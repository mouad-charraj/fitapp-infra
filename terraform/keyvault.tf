# Key Vault: will hold app secrets (DB passwords, Firebase service account, ...).
# External Secrets Operator in the cluster reads them and creates Kubernetes Secrets.
# Random suffix: a deleted vault name stays reserved for a while (soft delete),
# so a fresh suffix avoids name clashes between demo rebuilds.

resource "azurerm_key_vault" "main" {
  count = var.enable_key_vault ? 1 : 0

  name                       = "kv-${local.name}-${random_string.suffix.result}"
  location                   = azurerm_resource_group.main.location
  resource_group_name        = azurerm_resource_group.main.name
  tenant_id                  = data.azurerm_client_config.current.tenant_id
  sku_name                   = "standard"
  rbac_authorization_enabled = true # access via Azure roles, no legacy access policies
  soft_delete_retention_days = 7
  purge_protection_enabled   = false # must stay false so destroy can purge it
  tags                       = local.tags
}

# You can manage secrets in it.
resource "azurerm_role_assignment" "kv_admin_me" {
  count = var.enable_key_vault ? 1 : 0

  scope                = azurerm_key_vault.main[0].id
  role_definition_name = "Key Vault Administrator"
  principal_id         = data.azurerm_client_config.current.object_id
}

# The nodes (managed identity) can read secrets — least privilege: read only.
resource "azurerm_role_assignment" "kv_reader_nodes" {
  for_each = { for k, vm in azurerm_linux_virtual_machine.node : k => vm.identity[0].principal_id if var.enable_key_vault }

  scope                = azurerm_key_vault.main[0].id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = each.value
}
