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
  default = "japaneast" 
}

variable "rg_name" {
  type    = string
  default = "rg-bifrost-final-v7" # Grupo novo para garantir sucesso limpo
}

# =========================================================================
# CORE INFRASTRUCTURE (RESOURCE GROUP)
# =========================================================================

resource "azurerm_resource_group" "rg" {
  name     = var.rg_name
  location = var.location
}

# =========================================================================
# CONTAINER REGISTRY
# =========================================================================

resource "azurerm_container_registry" "acr" {
  name                = "acrbifrost${random_string.unique.result}"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  sku                 = "Basic"
  admin_enabled       = true
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
      docker_image_name        = "web-bifrost-frontend:latest"
      docker_registry_url      = "https://${azurerm_container_registry.acr.login_server}"
      docker_registry_username = azurerm_container_registry.acr.admin_username
      docker_registry_password = azurerm_container_registry.acr.admin_password
    }
  }

  app_settings = {
    "WEBSITES_ENABLE_APP_SERVICE_STORAGE" = "false"
    "DOCKER_ENABLE_CI"                    = "true"
  }
}

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

  app_settings = {
    AzureWebJobsFeatureFlags = "EnableWorkerIndexing"
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
