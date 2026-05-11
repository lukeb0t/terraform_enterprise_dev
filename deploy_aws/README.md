# tfe_deploy_aws

Deploys Terraform Enterprise (disk mode) on a single Ubuntu 22.04 EC2 instance using Docker Compose and a self-signed TLS certificate. TFE is accessed directly by its Elastic IP address. Consumers can add their own DNS record pointing to the EIP if a hostname is needed.

The compose configuration follows the [official HashiCorp disk-mode example](https://developer.hashicorp.com/terraform/enterprise/deploy/docker) exactly.

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

## How it works

### TLS and CA trust

cloud-init generates a self-signed certificate for the instance's Elastic IP address (using an IP SAN, not a DNS SAN) and writes it to `/etc/tfe-tls/`. The TFE container's `TFE_TLS_CA_BUNDLE_FILE` causes TFE to add this cert to its own OS trust store on startup.

When a workspace run is queued, the `task-worker-bootstrap` script (bundled inside the TFE image) automatically:
1. Loads the `tfe-agent.tar` base image included in the TFE image.
2. Copies `/etc/ssl/certs/ca-certificates.crt` (which now includes the self-signed cert) into a build context.
3. Builds `hashicorp/tfc-agent:now` with the cert baked in.

Agent containers spawned for each run therefore trust TFE's self-signed endpoint without any custom image or manual cert injection.

### Terraform binary cache

The Docker named volume `terraform-enterprise-cache` is mounted at `/var/cache/tfe-task-worker/terraform` inside the TFE container. When a run starts, `task-worker` downloads the required Terraform binary into this volume. The ephemeral agent container then mounts the same volume **read-only** at `/tmp/terraform` and executes the pre-downloaded binary directly.

## Prerequisites

- AWS account with permissions to create EC2, IAM, VPC, and SSM resources
- Terraform 1.3+
- Terraform Enterprise license

## Quick start

1. Copy `terraform.tfvars.example` to `terraform.tfvars` and fill in your values.
2. Run `terraform init`.
3. Run `terraform apply`.
4. Wait ~10–15 minutes for cloud-init to complete — TFE pulls its image and bootstraps on first boot.
5. Open the `tfe_url` output in a browser (accept the self-signed cert warning).
6. Retrieve tokens from SSM as shown below.

## Inputs

| Name | Type | Default | Description |
| --- | --- | --- | --- |
| `cluster_name` | `string` | n/a | Name prefix for all resources. |
| `tfe_version` | `string` | `"v202505-1"` | TFE Docker image tag to deploy. |
| `tfe_license` | `string` | n/a | TFE Enterprise license string. |
| `admin_email` | `string` | n/a | Email for the initial TFE admin user. |
| `admin_password` | `string` | n/a | Initial admin password (min 8 chars, mixed case + number + symbol recommended). |
| `org_name` | `string` | `"hashicorp-demo"` | TFE organization created during bootstrap. |
| `create_networking` | `bool` | `true` | Create a VPC/subnet. Set `false` when reusing an existing network. |
| `vpc_id` | `string` | `null` | Existing VPC ID; required when `create_networking = false`. |
| `subnet_id` | `string` | `null` | Existing subnet ID; required when `create_networking = false`. |
| `vpc_cidr` | `string` | `"10.101.0.0/16"` | CIDR for the new VPC. |
| `subnet_cidr` | `string` | `"10.101.1.0/24"` | CIDR for the new public subnet. |
| `instance_type` | `string` | `"m5.large"` | EC2 instance size. TFE requires at least 4 vCPU / 8 GB RAM. |
| `root_volume_size_gb` | `number` | `200` | Root EBS volume size in GiB (holds TFE application data). |
| `key_pair_name` | `string` | `null` | EC2 key pair for SSH. Also requires `ssh_ingress_cidr_blocks`. |
| `allowed_ingress_cidrs` | `list(string)` | `["0.0.0.0/0"]` | CIDRs allowed to reach TFE on ports 80/443. |
| `ssh_ingress_cidr_blocks` | `list(string)` | `[]` | CIDRs allowed SSH (port 22). Empty = SSM-only access. |
| `ssm_path_prefix` | `string` | `"/tfe"` | SSM Parameter Store prefix for bootstrap tokens. |
| `tags` | `map(string)` | `{}` | Extra AWS tags applied to all resources. |

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

## Sensitive files — do not commit

| File | Contains |
| --- | --- |
| `terraform.tfvars` | License key, admin password |
| `terraform.tfstate` | IACT token, SSM paths, resource IDs |
| `.terraform/` | Provider binaries |

All three are covered by `.gitignore`. Use `terraform.tfvars.example` as a template.

## References

- [Deploy TFE to Docker](https://developer.hashicorp.com/terraform/enterprise/deploy/docker)
- [TFE configuration reference](https://developer.hashicorp.com/terraform/enterprise/deploy/reference/configuration)
- [TFE data storage overview](https://developer.hashicorp.com/terraform/enterprise/deploy/configuration/storage)
