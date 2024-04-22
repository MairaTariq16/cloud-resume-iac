# Configure the Azure provider
terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.99.0"
    }
  }

  required_version = ">= 1.1.0"
}

provider "azurerm" {
  features {}
}

data azurerm_subscription "current_subscription" { }
output "current_subscription_id" {
  value = data.azurerm_subscription.current_subscription.id
}

# ------------------ Resource Group ------------------
resource "azurerm_resource_group" "rg" {
  name     = "cloudresumerg"
  location = "centralindia"
}

# ------------------ Key Vault ------------------
resource "azurerm_key_vault" "kv" {
  name                = "cloud-resume-kv"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  tenant_id           = data.azurerm_subscription.current_subscription.tenant_id
  sku_name            = "standard"
  enable_rbac_authorization = true
}

# ------------------ Storage Account ------------------
resource "azurerm_storage_account" "st" {
  name                     = "cloudresumewebstorage"
  resource_group_name      = azurerm_resource_group.rg.name
  location                 = azurerm_resource_group.rg.location
  account_tier             = "Standard"
  account_kind             = "StorageV2"
  account_replication_type = "LRS"
  static_website {
    index_document = "index.html"
  }
}

# ------------------ CDN Profile ------------------
resource "azurerm_cdn_profile" "cdn_profile" {
  name                = "cloud-resume-static-cdn"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  sku                 = "Standard_Microsoft"
}

# ------------------ CDN Endpoint ------------------
resource "azurerm_cdn_endpoint" "endpoint" {
  name                          = "cloud-resume-static"
  profile_name                  = azurerm_cdn_profile.cdn_profile.name
  location                      = azurerm_cdn_profile.cdn_profile.location
  resource_group_name           = azurerm_resource_group.rg.name
  is_http_allowed               = true
  is_https_allowed              = true
  querystring_caching_behaviour = "IgnoreQueryString"
  origin_host_header = azurerm_storage_account.st.primary_web_host // required for static website on storage account
  is_compression_enabled        = true
  content_types_to_compress = [
    "application/eot",
    "application/font",
    "application/font-sfnt",
    "application/javascript",
    "application/json",
    "application/opentype",
    "application/otf",
    "application/pkcs7-mime",
    "application/truetype",
    "application/ttf",
    "application/vnd.ms-fontobject",
    "application/xhtml+xml",
    "application/xml",
    "application/xml+rss",
    "application/x-font-opentype",
    "application/x-font-truetype",
    "application/x-font-ttf",
    "application/x-httpd-cgi",
    "application/x-javascript",
    "application/x-mpegurl",
    "application/x-opentype",
    "application/x-otf",
    "application/x-perl",
    "application/x-ttf",
    "font/eot",
    "font/ttf",
    "font/otf",
    "font/opentype",
    "image/svg+xml",
    "text/css",
    "text/csv",
    "text/html",
    "text/javascript",
    "text/js",
    "text/plain",
    "text/richtext",
    "text/tab-separated-values",
    "text/xml",
    "text/x-script",
    "text/x-component",
    "text/x-java-source",
  ]
  origin {
    name      = "cloud-resume-storage-origin"
    host_name = azurerm_storage_account.st.primary_web_host
  }
  delivery_rule {
    name  = "EnforceHTTPS"
    order = "1"

    request_scheme_condition {
      operator     = "Equal"
      match_values = ["HTTP"]
    }
    url_redirect_action {
      redirect_type = "Found"
      protocol      = "Https"
    }
  }
}

# ------------------ Custom Domain ------------------
resource "azurerm_cdn_endpoint_custom_domain" "custom_domain" {
  name            = "personal-domain"
  cdn_endpoint_id = azurerm_cdn_endpoint.endpoint.id
  host_name       = var.custom_domain
  cdn_managed_https {
    certificate_type = "Dedicated"
    protocol_type="ServerNameIndication"
  }
  depends_on = [ azurerm_cdn_endpoint.endpoint ]
}

# ------------------ CosmosDB ------------------
resource "azurerm_cosmosdb_account" "cosmosdb" {
  name                = "cloud-resume-cosmosdb"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  offer_type          = "Standard"
  kind                = "MongoDB"

  enable_automatic_failover = true

  capabilities {
    name = "EnableMongo"
  }
  capabilities {
    name = "EnableServerless"
  }
  consistency_policy {
    consistency_level       = "Session"
    max_interval_in_seconds = 5
    max_staleness_prefix    = 100
  }

  geo_location {
    location          = azurerm_resource_group.rg.location
    failover_priority = 0
  }

}

# ------------------ CosmosDB Database and Collection ------------------
resource "azurerm_cosmosdb_mongo_database" "metrics_database" {
  name                = "cloud-resume-metrics-db"
  resource_group_name = azurerm_cosmosdb_account.cosmosdb.resource_group_name
  account_name        = azurerm_cosmosdb_account.cosmosdb.name
}

resource "azurerm_cosmosdb_mongo_collection" "counts_collection" {
  name                = "counts"
  resource_group_name = azurerm_cosmosdb_account.cosmosdb.resource_group_name
  account_name        = azurerm_cosmosdb_account.cosmosdb.name
  database_name       = azurerm_cosmosdb_mongo_database.metrics_database.name
  index {
    keys   = ["_id"]
    unique = true
  }
}

# ------------------ Key Vault Secret for DB Connection String ------------------
resource "azurerm_key_vault_secret" "cosmosdb_connection_string" {
  name         = "cosmosdb-connection-string"
  value        = azurerm_cosmosdb_account.cosmosdb.primary_mongodb_connection_string
  key_vault_id = azurerm_key_vault.kv.id
}

# ------------------ App Service Plan ------------------
resource "azurerm_service_plan" "cloud_resume_service_plan" {
  name                = "cloud-resume-service-plan"
  resource_group_name = azurerm_resource_group.rg.name
  # location            = azurerm_resource_group.rg.location
  location            = "East US" # Due to quota restrictions in Central India
  os_type             = "Linux"
  sku_name            = "Y1"
}
# ------------------ Function App ------------------
resource "azurerm_linux_function_app" "cloud_resume_function_app" {
  name                = "cloud-resume-linux-function-app"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_service_plan.cloud_resume_service_plan.location

  storage_account_name       = azurerm_storage_account.st.name
  storage_account_access_key = azurerm_storage_account.st.primary_access_key
  service_plan_id            = azurerm_service_plan.cloud_resume_service_plan.id
  connection_string {
    name  = "COSMOSDB_CONNECTION_STRING"
    type  = "Custom"
    value = "@Microsoft.KeyVault(SecretUri=${azurerm_key_vault_secret.cosmosdb_connection_string.id}"
  }
  site_config {
    application_stack {
      node_version = "20"
    }

  }
  functions_extension_version = "~4"
  app_settings = {
    COSMOSDB_CONNECTION_STRING = "@Microsoft.KeyVault(SecretUri=${azurerm_key_vault_secret.cosmosdb_connection_string.id})"
    FUNCTIONS_WORKER_RUNTIME = "node"
    WEBSITE_NODE_DEFAULT_VERSION = "~20"
    LinuxFxVersion = "Node|20"
  }
  identity {
    type = "SystemAssigned"
  }
}

# # ------------------ Function App Function ------------------
# resource "azurerm_function_app_function" "counter_function" {
#   name            = "cloud-resume-counter-function"
#   function_app_id = azurerm_linux_function_app.cloud_resume_function_app.id
#   language        = "TypeScript"
#   config_json = jsonencode({
#     "bindings" = [
#       {
#         "authLevel" = "function"
#         "direction" = "in"
#         "methods" = [
#           "get",
#           "post",
#         ]
#         "name" = "req"
#         "type" = "httpTrigger"
#       },
#       {
#         "direction" = "out"
#         "name"      = "$return"
#         "type"      = "http"
#       },
#     ]
#   })
# }