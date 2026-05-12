# Required for standalone use (terraform apply in this directory directly).
# When consuming this as a module, configure the azurerm provider in your root module instead.
provider "azurerm" {
  features {}
}
