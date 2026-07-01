# =========================================================================
# SYSTEM CONFIGURATION & VARIABLES
# =========================================================================

terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.0"
    }
  }
}

provider "azurerm" {
  features {}
}

variable "location" {
  type    = string
  default = "denmarkeast"
}

variable "rg_name" {
  type    = string
  default = "rg-bifrost-final"
}

# =========================================================================
# CORE INFRASTRUCTURE (RESOURCE GROUP & NETWORKING)
# =========================================================================

resource "azurerm_resource_group" "rg" {
  name     = var.rg_name
  location = var.location
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

# =========================================================================
# CONTAINER REGISTRY (ONDE FICA A TUA IMAGEM DOCKER CUSTOMIZADA)
# =========================================================================

resource "azurerm_container_registry" "acr" {
  name                = "acrbifrost${random_string.unique.result}"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  sku                 = "Basic"
  # admin_enabled = true simplifica a autenticação para um projeto académico
  # (username/password diretos). Em produção usar-se-ia uma Managed Identity.
  admin_enabled = true
}

# =========================================================================
# PERSISTENCE LAYER (STORAGE ACCOUNT & COSMOS DB)
# =========================================================================

resource "azurerm_storage_account" "storage" {
  name                     = "stbifrost${random_string.unique.result}"
  resource_group_name      = azurerm_resource_group.rg.name
  location                 = azurerm_resource_group.rg.location
  account_tier             = "Standard"
  account_replication_type = "LRS"
}

resource "azurerm_storage_container" "blob_container" {
  name                  = "historico-bruto"
  storage_account_name  = azurerm_storage_account.storage.name
  container_access_type = "private"
}

resource "azurerm_cosmosdb_account" "cosmos" {
  name                = "cosmos-bifrost-${random_string.unique.result}"
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

  capabilities {
    name = "EnableServerless"
  }
}

# =========================================================================
# COMPUTE LAYER (SERVERLESS BACKEND & CONTAINER FRONTEND)
# =========================================================================

# Plano para o Frontend (App Service Linux B1 para suportar Docker)
resource "azurerm_service_plan" "plan_app" {
  name                = "plan-bifrost-frontend"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  os_type             = "Linux"
  sku_name            = "B1"
}

resource "azurerm_linux_web_app" "frontend_app" {
  name                = "web-bifrost-${random_string.unique.result}"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  service_plan_id     = azurerm_service_plan.plan_app.id

  site_config {
    application_stack {
      # Aponta para a TUA imagem, dentro do TEU registry - não para
      # o nginx:alpine genérico do Docker Hub.
      docker_image_name        = "web-bifrost-frontend:latest"
      docker_registry_url      = "https://${azurerm_container_registry.acr.login_server}"
      docker_registry_username = azurerm_container_registry.acr.admin_username
      docker_registry_password = azurerm_container_registry.acr.admin_password
    }
  }

  app_settings = {
    # Garante que a Azure não faz cache eterna da imagem entre deploys.
    "WEBSITES_ENABLE_APP_SERVICE_STORAGE" = "false"
    "DOCKER_ENABLE_CI"                    = "true"
  }
}

# Plano para a Azure Function (Passa a Windows para contornar limites de Linux Workers)
resource "azurerm_service_plan" "plan_function" {
  name                = "plan-bifrost-serverless"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  os_type             = "Windows"
  sku_name            = "Y1"
}

resource "azurerm_windows_function_app" "backend_func" {
  name                = "func-recon-bifrost-${random_string.unique.result}"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name

  service_plan_id            = azurerm_service_plan.plan_function.id
  storage_account_name       = azurerm_storage_account.storage.name
  storage_account_access_key = azurerm_storage_account.storage.primary_access_key

  site_config {
    application_stack {
      node_version = "~18"
    }
  }

  # Necessário para o modelo de programação v4 (app.http(...) no ReconEngine.js)
  # ser indexado corretamente. Sem isto o host arranca mas não regista
  # nenhuma função, e qualquer chamada a /api/... devolve 404 vazio.
  # Fica aqui, em código, para não se perder num terraform apply futuro.
  app_settings = {
    AzureWebJobsFeatureFlags = "EnableWorkerIndexing"
  }
}

# =========================================================================
# SANDBOX LABORATORY (TARGET VM)
# =========================================================================

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
  size                = "Standard_B1s"
  admin_username      = "bifrostadmin"
  network_interface_ids = [
    azurerm_network_interface.vm_nic.id,
  ]

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

# =========================================================================
# UTILS
# =========================================================================

resource "random_string" "unique" {
  length  = 5
  special = false
  upper   = false
}
