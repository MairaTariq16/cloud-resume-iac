# Configure the Azure provider
terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.0.2"
    }
  }

  required_version = ">= 1.1.0"
}

provider "azurerm" {
  features {}
}

resource "azurerm_resource_group" "rg" {
  name     = "cloudresumerg"
  location = "centralindia"
}

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

resource "azurerm_storage_blob" "blob" {
  name                   = "index.html"
  storage_account_name   = azurerm_storage_account.st.name
  storage_container_name = "$web"
  type                   = "Block"
  content_type           = "text/html"
  source                 = "../cv-website/index.html"
}

