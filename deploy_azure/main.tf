data "azurerm_client_config" "current" {}

locals {
  create_networking  = var.create_networking
  subnet_id_resolved = local.create_networking ? azurerm_subnet.tfe[0].id : var.subnet_id

  tfe_hostname = var.tfe_hostname != null ? var.tfe_hostname : azurerm_public_ip.tfe.ip_address

  # Key Vault names must be globally unique, 3-24 chars, alphanumeric + hyphens.
  kv_name = "${substr(var.cluster_name, 0, 13)}-kv-${random_id.kv_suffix.hex}"

  storage_container = var.storage_container_name != null ? var.storage_container_name : "${var.cluster_name}-tfe-data-${random_id.storage_suffix.hex}"

  explorer_db_host     = var.explorer_database_host != null ? var.explorer_database_host : "postgres:5432"
  explorer_db_user     = var.explorer_database_user != null ? var.explorer_database_user : var.database_user
  explorer_db_password = var.explorer_database_password != null ? var.explorer_database_password : random_password.database.result

  common_tags = merge({
    Module      = "tfe_deploy"
    ClusterName = var.cluster_name
  }, var.tags)
}

resource "random_password" "iact_token" {
  length  = 32
  special = false
}

resource "random_password" "database" {
  length  = 32
  special = false
}

# Fallback VM admin password when no SSH key is provided.
resource "random_password" "vm_admin" {
  length           = 20
  special          = true
  override_special = "!@#"
}

# Short random suffix to make the Key Vault name globally unique.
resource "random_id" "kv_suffix" {
  byte_length = 3
}

resource "random_id" "storage_suffix" {
  byte_length = 4
}

# ── Resource Group ─────────────────────────────────────────────────────────────

resource "azurerm_resource_group" "tfe" {
  name     = "${var.cluster_name}-tfe-rg"
  location = var.location
  tags     = local.common_tags
}

# ── Networking (optional) ──────────────────────────────────────────────────────

resource "azurerm_virtual_network" "tfe" {
  count               = local.create_networking ? 1 : 0
  name                = "${var.cluster_name}-vnet"
  resource_group_name = azurerm_resource_group.tfe.name
  location            = azurerm_resource_group.tfe.location
  address_space       = [var.vnet_address_space]
  tags                = local.common_tags
}

resource "azurerm_subnet" "tfe" {
  count                = local.create_networking ? 1 : 0
  name                 = "${var.cluster_name}-subnet"
  resource_group_name  = azurerm_resource_group.tfe.name
  virtual_network_name = azurerm_virtual_network.tfe[0].name
  address_prefixes     = [var.subnet_address_prefix]
}

# ── Network Security Group ─────────────────────────────────────────────────────

resource "azurerm_network_security_group" "tfe" {
  name                = "${var.cluster_name}-tfe-nsg"
  resource_group_name = azurerm_resource_group.tfe.name
  location            = azurerm_resource_group.tfe.location
  tags                = local.common_tags
}

resource "azurerm_network_security_rule" "https" {
  name                        = "HTTPS"
  priority                    = 100
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "443"
  source_address_prefixes     = var.allowed_ingress_cidrs
  destination_address_prefix  = "*"
  resource_group_name         = azurerm_resource_group.tfe.name
  network_security_group_name = azurerm_network_security_group.tfe.name
}

resource "azurerm_network_security_rule" "http" {
  name                        = "HTTP"
  priority                    = 110
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "80"
  source_address_prefixes     = var.allowed_ingress_cidrs
  destination_address_prefix  = "*"
  resource_group_name         = azurerm_resource_group.tfe.name
  network_security_group_name = azurerm_network_security_group.tfe.name
}

resource "azurerm_network_security_rule" "ssh" {
  count = length(var.ssh_ingress_cidr_blocks) > 0 ? 1 : 0

  name                        = "SSH"
  priority                    = 120
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "22"
  source_address_prefixes     = var.ssh_ingress_cidr_blocks
  destination_address_prefix  = "*"
  resource_group_name         = azurerm_resource_group.tfe.name
  network_security_group_name = azurerm_network_security_group.tfe.name
}

# ── Managed Identity ───────────────────────────────────────────────────────────

resource "azurerm_user_assigned_identity" "tfe" {
  name                = "${var.cluster_name}-tfe-identity"
  resource_group_name = azurerm_resource_group.tfe.name
  location            = azurerm_resource_group.tfe.location
  tags                = local.common_tags
}

# ── Key Vault ──────────────────────────────────────────────────────────────────

resource "azurerm_key_vault" "tfe" {
  name                       = local.kv_name
  resource_group_name        = azurerm_resource_group.tfe.name
  location                   = azurerm_resource_group.tfe.location
  tenant_id                  = data.azurerm_client_config.current.tenant_id
  sku_name                   = "standard"
  soft_delete_retention_days = 7
  purge_protection_enabled   = false
  rbac_authorization_enabled = true
  tags                       = local.common_tags
}

# VM managed identity can read and write secrets (stores admin/org tokens at boot).
resource "azurerm_role_assignment" "vm_kv" {
  scope                = azurerm_key_vault.tfe.id
  role_definition_name = "Key Vault Secrets Officer"
  principal_id         = azurerm_user_assigned_identity.tfe.principal_id
}

# Terraform executor can create TLS secrets at apply time.
resource "azurerm_role_assignment" "terraform_kv" {
  scope                = azurerm_key_vault.tfe.id
  role_definition_name = "Key Vault Secrets Officer"
  principal_id         = data.azurerm_client_config.current.object_id
}

# BYO TLS material stored in Key Vault at apply time.
resource "azurerm_key_vault_secret" "tls_cert" {
  count        = var.tls_cert_pem != null ? 1 : 0
  name         = "tls-cert"
  value        = var.tls_cert_pem
  key_vault_id = azurerm_key_vault.tfe.id
  depends_on   = [azurerm_role_assignment.terraform_kv]
  tags         = local.common_tags
}

resource "azurerm_key_vault_secret" "tls_key" {
  count        = var.tls_key_pem != null ? 1 : 0
  name         = "tls-key"
  value        = var.tls_key_pem
  key_vault_id = azurerm_key_vault.tfe.id
  depends_on   = [azurerm_role_assignment.terraform_kv]
  tags         = local.common_tags
}

resource "azurerm_key_vault_secret" "tls_bundle" {
  count        = var.tls_ca_bundle_pem != null ? 1 : 0
  name         = "tls-bundle"
  value        = var.tls_ca_bundle_pem
  key_vault_id = azurerm_key_vault.tfe.id
  depends_on   = [azurerm_role_assignment.terraform_kv]
  tags         = local.common_tags
}

# ── Object Storage ─────────────────────────────────────────────────────────────

resource "azurerm_storage_account" "tfe" {
  name                     = "${replace(var.cluster_name, "-", "")}tfe${random_id.storage_suffix.hex}"
  resource_group_name      = azurerm_resource_group.tfe.name
  location                 = azurerm_resource_group.tfe.location
  account_tier             = "Standard"
  account_replication_type = "LRS"
  tags                     = local.common_tags
}

resource "azurerm_storage_container" "tfe" {
  name                  = local.storage_container
  storage_account_id    = azurerm_storage_account.tfe.id
  container_access_type = "private"
}

resource "azurerm_role_assignment" "tfe_storage" {
  scope                = azurerm_storage_account.tfe.id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = azurerm_user_assigned_identity.tfe.principal_id
}

# ── Public IP ──────────────────────────────────────────────────────────────────

resource "azurerm_public_ip" "tfe" {
  name                = "${var.cluster_name}-tfe-pip"
  resource_group_name = azurerm_resource_group.tfe.name
  location            = azurerm_resource_group.tfe.location
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = local.common_tags
}

# ── Network Interface ──────────────────────────────────────────────────────────

resource "azurerm_network_interface" "tfe" {
  name                = "${var.cluster_name}-tfe-nic"
  resource_group_name = azurerm_resource_group.tfe.name
  location            = azurerm_resource_group.tfe.location
  tags                = local.common_tags

  ip_configuration {
    name                          = "tfe-ip-config"
    subnet_id                     = local.subnet_id_resolved
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.tfe.id
  }
}

resource "azurerm_network_interface_security_group_association" "tfe" {
  network_interface_id      = azurerm_network_interface.tfe.id
  network_security_group_id = azurerm_network_security_group.tfe.id
}

# ── Virtual Machine ────────────────────────────────────────────────────────────

resource "azurerm_linux_virtual_machine" "tfe" {
  name                  = "${var.cluster_name}-tfe-vm"
  resource_group_name   = azurerm_resource_group.tfe.name
  location              = azurerm_resource_group.tfe.location
  size                  = var.vm_size
  admin_username        = var.admin_username
  network_interface_ids = [azurerm_network_interface.tfe.id]

  disable_password_authentication = var.ssh_public_key != null

  dynamic "admin_ssh_key" {
    for_each = var.ssh_public_key != null ? [var.ssh_public_key] : []
    content {
      username   = var.admin_username
      public_key = admin_ssh_key.value
    }
  }

  # Fallback password when no SSH key is provided (break-glass access only).
  admin_password = var.ssh_public_key == null ? random_password.vm_admin.result : null

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.tfe.id]
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Premium_LRS"
    disk_size_gb         = var.os_disk_size_gb
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "0001-com-ubuntu-server-jammy"
    sku       = "22_04-lts-gen2"
    version   = "latest"
  }

  custom_data = base64encode(templatefile("${path.module}/templates/cloud-init.sh.tpl", {
    tfe_hostname                         = local.tfe_hostname
    tfe_license                          = var.tfe_license
    tfe_version                          = var.tfe_version
    iact_token                           = random_password.iact_token.result
    admin_email                          = var.admin_email
    admin_password                       = var.admin_password
    org_name                             = var.org_name
    key_vault_name                       = local.kv_name
    managed_identity_client_id           = azurerm_user_assigned_identity.tfe.client_id
    tls_cert_kv_secret                   = var.tls_cert_pem != null ? "tls-cert" : ""
    tls_key_kv_secret                    = var.tls_key_pem != null ? "tls-key" : ""
    tls_bundle_kv_secret                 = var.tls_ca_bundle_pem != null ? "tls-bundle" : ""
    database_name                        = var.database_name
    database_user                        = var.database_user
    database_password                    = random_password.database.result
    database_parameters                  = var.database_parameters
    storage_account_name                 = azurerm_storage_account.tfe.name
    storage_container                    = local.storage_container
    explorer_database_host               = local.explorer_db_host
    explorer_database_name               = var.explorer_database_name
    explorer_database_user               = local.explorer_db_user
    explorer_database_password           = local.explorer_db_password
    explorer_database_parameters         = var.explorer_database_parameters
    explorer_database_passwordless_azure = var.explorer_database_passwordless_azure
  }))

  tags = merge(local.common_tags, {
    Name = "${var.cluster_name}-tfe"
  })
}
