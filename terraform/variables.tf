variable "project" {
  description = "Short project name, used in resource names."
  type        = string
  default     = "fitapp"
}

variable "location" {
  description = "Azure region (student policy allows: swedencentral, francecentral, germanywestcentral, polandcentral, norwayeast)."
  type        = string
  default     = "swedencentral"
}

# ---------------------------------------------------------------- access ----

variable "admin_username" {
  description = "Linux admin user on every VM."
  type        = string
  default     = "azureuser"
}

variable "ssh_public_key_path" {
  description = "Public key installed on the VMs. The private key (same path without .pub) is used by Ansible."
  type        = string
  default     = "~/.ssh/fitapp_azure.pub"
}

variable "admin_cidrs" {
  description = "CIDRs allowed to reach SSH (22) and the Kubernetes API (6443) on the master. Empty = auto-detect your current public IP."
  type        = list(string)
  default     = []
}

# ----------------------------------------------------------------- nodes ----

variable "master_size" {
  description = "VM size of the k3s server (control plane). B2als_v2 = 2 vCPU / 4 GB."
  type        = string
  default     = "Standard_B2als_v2"
}

variable "worker_size" {
  description = "VM size of each k3s worker. B2as_v2 = 2 vCPU / 8 GB."
  type        = string
  default     = "Standard_B2as_v2"
}

variable "worker_count" {
  description = "Number of workers. Regional quota is 6 vCPU -> master + 2 workers maximum."
  type        = number
  default     = 1

  validation {
    condition     = var.worker_count >= 0 && var.worker_count <= 2
    error_message = "worker_count must be 0, 1 or 2 (6 vCPU regional quota)."
  }
}

variable "os_disk_size_gb" {
  description = "OS disk size of every node (images, logs, local-path volumes)."
  type        = number
  default     = 64
}

variable "trusted_launch" {
  description = "Secure Boot + vTPM on the VMs (Trusted Launch)."
  type        = bool
  default     = true
}

# --------------------------------------------------------------- network ----

variable "vnet_cidr" {
  type    = string
  default = "10.0.0.0/16"
}

variable "subnet_cidr" {
  description = "Node subnet. Master gets .10, workers .11, .12"
  type        = string
  default     = "10.0.1.0/24"
}

# ----------------------------------------------------------- cost safety ----

variable "auto_shutdown_enabled" {
  description = "Safety net: deallocate every VM daily at auto_shutdown_time, in case someone forgets to destroy."
  type        = bool
  default     = true
}

variable "auto_shutdown_time" {
  description = "HHMM, 24h format."
  type        = string
  default     = "2300"
}

variable "auto_shutdown_timezone" {
  description = "Windows time zone id."
  type        = string
  default     = "Morocco Standard Time"
}

# ------------------------------------------------------------------ misc ----

variable "enable_key_vault" {
  description = "Create the Key Vault used later by External Secrets Operator."
  type        = bool
  default     = true
}

variable "extra_tags" {
  type    = map(string)
  default = {}
}
