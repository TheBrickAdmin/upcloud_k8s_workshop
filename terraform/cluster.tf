resource "upcloud_network" "workshop" {
  name = "${var.cluster_name}-network"
  zone = var.zone

  ip_network {
    address            = "10.0.0.0/24"
    dhcp               = true
    dhcp_default_route = false
    family             = "IPv4"
  }
}

resource "upcloud_kubernetes_cluster" "c" {
  control_plane_ip_filter = var.control_plane_ip_filter
  labels                  = {}
  name                    = var.cluster_name
  network                 = upcloud_network.workshop.id
  plan                    = var.cluster_plan
  private_node_groups     = false
  storage_encryption      = null
  upgrade_strategy_type   = null
  version                 = var.kubernetes_version
  zone                    = var.zone
}

resource "upcloud_kubernetes_node_group" "ng" {
  anti_affinity          = false
  cluster                = upcloud_kubernetes_cluster.c.id
  labels                 = {}
  name                   = "default"
  node_count             = var.node_count
  plan                   = var.node_plan
  ssh_keys               = var.ssh_keys
  utility_network_access = true
}
