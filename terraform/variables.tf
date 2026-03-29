variable "cluster_name" {
  description = "Name of the Kubernetes cluster."
  type        = string
  default     = "workshop-kub"
}

variable "cluster_plan" {
  description = "UpCloud plan for the cluster control plane."
  type        = string
  default     = "dev-md"
  # Trial account: only "dev-md" is supported.
  # Full account options: "production-sm", "production-md", "production-lg"
  # Run "upctl kubernetes plans" to see all available plans and their specs.
}

variable "kubernetes_version" {
  description = "Kubernetes version to deploy."
  type        = string
  default     = "1.34"
}

variable "zone" {
  description = "UpCloud zone to deploy into."
  type        = string
  default     = "de-fra1"
}

variable "control_plane_ip_filter" {
  description = "List of CIDRs/IPs allowed to reach the Kubernetes API server."
  type        = list(string)
  default     = []
}

variable "node_count" {
  description = "Number of worker nodes in the default node group. provision-workshop-access.ps1 sets this automatically (1 node per participant, minimum 2)."
  type        = number
  default     = 2
}

variable "node_plan" {
  description = "UpCloud plan for each worker node."
  type        = string
  default     = "DEV-1xCPU-2GB"
}

variable "ssh_keys" {
  description = "List of SSH public keys to add to each worker node."
  type        = list(string)
  default     = []
}
