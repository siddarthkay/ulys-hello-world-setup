# External HTTPS LB:
#   /         -> backend_bucket (web GCS bucket, CDN-cached)
#   /api/*    -> backend_service (Cloud Run api, /api stripped before forward)
#
# Same origin = no CORS surface. The forwarding rule binds a global anycast
# IP; the managed cert is issued for <ip>.sslip.io. Cert provisioning takes
# ~15-30 minutes for first issuance via Load-Balancer-Authorization.

# ---- public IP -----------------------------------------------------------
resource "google_compute_global_address" "lb" {
  name = "${var.name_prefix}-lb-ip"
}

# ---- backend bucket for the static site ----------------------------------
resource "google_compute_backend_bucket" "web" {
  name        = "${var.name_prefix}-web-backend"
  bucket_name = google_storage_bucket.web.name
  enable_cdn  = true

  cdn_policy {
    cache_mode  = "CACHE_ALL_STATIC"
    default_ttl = 3600
    max_ttl     = 86400
    client_ttl  = 3600
  }
}

# ---- serverless NEG + backend service for the api ------------------------
resource "google_compute_region_network_endpoint_group" "api" {
  name                  = "${var.name_prefix}-api-neg"
  network_endpoint_type = "SERVERLESS"
  region                = var.region

  cloud_run {
    service = google_cloud_run_v2_service.api.name
  }
}

resource "google_compute_backend_service" "api" {
  name                  = "${var.name_prefix}-api-backend"
  protocol              = "HTTPS"
  timeout_sec           = 30
  load_balancing_scheme = "EXTERNAL_MANAGED"

  backend {
    group = google_compute_region_network_endpoint_group.api.id
  }

  log_config {
    enable      = true
    sample_rate = 1.0
  }
}

# ---- URL map: route /api/* -> api, everything else -> web ----------------
resource "google_compute_url_map" "lb" {
  name            = "${var.name_prefix}-url-map"
  default_service = google_compute_backend_bucket.web.id

  host_rule {
    hosts        = ["*"]
    path_matcher = "main"
  }

  path_matcher {
    name            = "main"
    default_service = google_compute_backend_bucket.web.id

    # /api/healthz -> Cloud Run api at /healthz (the path_prefix_rewrite
    # strips "/api"). /api by itself is not rewritten because the rule
    # `paths = ["/api", "/api/*"]` matches both.
    path_rule {
      paths   = ["/api", "/api/*"]
      service = google_compute_backend_service.api.id
      route_action {
        url_rewrite {
          path_prefix_rewrite = "/"
        }
      }
    }
  }
}

# ---- managed SSL cert for sslip.io ---------------------------------------
resource "google_compute_managed_ssl_certificate" "lb" {
  name = "${var.name_prefix}-cert"

  managed {
    domains = [local.domain]
  }
}

resource "google_compute_target_https_proxy" "lb" {
  name             = "${var.name_prefix}-https-proxy"
  url_map          = google_compute_url_map.lb.id
  ssl_certificates = [google_compute_managed_ssl_certificate.lb.id]
}

resource "google_compute_global_forwarding_rule" "lb_https" {
  name                  = "${var.name_prefix}-fr-https"
  target                = google_compute_target_https_proxy.lb.id
  ip_address            = google_compute_global_address.lb.id
  port_range            = "443"
  load_balancing_scheme = "EXTERNAL_MANAGED"
}

# ---- HTTP -> HTTPS redirect ---------------------------------------------
resource "google_compute_url_map" "redirect" {
  name = "${var.name_prefix}-http-redirect"
  default_url_redirect {
    https_redirect         = true
    redirect_response_code = "MOVED_PERMANENTLY_DEFAULT"
    strip_query            = false
  }
}

resource "google_compute_target_http_proxy" "lb" {
  name    = "${var.name_prefix}-http-proxy"
  url_map = google_compute_url_map.redirect.id
}

resource "google_compute_global_forwarding_rule" "lb_http" {
  name                  = "${var.name_prefix}-fr-http"
  target                = google_compute_target_http_proxy.lb.id
  ip_address            = google_compute_global_address.lb.id
  port_range            = "80"
  load_balancing_scheme = "EXTERNAL_MANAGED"
}
