output "state_storage_account" {
  value = azurerm_storage_account.state.name
}

output "state_resource_group" {
  value = azurerm_resource_group.state.name
}

output "next_step" {
  value = "Wait ~2 min for the role assignment to propagate, then: cd ../terraform && terraform init -backend-config=backend.hcl"
}
