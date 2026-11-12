# =============================================================================
# BOOTSTRAP — run ONCE. Creates the PERMANENT resources that are never destroyed:
#   - resource group + storage account that hold the Terraform state of ../terraform
#     (and later the Postgres backups)
#   - a monthly budget alert on the whole subscription
#
# Its own state stays LOCAL (bootstrap/terraform.tfstate, git-ignored) because
# it cannot store its state in a storage account that does not exist yet.
# =============================================================================

terraform {
  required_version = ">= 1.9"
  required_providers {
    azurerm = { source = "hashicorp/azurerm", version = "~> 4.81" }
    local   = { source = "hashicorp/local", version = "~> 2.5" }
  }
}

provider "azurerm" {
  features {}
  # Azure for Students cannot register every provider of the default "core" set.
  # The ones we use (Storage, Consumption) are already registered.
  resource_provider_registrations = "none"
  # Shared keys are disabled on the storage account -> talk to blob storage with Entra ID (your az login).
  storage_use_azuread = true
}

data "azurerm_client_config" "current" {}
data "azurerm_subscription" "current" {}

locals {
  tags = {
    project    = var.project
    managed_by = "terraform-bootstrap"
    lifecycle  = "permanent"
  }
  # Storage account names must be globally unique, 3-24 lowercase letters/digits.
  # Derived from the subscription id so re-running always gives the same name.
  storage_account_name = "${var.project}tfstate${substr(sha1(data.azurerm_client_config.current.subscription_id), 0, 8)}"
}

resource "azurerm_resource_group" "state" {
  name     = "${var.project}-tfstate-rg"
  location = var.location
  tags     = local.tags
}

resource "azurerm_storage_account" "state" {
  name                     = local.storage_account_name
  resource_group_name      = azurerm_resource_group.state.name
  location                 = azurerm_resource_group.state.location
  account_tier             = "Standard"
  account_replication_type = "LRS"
  account_kind             = "StorageV2"

  # --- security baseline ---
  min_tls_version                 = "TLS1_2"
  https_traffic_only_enabled      = true
  allow_nested_items_to_be_public = false
  shared_access_key_enabled       = false # only Entra ID (RBAC) access, no account keys
  default_to_oauth_authentication = true

  blob_properties {
    versioning_enabled = true # every state change is kept -> you can recover an old state
    delete_retention_policy {
      days = 14
    }
    container_delete_retention_policy {
      days = 14
    }
  }

  tags = local.tags

  lifecycle {
    prevent_destroy = true # losing the state = Terraform forgets everything it created
  }
}

resource "azurerm_storage_container" "tfstate" {
  name                  = "tfstate"
  storage_account_id    = azurerm_storage_account.state.id
  container_access_type = "private"
}

resource "azurerm_storage_container" "backups" {
  name                  = "backups" # later: nightly pg_dump of prod
  storage_account_id    = azurerm_storage_account.state.id
  container_access_type = "private"
}

# You (the signed-in user) may read/write blobs -> needed by the azurerm backend with use_azuread_auth.
resource "azurerm_role_assignment" "me_blob_contributor" {
  scope                = azurerm_storage_account.state.id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = data.azurerm_client_config.current.object_id
}

# ----------------------------------------------------------------------------
# Budget alert: emails you when spending passes 50% / 90% (actual) or is
# forecast to pass 100% of the monthly amount.
# ----------------------------------------------------------------------------
resource "azurerm_consumption_budget_subscription" "monthly" {
  count = var.alert_email == "" ? 0 : 1

  name            = "budget-${var.project}-monthly"
  subscription_id = data.azurerm_subscription.current.id
  amount          = var.budget_amount
  time_grain      = "Monthly"

  time_period {
    start_date = formatdate("YYYY-MM-01'T'00:00:00Z", plantimestamp())
  }

  notification {
    enabled        = true
    threshold      = 50
    operator       = "GreaterThan"
    threshold_type = "Actual"
    contact_emails = [var.alert_email]
  }

  notification {
    enabled        = true
    threshold      = 90
    operator       = "GreaterThan"
    threshold_type = "Actual"
    contact_emails = [var.alert_email]
  }

  notification {
    enabled        = true
    threshold      = 100
    operator       = "GreaterThan"
    threshold_type = "Forecasted"
    contact_emails = [var.alert_email]
  }

  lifecycle {
    ignore_changes = [time_period] # start date is computed once, do not change it every month
  }
}

# Writes the backend config used by ../terraform  (terraform init -backend-config=backend.hcl)
resource "local_file" "backend_config" {
  filename        = "${path.module}/../terraform/backend.hcl"
  file_permission = "0644"
  content         = <<-EOT
    # GENERATED by bootstrap/ — not secret, safe to commit.
    resource_group_name  = "${azurerm_resource_group.state.name}"
    storage_account_name = "${azurerm_storage_account.state.name}"
    container_name       = "${azurerm_storage_container.tfstate.name}"
    key                  = "${var.project}/infra.tfstate"
    use_azuread_auth     = true
  EOT
}
