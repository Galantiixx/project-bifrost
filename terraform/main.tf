terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.0"
    }
  }
}

provider "azurerm" {
  features {}
}

resource "azurerm_resource_group" "rg" {
  name     = "rg-bifrost-final"
  location = "westeurope"
}

# Storage Account para logs brutos e backend
resource "azurerm_storage_account" "storage" {
  name                     = "stbifrost34629"
  resource_group_name      = azurerm_resource_group.rg.name
  location                 = azurerm_resource_group.rg.location
  account_tier             = "Standard"
  account_replication_type = "LRS"
}

# Contentor de Blobs dedicado aos relatórios brutos .json do enunciado
resource "azurerm_storage_container" "raw_container" {
  name                  = "historico-bruto"
  storage_account_name  = azurerm_storage_account.storage.name
  container_access_type = "private"
}

resource "azurerm_cosmosdb_account" "cosmos" {
  name                = "cosmos-bifrost-34629"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  offer_type          = "Standard"
  kind                = "GlobalDocumentDB"

  consistency_policy {
    consistency_level = "Session"
  }

  geo_location {
    location          = azurerm_resource_group.rg.location
    failover_priority = 0
  }
}

# Plano de Serviço para a Azure Function (Serverless)
resource "azurerm_service_plan" "plan_function" {
  name                = "plan-bifrost-serverless"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  os_type             = "Linux"
  sku_name            = "Y1"
}

resource "azurerm_linux_function_app" "function" {
  name                = "func-bifrost-recon-34629"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  service_plan_id     = azurerm_service_plan.plan_function.id

  storage_account_name       = azurerm_storage_account.storage.name
  storage_account_access_key = azurerm_storage_account.storage.primary_access_key

  site_config {
    application_stack {
      node_version = "18"
    }
  }
}

# ==================== INTEGRATION: DOCKER & APP SERVICE ====================

# Plano de Serviço dedicado para o App Service Containers
resource "azurerm_service_plan" "plan_app" {
  name                = "plan-bifrost-appservice"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  os_type             = "Linux"
  sku_name            = "B1" # Plano básico económico que suporta Docker nativo
}

# Azure App Service que vai rodar o Frontend em Docker
resource "azurerm_linux_web_app" "frontend_app" {
  name                = "app-bifrost-frontend-34629"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  service_plan_id     = azurerm_service_plan.plan_app.id

  site_config {
    application_stack {
      docker_image_name   = "nginx:alpine" # Imagem base inicial (o deploy.sh atualiza com o build local)
      docker_registry_url = "https://index.docker.io"
    }
  }
}

# ==================== VM ALVO ESTÁTICA PARA TESTES ====================
resource "azurerm_public_ip" "vm_ip" {
  name                = "ip-alvo-bifrost"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  allocation_method   = "Static"
}

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

resource "azurerm_network_interface" "nic" {
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

resource "azurerm_linux_virtual_machine" "vm" {
  name                = "vm-alvo-bifrost"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  size                = "Standard_D2s_v6"
  admin_username      = "operador"
  network_interface_ids = [
    azurerm_network_interface.nic.id,
  ]

  admin_password                  = "P@ssw0rdBifrost2026!"
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