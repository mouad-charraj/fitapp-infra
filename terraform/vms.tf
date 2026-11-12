resource "azurerm_public_ip" "node" {
  for_each = local.nodes

  name                = "pip-${each.key}"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = merge(local.tags, { role = each.value.role })
}

resource "azurerm_network_interface" "node" {
  for_each = local.nodes

  name                = "nic-${each.key}"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  tags                = merge(local.tags, { role = each.value.role })

  ip_configuration {
    name                          = "internal"
    subnet_id                     = azurerm_subnet.nodes.id
    private_ip_address_allocation = "Static"
    private_ip_address            = each.value.private_ip
    public_ip_address_id          = azurerm_public_ip.node[each.key].id
  }
}

resource "azurerm_network_interface_security_group_association" "node" {
  for_each = local.nodes

  network_interface_id      = azurerm_network_interface.node[each.key].id
  network_security_group_id = each.value.role == "master" ? azurerm_network_security_group.master.id : azurerm_network_security_group.workers.id
}

resource "azurerm_linux_virtual_machine" "node" {
  for_each = local.nodes

  name                  = each.key
  computer_name         = each.key # = Linux hostname = Kubernetes node name
  location              = azurerm_resource_group.main.location
  resource_group_name   = azurerm_resource_group.main.name
  size                  = each.value.size
  admin_username        = var.admin_username
  network_interface_ids = [azurerm_network_interface.node[each.key].id]

  disable_password_authentication = true
  admin_ssh_key {
    username   = var.admin_username
    public_key = file(pathexpand(var.ssh_public_key_path))
  }

  os_disk {
    name                 = "osdisk-${each.key}"
    caching              = "ReadWrite"
    storage_account_type = "StandardSSD_LRS"
    disk_size_gb         = var.os_disk_size_gb
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "ubuntu-24_04-lts"
    sku       = "server"
    version   = "latest"
  }

  secure_boot_enabled = var.trusted_launch
  vtpm_enabled        = var.trusted_launch

  # Managed identity: later lets the node read secrets from Key Vault without passwords.
  identity {
    type = "SystemAssigned"
  }

  # Serial console + boot screenshots in the portal (managed storage, no extra resource).
  boot_diagnostics {}

  tags = merge(local.tags, { role = each.value.role })

  depends_on = [azurerm_network_interface_security_group_association.node]
}

# Safety net: deallocate every night so a forgotten cluster does not eat the credit.
resource "azurerm_dev_test_global_vm_shutdown_schedule" "node" {
  for_each = { for k, vm in azurerm_linux_virtual_machine.node : k => vm.id if var.auto_shutdown_enabled }

  virtual_machine_id    = each.value
  location              = azurerm_resource_group.main.location
  enabled               = true
  daily_recurrence_time = var.auto_shutdown_time
  timezone              = var.auto_shutdown_timezone
  tags                  = local.tags

  notification_settings {
    enabled = false
  }
}
