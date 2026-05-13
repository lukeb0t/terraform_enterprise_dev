output "tfe_url" {
  description = "HTTPS URL of the Terraform Enterprise instance."
  value       = "https://${local.tfe_hostname}"
}

output "tfe_hostname" {
  description = "Public IP (or hostname) of the Terraform Enterprise instance."
  value       = local.tfe_hostname
}

output "public_ip" {
  description = "Static public IP address of the Terraform Enterprise instance."
  value       = azurerm_public_ip.tfe.ip_address
}

output "vm_id" {
  description = "Azure VM resource ID."
  value       = azurerm_linux_virtual_machine.tfe.id
}

output "resource_group_name" {
  description = "Resource group containing all TFE resources."
  value       = azurerm_resource_group.tfe.name
}

output "key_vault_name" {
  description = "Key Vault name used for bootstrap secrets."
  value       = azurerm_key_vault.tfe.name
}

output "key_vault_uri" {
  description = "Key Vault URI."
  value       = azurerm_key_vault.tfe.vault_uri
}

output "key_vault_admin_token_secret" {
  description = "Key Vault secret name for the TFE admin API token."
  value       = "admin-token"
}

output "key_vault_org_token_secret" {
  description = "Key Vault secret name for the TFE organization API token."
  value       = "org-token"
}

output "retrieve_admin_token_cmd" {
  description = "Shell command to retrieve the TFE admin token from Key Vault."
  value       = "az keyvault secret show --vault-name '${azurerm_key_vault.tfe.name}' --name 'admin-token' --query value -o tsv"
}

output "vnet_id" {
  description = "Resolved VNet ID used for the deployment."
  value       = local.create_networking ? azurerm_virtual_network.tfe[0].id : var.vnet_id
}

output "subnet_id" {
  description = "Resolved subnet ID used for the deployment."
  value       = local.subnet_id_resolved
}
