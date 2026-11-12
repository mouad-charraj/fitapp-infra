terraform {
  required_version = ">= 1.9"

  required_providers {
    azurerm = { source = "hashicorp/azurerm", version = "~> 4.81" }
    random  = { source = "hashicorp/random", version = "~> 3.7" }
    http    = { source = "hashicorp/http", version = "~> 3.5" }
    local   = { source = "hashicorp/local", version = "~> 2.5" }
  }

  # State lives in the permanent storage account created by ../bootstrap.
  # Values come from backend.hcl:  terraform init -backend-config=backend.hcl
  backend "azurerm" {}
}

provider "azurerm" {
  # subscription_id is read from the ARM_SUBSCRIPTION_ID environment variable.

  # Azure for Students cannot register every provider of the default "core" set.
  # Needed ones (Compute, Network, Storage, KeyVault, DevTestLab) are already registered.
  resource_provider_registrations = "none"

  features {
    key_vault {
      purge_soft_delete_on_destroy    = true # destroy = really gone, so the next apply can reuse names
      recover_soft_deleted_key_vaults = false
    }
    virtual_machine {
      delete_os_disk_on_deletion = true # no orphan disks billing after destroy
    }
  }
}
