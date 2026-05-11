# tfe_deploy_aws

Deploys Terraform Enterprise on a single Ubuntu 22.04 EC2 instance using Docker Compose. 

## Architecture

```text
                    +-----------------------------+
Internet ---------> |  Elastic IP                 |
                    |  https://<eip>              |
                    +--------------+--------------+
                                   |
                            80 / 443 to EC2
                                   |
                    +--------------v--------------+
                    | Ubuntu 22.04 EC2            |
                    | Docker + Docker Compose     |
                    |                             |
                    |  TFE container (read-only)  |
                    |  +-----------------------+  |
                    |  | /var/lib/tfe (bind)   |  |  <-- gp3 EBS (application data)
                    |  | /etc/tfe-tls (bind)   |  |  <-- self-signed TLS cert
                    |  | cache volume (rw)     |  |  <-- Terraform binary cache
                    |  +-----------------------+  |
                    |                             |
                    +------+---------------+------+
                           |               |
                  gp3 root volume      AWS SSM Parameter Store
                  /var/lib/tfe         /tfe/<cluster>/admin-token
                                       /tfe/<cluster>/org-token
```

## Prerequisites

- AWS account with permissions to create EC2, IAM, VPC, and SSM resources
- Terraform Enterprise license

## Quick start

1. Copy `terraform.tfvars.example` to `terraform.tfvars` and fill in your values.
2. Run `terraform init`.
3. Run `terraform apply`.
4. Wait ~5 minutes for cloud-init to complete — TFE pulls its image and bootstraps on first boot.
5. Open the `tfe_url` output in a browser (accept the self-signed cert warning, if using self-signed certs).
6. Retrieve tokens from SSM as shown below.

## Inputs

| Name | Type | Required | Default | Description |
| --- | --- | --- | --- | --- |
| `cluster_name` | `string` | yes | — | Name prefix for all resources. |
| `tfe_license` | `string` | yes | — | TFE Enterprise license string. |
| `admin_email` | `string` | yes | — | Email for the initial TFE admin user. |
| `admin_password` | `string` | yes | — | Initial admin password (min 8 chars, mixed case + number + symbol recommended). |
| `tfe_version` | `string` | no | `"v202505-1"` | TFE Docker image tag to deploy. |
| `org_name` | `string` | no | `"hashicorp-demo"` | TFE organization created during bootstrap. |
| `create_networking` | `bool` | no | `true` | Create a VPC/subnet. Set `false` when reusing an existing network. |
| `vpc_id` | `string` | no | `null` | Existing VPC ID; required when `create_networking = false`. |
| `subnet_id` | `string` | no | `null` | Existing subnet ID; required when `create_networking = false`. |
| `vpc_cidr` | `string` | no | `"10.101.0.0/16"` | CIDR for the new VPC. |
| `subnet_cidr` | `string` | no | `"10.101.1.0/24"` | CIDR for the new public subnet. |
| `instance_type` | `string` | no | `"m5.large"` | EC2 instance size. TFE requires at least 4 vCPU / 8 GB RAM. |
| `root_volume_size_gb` | `number` | no | `200` | Root EBS volume size in GiB (holds TFE application data). |
| `key_pair_name` | `string` | no | `null` | EC2 key pair for SSH. Also requires `ssh_ingress_cidr_blocks`. |
| `allowed_ingress_cidrs` | `list(string)` | no | `["0.0.0.0/0"]` | CIDRs allowed to reach TFE on ports 80/443. |
| `ssh_ingress_cidr_blocks` | `list(string)` | no | `[]` | CIDRs allowed SSH (port 22). Empty = SSM-only access. |
| `ssm_path_prefix` | `string` | no | `"/tfe"` | SSM Parameter Store prefix for bootstrap tokens. |
| `tfe_hostname` | `string` | no | EIP | Overrides the hostname used for TLS and TFE URLs. Set this when providing a cert issued for a domain name. |
| `tls_cert_pem` | `string` | no | `null` | PEM-encoded TLS certificate. All three `tls_*` vars must be set together to skip self-signed generation. |
| `tls_key_pem` | `string` | no | `null` | PEM-encoded TLS private key. |
| `tls_ca_bundle_pem` | `string` | no | `null` | PEM-encoded CA bundle. Should include the signing CA so TFE and agent containers trust the certificate. |
| `tags` | `map(string)` | no | `{}` | Extra AWS tags applied to all resources. |

## Outputs

| Name | Description |
| --- | --- |
| `tfe_url` | HTTPS URL of the TFE instance (`https://<eip>`). |
| `tfe_hostname` | Public IP (Elastic IP) of the TFE instance. |
| `public_ip` | Elastic IP attached to the instance. |
| `instance_id` | EC2 instance ID. |
| `security_group_id` | Security group ID for the TFE host. |
| `ssm_prefix` | Base SSM path used by bootstrap. |
| `ssm_admin_token_path` | SSM path for the TFE admin API token. |
| `ssm_org_token_path` | SSM path for the TFE organization token. |
| `retrieve_admin_token_cmd` | Ready-to-run `aws ssm` command to retrieve the admin token. |
| `vpc_id` | Resolved VPC ID. |
| `subnet_id` | Resolved subnet ID. |

## Retrieve tokens from SSM

```bash
# Admin token (used for API calls and workspace runs)
aws ssm get-parameter \
  --name "/tfe/<cluster_name>/admin-token" \
  --with-decryption \
  --region <region> \
  --query Parameter.Value --output text

# Organization token
aws ssm get-parameter \
  --name "/tfe/<cluster_name>/org-token" \
  --with-decryption \
  --region <region> \
  --query Parameter.Value --output text
```

## References

- [Deploy TFE to Docker](https://developer.hashicorp.com/terraform/enterprise/deploy/docker)
- [TFE configuration reference](https://developer.hashicorp.com/terraform/enterprise/deploy/reference/configuration)
- [TFE data storage overview](https://developer.hashicorp.com/terraform/enterprise/deploy/configuration/storage)
