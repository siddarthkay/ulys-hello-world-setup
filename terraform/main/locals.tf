# Shared labels applied to everything that supports them.
locals {
  common_labels = {
    app     = var.name_prefix
    managed = "terraform"
  }

  # sslip.io resolves <ip>.sslip.io to <ip> via public DNS, so Google's
  # managed SSL cert can be issued via Load-Balancer-Authorization without
  # a real domain. domain renders as e.g. "1-2-3-4.sslip.io".
  domain = "${replace(google_compute_global_address.lb.address, ".", "-")}.sslip.io"
}
