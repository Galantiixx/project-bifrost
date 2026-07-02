terraform {
  required_providers {
    azurerm = { source = "hashicorp/azurerm", version = "~> 3.0" }
    random = { source = "hashicorp/random", version = "~> 3.0" }
  }
}

provider "azurerm" { features {} }

variable "location" { type = string, default = "eastus" }
variable "rg_name" { type = string, default = "rg-bifrost-final-v2" }

resource "azurerm_resource_group" "rg" {
  name     = var.rg_name
  location = var.location
}

# --- VNET e SUBNET ---
resource "azurerm_virtual_network" "vnet" {
  name                = "vnet-bifrost"
  address_space       = ["10.0.0.0/16"]
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
}

resource "azurerm_subnet" "subnet" {
  name                 = "internal"
  resource_group_name  = azurerm_resource_group.rg.name
  virtual_network_name = azurerm_virtual_network.vnet.name
  address_prefixes     = ["10.0.2.0/24"]
}

# --- VM ALVO (SKU B2s para evitar erro de disponibilidade) ---
resource "azurerm_public_ip" "vm_ip" {
  name                = "ip-alvo-bifrost"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  allocation_method   = "Static"
  sku                 = "Standard"
}

resource "azurerm_network_interface" "vm_nic" {
  name                = "nic-alvo-bifrost"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  ip_configuration {
    name                          = "internal"
    subnet_id                     = azurerm_subnet.subnet.id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.vm_ip.id
  }
}

resource "azurerm_linux_virtual_machine" "target_vm" {
  name                = "vm-alvo-bifrost"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  size                = "Standard_B2s" 
  admin_username      = "bifrostadmin"
  network_interface_ids = [azurerm_network_interface.vm_nic.id]
  admin_password                  = "BifrostPass1234!"
  disable_password_authentication = false
  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
  }
  source_image_reference {
    publisher = "Canonical"
    offer     = "0001-com-ubuntu-server-jammy"
    sku       = "22_04-lts"
    version   = "latest"
  }
}

# --- COSMOS DB (Serverless) ---
resource "azurerm_cosmosdb_account" "cosmos" {
  name                = "cosmos-bifrost-${random_string.unique.result}"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  offer_type          = "Standard"
  kind                = "GlobalDocumentDB"
  consistency_policy { consistency_level = "Session" }
  geo_location { location = azurerm_resource_group.rg.location, failover_priority = 0 }
  capabilities { name = "EnableServerless" }
}

resource "random_string" "unique" { length = 5, special = false, upper = false }
