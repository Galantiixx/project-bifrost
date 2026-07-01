terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.0"
    }
  }
}

provider "azurerm" {
  features {
    resource_group {
      prevent_deletion_if_contains_resources = false
    }
  }
}

data "azurerm_client_config" "current" {}

# 1. GRUPO DE RECURSOS (Região oficial dos guiões)
resource "azurerm_resource_group" "rg" {
  name     = "rg-bifrost-final"
  location = "France Central" 
}

resource "random_integer" "ri" {
  min = 10000
  max = 99999
  
  # Força a rotação de IDs mudando um metadado simples
  keepers = {
    version = "2"
  }
}

# 2. ARMAZENAMENTO
resource "azurerm_storage_account" "storage" {
  name                     = "stbifrost${random_integer.ri.result}" 
  resource_group_name      = azurerm_resource_group.rg.name
  location                 = azurerm_resource_group.rg.location
  account_tier             = "Standard"
  account_replication_type = "LRS"
}

resource "azurerm_storage_queue" "queue" {
  name                 = "bifrost-recon-requests"
  storage_account_name = azurerm_storage_account.storage.name
}

resource "azurerm_storage_container" "blob_container" {
  name                  = "raw-recon-outputs"
  storage_account_name  = azurerm_storage_account.storage.name
  container_access_type = "private"
}

# 3. BASE DE DADOS NOSQL (SERVERLESS)
resource "azurerm_cosmosdb_account" "cosmos" {
  name                       = "cosmos-bifrost-${random_integer.ri.result}"
  location                   = azurerm_resource_group.rg.location
  resource_group_name        = azurerm_resource_group.rg.name
  offer_type                 = "Standard"
  kind                       = "GlobalDocumentDB" 
  automatic_failover_enabled = false

  capabilities {
    name = "EnableServerless" 
  }
  
  consistency_policy {
    consistency_level = "Session" 
  }
  
  geo_location {
    location          = azurerm_resource_group.rg.location
    failover_priority = 0
    zone_redundant    = false 
  }
}

# 4. COFRE DE SEGURANÇA
resource "azurerm_key_vault" "kv" {
  name                        = "kv-bifrost-${random_integer.ri.result}"
  location                    = azurerm_resource_group.rg.location
  resource_group_name         = azurerm_resource_group.rg.name
  enabled_for_disk_encryption = true
  tenant_id                   = data.azurerm_client_config.current.tenant_id
  sku_name                    = "standard"
  purge_protection_enabled    = false
}

# 5. APP SERVICE PLAN E WEB APP (FRONTEND)
resource "azurerm_service_plan" "app_plan" {
  name                = "plan-bifrost-web"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  os_type             = "Linux"
  sku_name            = "F1" 
}

resource "azurerm_linux_web_app" "webapp" {
  name                = "app-bifrost-dash-${random_integer.ri.result}"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_service_plan.app_plan.location
  service_plan_id     = azurerm_service_plan.app_plan.id

  site_config {
    always_on = false 
    application_stack {
      docker_image_name   = "nginx:alpine" 
      docker_registry_url = "https://index.docker.io"
    }
  }
}

# 6. AZURE FUNCTION APP (BACKEND)
resource "azurerm_service_plan" "function_plan" {
  name                = "plan-bifrost-func"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  os_type             = "Linux"
  sku_name            = "Y1" 
}

resource "azurerm_linux_function_app" "function_app" {
  name                       = "func-bifrost-recon-${random_integer.ri.result}"
  resource_group_name        = azurerm_resource_group.rg.name
  location                   = azurerm_resource_group.rg.location
  service_plan_id            = azurerm_service_plan.function_plan.id
  storage_account_name       = azurerm_storage_account.storage.name
  storage_account_access_key = azurerm_storage_account.storage.primary_access_key

  site_config {
    application_stack {
      node_version = "18" 
    }
  }
}

# 7. MÁQUINA ALVO
resource "azurerm_virtual_network" "vnet_alvo" {
  name                = "vnet-bifrost-alvo-we" # <--- ALTERADO O NOME
  address_space       = ["10.0.0.0/16"]
  location            = "West Europe"
  resource_group_name = azurerm_resource_group.rg.name
}

resource "azurerm_subnet" "subnet_alvo" {
  name                 = "subrede-alvo-we" # <--- ALTERADO O NOME
  resource_group_name  = azurerm_resource_group.rg.name
  virtual_network_name = azurerm_virtual_network.vnet_alvo.name
  address_prefixes     = ["10.0.1.0/24"]
}

resource "azurerm_public_ip" "ip_alvo" {
  name                = "ip-bifrost-alvo-we" # <--- ALTERADO O NOME
  location            = "West Europe"
  resource_group_name = azurerm_resource_group.rg.name
  allocation_method   = "Static"
  sku                 = "Standard" 
}

resource "azurerm_network_interface" "nic_alvo" {
  name                = "nic-bifrost-alvo-we" # <--- ALTERADO O NOME
  location            = "West Europe"
  resource_group_name = azurerm_resource_group.rg.name

  ip_configuration {
    name                          = "internal"
    subnet_id                     = azurerm_subnet.subnet_alvo.id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.ip_alvo.id
  }
}

resource "azurerm_linux_virtual_machine" "vm_alvo" {
  name                = "vm-alvo-bifrost"
  resource_group_name = azurerm_resource_group.rg.name
  location            = "West Europe"
  
  # ALTERADO PARA O SKU DISPONÍVEL NA TUA LISTA
  size                = "Standard_D2s_v6" 
  
  
  network_interface_ids = [
    azurerm_network_interface.nic_alvo.id,
  ]

 # Comenta ou apaga estas linhas se aparecerem:
 # admin_ssh_key {
 #   username   = "operador"
 #   public_key = file("${path.module}/id_rsa.pub")
 # }

admin_username                  = "bifrost"
admin_password                  = "bifrost2026"
disable_password_authentication = false

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "0001-com-ubuntu-server-focal"
    sku       = "20_04-lts-gen2" # Gen2 nativo e compatível com a série v6
    version   = "latest"
  }
}