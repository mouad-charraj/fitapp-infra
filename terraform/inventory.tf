# Generates the Ansible inventory from what Terraform just created.
# Nobody writes IPs by hand -> no copy/paste mistakes, always in sync.

resource "local_file" "ansible_inventory" {
  filename        = "${path.module}/../ansible/inventory/hosts.ini"
  file_permission = "0644"

  content = templatefile("${path.module}/templates/inventory.tftpl", {
    admin_user        = var.admin_username
    ssh_private_key   = local.ssh_private_key_path
    known_hosts       = abspath("${path.module}/../ansible/.known_hosts")
    master_public_ip  = azurerm_public_ip.node["k3s-master"].ip_address
    master_private_ip = local.nodes["k3s-master"].private_ip
    workers           = { for k, v in local.nodes : k => v if v.role == "worker" }
  })
}
