variable "kubeconfig" {
  description = "Path to Harvester kubeconfig"
  type        = string
  default     = "~/.kube/carbide-enclave-harvester.kubeconfig"
}

variable "namespace" {
  description = "Harvester namespace for all resources"
  type        = string
  default     = "default"
}

variable "ip_prefix" {
  description = "Network IP prefix (first three octets)"
  type        = string
  default     = "10.0.0"
}

variable "network_name" {
  description = "Harvester VM network name (vlan-mgmt or similar)"
  type        = string
}

variable "ssh_public_key" {
  description = "SSH public key injected into each VM"
  type        = string
}

variable "admin_user" {
  description = "Admin username for cloud-init"
  type        = string
  default     = "mansible"
}

variable "vm_cpu" {
  description = "vCPUs per RKE2 node"
  type        = number
  default     = 4
}

variable "vm_memory" {
  description = "RAM per RKE2 node (e.g. 8Gi)"
  type        = string
  default     = "8Gi"
}

variable "vm_disk_size" {
  description = "Root disk size per node (e.g. 50Gi)"
  type        = string
  default     = "50Gi"
}
