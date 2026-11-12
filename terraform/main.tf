data "azurerm_client_config" "current" {}

# Your current public IP, used only when var.admin_cidrs is empty.
data "http" "my_ip" {
  # Fallback only: scripts/up.sh detects the IP itself and sets TF_VAR_admin_cidrs.
  count = length(var.admin_cidrs) == 0 ? 1 : 0
  url   = "https://checkip.amazonaws.com"

  retry {
    attempts     = 3
    min_delay_ms = 2000
  }

  lifecycle {
    postcondition {
      condition     = self.status_code == 200
      error_message = "Could not detect your public IP. Set admin_cidrs manually in terraform.tfvars."
    }
  }
}

resource "random_string" "suffix" {
  length  = 6
  upper   = false
  special = false
}

locals {
  name = var.project

  admin_cidrs = length(var.admin_cidrs) > 0 ? var.admin_cidrs : ["${chomp(data.http.my_ip[0].response_body)}/32"]

  ssh_private_key_path = trimsuffix(pathexpand(var.ssh_public_key_path), ".pub")

  # One map describing every node: master first, then the workers.
  nodes = merge(
    {
      "k3s-master" = {
        role       = "master"
        size       = var.master_size
        private_ip = cidrhost(var.subnet_cidr, 10)
      }
    },
    {
      for i in range(var.worker_count) : "k3s-worker-${i + 1}" => {
        role       = "worker"
        size       = var.worker_size
        private_ip = cidrhost(var.subnet_cidr, 11 + i)
      }
    }
  )

  tags = merge({
    project    = var.project
    managed_by = "terraform"
    lifecycle  = "ephemeral" # created for demos, destroyed after
  }, var.extra_tags)
}

resource "azurerm_resource_group" "main" {
  name     = "${local.name}-rg"
  location = var.location
  tags     = local.tags
}
