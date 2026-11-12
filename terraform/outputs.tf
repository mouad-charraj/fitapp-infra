output "master_public_ip" {
  value = azurerm_public_ip.node["k3s-master"].ip_address
}

output "nodes" {
  description = "Every node with its private and public IP."
  value = {
    for k, v in local.nodes : k => {
      role       = v.role
      size       = v.size
      private_ip = v.private_ip
      public_ip  = azurerm_public_ip.node[k].ip_address
    }
  }
}

output "ssh_master" {
  value = "ssh -i ${local.ssh_private_key_path} ${var.admin_username}@${azurerm_public_ip.node["k3s-master"].ip_address}"
}

output "admin_cidrs" {
  description = "IPs allowed to SSH / reach the Kubernetes API."
  value       = local.admin_cidrs
}

output "key_vault_name" {
  value = var.enable_key_vault ? azurerm_key_vault.main[0].name : null
}

output "next_step" {
  value = "cd ../ansible && ansible-playbook site.yml"
}
