# tfe_deploy_aws

Deploys Terraform Enterprise Flexible Deployment Options (disk mode) on a single Ubuntu 22.04 EC2 instance using Docker Compose, a self-signed TLS certificate, and a `nip.io` hostname.

## Architecture

```text
                    +-----------------------------+
Internet ---------> |  EIP + nip.io hostname      |
                    |  https://<eip>.nip.io       |
                    +--------------+--------------+
                                   |
                            80 / 443 to EC2
                                   |
                    +--------------v--------------+
                    | Ubuntu 22.04 EC2            |
                    | Docker + Docker Compose     |
                    | Terraform Enterprise (disk) |
                    +------+---------------+------+
                           |               |
                  gp3 root volume      AWS SSM Parameter Store
                  /var/lib/tfe         /tfe/<cluster>/admin-token
                                       /tfe/<cluster>/org-token
```

## Prerequisites

- AWS account with permissions to create EC2, IAM, VPC, and SSM resources
- Terraform 1.3+
- Terraform Enterprise license
- An email and strong password for the initial TFE admin user

## Usage

```hcl
module "tfe" {
  source = "./tfe_deploy_aws"

  cluster_name   = "my-tfe"
  tfe_license    = var.tfe_license
  admin_email    = "admin@example.com"
  admin_password = var.admin_password
}
```

## Quick start

1. Copy `terraform.tfvars.example` to `terraform.tfvars` and fill in the license and admin credentials.
2. Run `terraform init` in this module directory.
3. Run `terraform apply` to create networking, IAM, and the TFE EC2 instance.
4. Wait for cloud-init to finish; first boot typically takes 10-15 minutes.
5. Open the `tfe_url` output and retrieve the admin and org tokens from SSM if needed.

## Inputs

| Name | Type | Default | Description |
| --- | --- | --- | --- |
| `cluster_name` | `string` | n/a | Name prefix for all resources. |
| `tfe_version` | `string` | `"v202505-1"` | TFE Docker image tag to deploy. |
| `tfe_license` | `string` | n/a | TFE Enterprise license string. |
| `admin_email` | `string` | n/a | Email for the initial admin user. |
| `admin_password` | `string` | n/a | Initial admin password. |
| `org_name` | `string` | `"hashicorp-demo"` | TFE organization created during bootstrap. |
| `create_networking` | `bool` | `true` | Create a VPC/subnet inside this module. Set `false` when reusing an existing network such as `vault_deploy_aws` outputs. |
| `vpc_id` | `string` | `null` | Existing VPC ID; used when `create_networking = false`. |
| `subnet_id` | `string` | `null` | Existing subnet ID; required when `create_networking = false`. |
| `vpc_cidr` | `string` | `"10.101.0.0/16"` | CIDR for a new VPC. |
| `subnet_cidr` | `string` | `"10.101.1.0/24"` | CIDR for a new public subnet. |
| `instance_type` | `string` | `"m5.xlarge"` | EC2 instance size for TFE. |
| `root_volume_size_gb` | `number` | `200` | Root EBS volume size in GiB. |
| `key_pair_name` | `string` | `null` | Optional EC2 key pair for SSH. |
| `allowed_ingress_cidrs` | `list(string)` | `["0.0.0.0/0"]` | CIDRs allowed to reach TFE over 80/443. |
| `ssh_ingress_cidr_blocks` | `list(string)` | `[]` | CIDRs allowed to SSH to the instance. |
| `ssm_path_prefix` | `string` | `"/tfe"` | SSM prefix where tokens are stored. |
| `tags` | `map(string)` | `{}` | Extra AWS tags to apply. |

## Outputs

| Name | Description |
| --- | --- |
| `tfe_url` | HTTPS URL of the TFE instance. |
| `tfe_hostname` | `nip.io` hostname assigned to TFE. |
| `public_ip` | Elastic IP attached to the instance. |
| `instance_id` | EC2 instance ID. |
| `security_group_id` | Security group ID for the TFE host. |
| `ssm_prefix` | Base SSM path used by bootstrap. |
| `ssm_admin_token_path` | SSM path of the TFE admin API token. |
| `ssm_org_token_path` | SSM path of the TFE organization token. |
| `retrieve_admin_token_cmd` | Ready-to-run shell command for the admin token. |
| `vpc_id` | Resolved VPC ID. |
| `subnet_id` | Resolved subnet ID. |

## Retrieve tokens from SSM

```bash
aws ssm get-parameter \
  --name "/tfe/<cluster_name>/admin-token" \
  --with-decryption \
  --region <region> \
  --query Parameter.Value --output text

aws ssm get-parameter \
  --name "/tfe/<cluster_name>/org-token" \
  --with-decryption \
  --region <region> \
  --query Parameter.Value --output text
```

## References

- [Terraform Enterprise Flexible Deployment Options](https://developer.hashicorp.com/terraform/enterprise/flexible-deployments)
- [Terraform Enterprise Docker installation](https://developer.hashicorp.com/terraform/enterprise/deploy/docker)
- [Terraform Enterprise configuration reference](https://developer.hashicorp.com/terraform/enterprise/deploy/reference/configuration)
