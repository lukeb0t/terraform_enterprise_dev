# terraform_enterprise_dev

Terraform modules for deploying Terraform Enterprise (TFE) on Docker Compose.

## Modules

| Module | Description |
| --- | --- |
| [`deploy_aws`](./deploy_aws) | Deploys TFE on a single EC2 instance (Ubuntu 22.04) with an Elastic IP and SSM-backed secrets. |
| [`deploy_azure`](./deploy_azure) | Deploys TFE on a single Azure VM (Ubuntu 22.04) with a static public IP and Key Vault-backed secrets. |

Both modules support self-signed certificates (default) and BYO TLS certificates, optional BYO networking, and produce an admin API token at bootstrap.

## References

- [Deploy TFE to Docker](https://developer.hashicorp.com/terraform/enterprise/deploy/docker)
- [TFE configuration reference](https://developer.hashicorp.com/terraform/enterprise/deploy/reference/configuration)
