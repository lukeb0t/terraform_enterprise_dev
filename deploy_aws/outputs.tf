output "tfe_url" {
  description = "HTTPS URL of the Terraform Enterprise instance."
  value       = "https://${local.tfe_hostname}"
}

output "tfe_hostname" {
  description = "Hostname assigned to Terraform Enterprise via nip.io."
  value       = local.tfe_hostname
}

output "public_ip" {
  description = "Elastic IP address of the Terraform Enterprise instance."
  value       = aws_eip.tfe.public_ip
}

output "instance_id" {
  description = "EC2 instance ID running Terraform Enterprise."
  value       = aws_instance.tfe.id
}

output "security_group_id" {
  description = "Security group attached to the Terraform Enterprise instance."
  value       = aws_security_group.tfe.id
}

output "ssm_prefix" {
  description = "SSM Parameter Store prefix used by the bootstrap process."
  value       = local.ssm_prefix
}

output "ssm_admin_token_path" {
  description = "SSM Parameter Store path for the TFE admin API token."
  value       = "${local.ssm_prefix}/admin-token"
}

output "ssm_org_token_path" {
  description = "SSM Parameter Store path for the TFE organization API token."
  value       = "${local.ssm_prefix}/org-token"
}

output "retrieve_admin_token_cmd" {
  description = "Shell command to retrieve the TFE admin token from SSM."
  value       = "aws ssm get-parameter --name '${local.ssm_prefix}/admin-token' --with-decryption --region ${data.aws_region.current.name} --query Parameter.Value --output text"
}

output "vpc_id" {
  description = "Resolved VPC ID used for the deployment."
  value       = local.vpc_id_resolved
}

output "subnet_id" {
  description = "Resolved subnet ID used for the deployment."
  value       = local.subnet_id_resolved
}
