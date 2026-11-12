# =============================================================================
#  Internet
#     │  22, 6443 : only admin_cidrs        80, 443 : everyone
#     ▼
#  k3s-master  10.0.1.10  (public IP, NSG "master")      <- bastion for Ansible
#     │   private subnet 10.0.1.0/24 — all node-to-node traffic allowed
#  k3s-worker-N 10.0.1.1x (public IP for OUTBOUND only, NSG "workers" = no inbound from internet)
# =============================================================================

resource "azurerm_virtual_network" "main" {
  name                = "vnet-${local.name}"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  address_space       = [var.vnet_cidr]
  tags                = local.tags
}

resource "azurerm_subnet" "nodes" {
  name                 = "snet-nodes"
  resource_group_name  = azurerm_resource_group.main.name
  virtual_network_name = azurerm_virtual_network.main.name
  address_prefixes     = [var.subnet_cidr]

  # No implicit internet access: every node gets outbound through its own public IP, explicitly.
  default_outbound_access_enabled = false
}

# ------------------------------------------------------------- NSG master ----
resource "azurerm_network_security_group" "master" {
  name                = "nsg-${local.name}-master"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  tags                = local.tags

  security_rule {
    name                       = "Allow-SSH-Admin"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "22"
    source_address_prefixes    = local.admin_cidrs
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "Allow-K8sAPI-Admin"
    priority                   = 110
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "6443"
    source_address_prefixes    = local.admin_cidrs
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "Allow-HTTP-HTTPS-Internet"
    priority                   = 120
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_ranges    = ["80", "443"]
    source_address_prefix      = "Internet"
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "Deny-All-Other-Internet"
    priority                   = 4000
    direction                  = "Inbound"
    access                     = "Deny"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "Internet"
    destination_address_prefix = "*"
  }
}

# ------------------------------------------------------------ NSG workers ----
resource "azurerm_network_security_group" "workers" {
  name                = "nsg-${local.name}-workers"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  tags                = local.tags

  # Nothing from the internet. Node-to-node traffic is allowed by the default
  # "AllowVnetInBound" rule (priority 65000).
  security_rule {
    name                       = "Deny-All-Internet"
    priority                   = 4000
    direction                  = "Inbound"
    access                     = "Deny"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "Internet"
    destination_address_prefix = "*"
  }
}
