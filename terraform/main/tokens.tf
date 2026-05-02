# Cluster join token. Persists across TF applies (no keepers). Rendered
# directly into both nodes' cloud-init via templatefile() — same trust
# scope as TF state, no extra surface.
resource "random_password" "k3s_token" {
  length  = 64
  special = false
}

# Per-node identity password. K3s agents store this at /etc/rancher/node/
# password and the server records it on first join; mismatches on later
# joins (e.g. agent VM rebuild) cause "Node password rejected". Pre-seeding
# the same value into every agent rebuild keeps the per-node secret stable.
resource "random_password" "agent_node_password" {
  length  = 32
  special = false
}
