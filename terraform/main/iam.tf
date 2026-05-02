# Three SAs:
#   - k3s_server: control-plane node identity. ESO pod runs here and uses
#                 ADC (metadata server) to read Secret Manager, so this SA
#                 needs roles/secretmanager.secretAccessor.
#   - k3s_agent:  worker node identity. Pulls images from AR via the kubelet
#                 credential provider.
#   - k8s_deployer: identity GHA impersonates to mint a Google-issued OIDC
#                 ID token for the k8s API server.

resource "google_service_account" "k3s_server" {
  account_id   = "${var.name_prefix}-k3s-server"
  display_name = "k3s control-plane node identity"
}

resource "google_service_account" "k3s_agent" {
  account_id   = "${var.name_prefix}-k3s-agent"
  display_name = "k3s agent node identity"
}

resource "google_service_account" "k8s_deployer" {
  account_id   = "${var.name_prefix}-k8s-deployer"
  display_name = "Identity GHA impersonates for k8s API ID tokens"
}

# GHA SA acts as both node SAs and impersonates k8s_deployer for OIDC.
resource "google_service_account_iam_member" "gha_uses_k3s_server" {
  service_account_id = google_service_account.k3s_server.name
  role               = "roles/iam.serviceAccountUser"
  member             = "serviceAccount:${var.gha_service_account_email}"
}

resource "google_service_account_iam_member" "gha_uses_k3s_agent" {
  service_account_id = google_service_account.k3s_agent.name
  role               = "roles/iam.serviceAccountUser"
  member             = "serviceAccount:${var.gha_service_account_email}"
}

resource "google_service_account_iam_member" "gha_impersonates_k8s_deployer" {
  service_account_id = google_service_account.k8s_deployer.name
  role               = "roles/iam.serviceAccountTokenCreator"
  member             = "serviceAccount:${var.gha_service_account_email}"
}

# OS Login + IAP for GHA SA.
resource "google_project_iam_member" "gha_os_admin_login" {
  project = var.project_id
  role    = "roles/compute.osAdminLogin"
  member  = "serviceAccount:${var.gha_service_account_email}"
}

resource "google_project_iam_member" "gha_iap_tunnel" {
  project = var.project_id
  role    = "roles/iap.tunnelResourceAccessor"
  member  = "serviceAccount:${var.gha_service_account_email}"
}
