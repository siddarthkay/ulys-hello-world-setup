# Cloud Run services: api (public, traffic-split via canary) + worker
# (internal, IAM-protected, called only by api).
#
# Each service has its own service account so we can grant least-privilege
# IAM bindings. api gets Cloud SQL + Memorystore + Secret Manager access;
# worker gets nothing (it just verifies tokens).
#
# IMPORTANT: `image` and `traffic` are managed out-of-band by the CI deploy
# script (gcloud run deploy + gcloud run services update-traffic). TF only
# creates the service skeleton with a placeholder image. lifecycle.ignore_
# changes keeps subsequent `terraform apply`s from clobbering CI's deploys.

# ---------------------------------------------------------------------------
# Service accounts
# ---------------------------------------------------------------------------
resource "google_service_account" "api" {
  account_id   = "${var.name_prefix}-api"
  display_name = "Cloud Run api"
}

resource "google_service_account" "worker" {
  account_id   = "${var.name_prefix}-worker"
  display_name = "Cloud Run worker"
}

# GHA SA needs to act-as both Cloud Run SAs to deploy revisions that bind
# to them.
resource "google_service_account_iam_member" "gha_acts_as_api" {
  service_account_id = google_service_account.api.name
  role               = "roles/iam.serviceAccountUser"
  member             = "serviceAccount:${var.gha_service_account_email}"
}

resource "google_service_account_iam_member" "gha_acts_as_worker" {
  service_account_id = google_service_account.worker.name
  role               = "roles/iam.serviceAccountUser"
  member             = "serviceAccount:${var.gha_service_account_email}"
}

# api SA reads the DB password secret. Worker doesn't touch DB so doesn't
# need it.
resource "google_secret_manager_secret_iam_member" "api_reads_db_password" {
  secret_id = data.google_secret_manager_secret.db_password.id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.api.email}"
}

# ---------------------------------------------------------------------------
# worker service: internal-only, IAM-required.
# ---------------------------------------------------------------------------
# ingress = "INGRESS_TRAFFIC_INTERNAL_ONLY": only callers on the VPC connector
# (i.e. api) can reach it. Combined with `--no-allow-unauthenticated` (default
# in v2 when no allUsers binding exists) and `roles/run.invoker` granted only
# to the api SA, this is defense-in-depth: network isolation + IAM.
resource "google_cloud_run_v2_service" "worker" {
  name     = "${var.name_prefix}-worker"
  location = var.region
  ingress  = "INGRESS_TRAFFIC_INTERNAL_ONLY"

  deletion_protection = false

  labels = merge(local.common_labels, { component = "worker" })

  template {
    service_account = google_service_account.worker.email
    timeout         = "10s"

    scaling {
      min_instance_count = 0
      max_instance_count = 5
    }

    containers {
      # Placeholder; CI re-deploys with the real image SHA-tagged.
      image = "us-docker.pkg.dev/cloudrun/container/hello"

      ports {
        container_port = 8081
      }

      # PORT is reserved by Cloud Run; it sets it automatically based on
      # the `ports.container_port` above. Don't set it manually.

      # Worker derives the expected audience from request.host at runtime
      # (the URL Cloud Run exposed it under), so no AUDIENCE env var here.
      # It does check the token's `email` claim matches the api SA.
      env {
        name  = "EXPECTED_INVOKER_EMAIL"
        value = google_service_account.api.email
      }
    }
  }

  traffic {
    type    = "TRAFFIC_TARGET_ALLOCATION_TYPE_LATEST"
    percent = 100
  }

  lifecycle {
    ignore_changes = [
      template[0].containers[0].image,
      client,
      client_version,
    ]
  }
}

# api can invoke worker.
resource "google_cloud_run_v2_service_iam_member" "api_invokes_worker" {
  project  = google_cloud_run_v2_service.worker.project
  location = google_cloud_run_v2_service.worker.location
  name     = google_cloud_run_v2_service.worker.name
  role     = "roles/run.invoker"
  member   = "serviceAccount:${google_service_account.api.email}"
}

# ---------------------------------------------------------------------------
# api service: public ingress (for sake of the canary's tag-URL probes), but
# the public *.run.app URL is unauthenticated only because the LB needs to
# reach it. Real users hit the LB; the LB strips /api and forwards.
# ---------------------------------------------------------------------------
resource "google_cloud_run_v2_service" "api" {
  name     = "${var.name_prefix}-api"
  location = var.region
  ingress  = "INGRESS_TRAFFIC_ALL"

  deletion_protection = false

  labels = merge(local.common_labels, { component = "api" })

  template {
    service_account = google_service_account.api.email
    timeout         = "30s"

    # ALL_TRAFFIC: every outbound request from api goes through the VPC
    # connector. This is required because worker is ingress=internal-only,
    # which only accepts requests that arrive via VPC. With
    # PRIVATE_RANGES_ONLY, api's calls to worker's *.run.app URL would
    # route via default Cloud Run egress (public internet) and worker
    # would reject them with 404 ("internal ingress block"). For our
    # workload (api only talks to Cloud SQL, Redis, and worker, plus the
    # local metadata server), routing all egress through the connector
    # adds no meaningful latency.
    vpc_access {
      connector = google_vpc_access_connector.connector.id
      egress    = "ALL_TRAFFIC"
    }

    scaling {
      min_instance_count = 0
      max_instance_count = 5
    }

    containers {
      # Placeholder; CI re-deploys with the real image SHA-tagged.
      image = "us-docker.pkg.dev/cloudrun/container/hello"

      ports {
        container_port = 8080
      }

      # PORT is reserved by Cloud Run; set automatically from ports above.

      env {
        name  = "DB_HOST"
        value = google_sql_database_instance.pg.private_ip_address
      }
      env {
        name  = "DB_USER"
        value = google_sql_user.app.name
      }
      env {
        name  = "DB_NAME"
        value = google_sql_database.app.name
      }
      env {
        name  = "REDIS_HOST"
        value = google_redis_instance.cache.host
      }
      env {
        name  = "REDIS_PORT"
        value = google_redis_instance.cache.port
      }
      env {
        name  = "WORKER_URL"
        value = google_cloud_run_v2_service.worker.uri
      }
      # DB password mounted from Secret Manager. `latest` so a SM rotation
      # picks up on the next Cloud Run revision (CI deploys a new revision).
      env {
        name = "DB_PASSWORD"
        value_source {
          secret_key_ref {
            secret  = data.google_secret_manager_secret.db_password.secret_id
            version = "latest"
          }
        }
      }
    }
  }

  traffic {
    type    = "TRAFFIC_TARGET_ALLOCATION_TYPE_LATEST"
    percent = 100
  }

  lifecycle {
    ignore_changes = [
      template[0].containers[0].image,
      template[0].containers[0].env,
      traffic, # CI manages traffic split for the canary
      client,
      client_version,
    ]
  }
}

# Cloud Run requires `allUsers` for fully public access. We allow it because
# the LB and the *.run.app URL both need to reach api unauthenticated. The
# canary probes the *.run.app URL via revision tags during rollout.
resource "google_cloud_run_v2_service_iam_member" "api_public" {
  project  = google_cloud_run_v2_service.api.project
  location = google_cloud_run_v2_service.api.location
  name     = google_cloud_run_v2_service.api.name
  role     = "roles/run.invoker"
  member   = "allUsers"
}

