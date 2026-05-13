# tfe_deploy_aws

Deploys Terraform Enterprise on a single Ubuntu 22.04 EC2 instance using Docker Compose in external operational mode with TFE Explorer enabled.

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
                    |  postgres:16 sidecar        |
                    |  TFE container (read-only)  |
                    |  cache volume (rw)          |
                    +------+---------------+------+
                           |               |
                  gp3 root volume      AWS SSM Parameter Store
                                       /tfe/<cluster>/admin-token
                                       /tfe/<cluster>/org-token
                           |
                           +------ S3 bucket
                                   TFE object data
```

## Prerequisites

- AWS account with permissions to create EC2, IAM, VPC, S3, and SSM resources
- Terraform Enterprise license (version 2.0.1 or later required for Explorer)

## Quick start

1. Copy `terraform.tfvars.example` to `terraform.tfvars` and fill in your values.
2. Run `terraform init`.
3. Run `terraform apply`.
4. Wait ~10 minutes for cloud-init to complete — TFE pulls its image, runs database migrations, and bootstraps on first boot.
5. Open the `tfe_url` output in a browser (accept the self-signed cert warning, if using self-signed certs).
6. Retrieve tokens from SSM as shown below.

## Inputs

| Name | Type | Required | Default | Description |
| --- | --- | --- | --- | --- |
| `cluster_name` | `string` | yes | — | Name prefix for all resources. |
| `tfe_license` | `string` | yes | — | TFE Enterprise license string. |
| `admin_email` | `string` | yes | — | Email for the initial TFE admin user. |
| `admin_password` | `string` | yes | — | Initial admin password (min 8 chars, mixed case + number + symbol recommended). |
| `tfe_version` | `string` | no | `"2.0.1"` | TFE Docker image tag to deploy. |
| `org_name` | `string` | no | `"hashicorp-demo"` | TFE organization created during bootstrap. |
| `create_networking` | `bool` | no | `true` | Create a VPC/subnet. Set `false` when reusing an existing network. |
| `vpc_id` | `string` | no | `null` | Existing VPC ID; required when `create_networking = false`. |
| `subnet_id` | `string` | no | `null` | Existing subnet ID; required when `create_networking = false`. |
| `vpc_cidr` | `string` | no | `"10.101.0.0/16"` | CIDR for the new VPC. |
| `subnet_cidr` | `string` | no | `"10.101.1.0/24"` | CIDR for the new public subnet. |
| `instance_type` | `string` | no | `"m5.large"` | EC2 instance size. |
| `root_volume_size_gb` | `number` | no | `200` | Root EBS volume size in GiB. |
| `key_pair_name` | `string` | no | `null` | EC2 key pair for SSH. Also requires `ssh_ingress_cidr_blocks`. |
| `allowed_ingress_cidrs` | `list(string)` | no | `["0.0.0.0/0"]` | CIDRs allowed to reach TFE on ports 80/443. |
| `ssh_ingress_cidr_blocks` | `list(string)` | no | `[]` | CIDRs allowed SSH (port 22). Empty = SSM-only access. |
| `ssm_path_prefix` | `string` | no | `"/tfe"` | SSM Parameter Store prefix for bootstrap tokens. |
| `tfe_hostname` | `string` | no | EIP | Overrides the hostname used for TLS and TFE URLs. Set when providing a cert issued for a domain name. |
| `tls_cert_pem` | `string` | no | `null` | PEM-encoded TLS certificate. All three `tls_*` vars must be set together to skip self-signed generation. |
| `tls_key_pem` | `string` | no | `null` | PEM-encoded TLS private key. |
| `tls_ca_bundle_pem` | `string` | no | `null` | PEM-encoded CA bundle. Should include the signing CA so TFE and agent containers trust the certificate. |
| `database_name` | `string` | no | `"tfe"` | PostgreSQL database name for the local postgres sidecar. |
| `database_user` | `string` | no | `"tfe"` | PostgreSQL username for the local postgres sidecar. |
| `database_parameters` | `string` | no | `"sslmode=disable"` | Additional PostgreSQL connection parameters for the main TFE database. |
| `storage_bucket_name` | `string` | no | `null` | Override the auto-generated S3 bucket name. Must be globally unique. |
| `explorer_database_host` | `string` | no | `null` | Explorer PostgreSQL host. Defaults to the local postgres sidecar. |
| `explorer_database_name` | `string` | no | `"tfe_explorer"` | Explorer PostgreSQL database name. |
| `explorer_database_user` | `string` | no | `null` | Explorer PostgreSQL username. Defaults to `database_user`. |
| `explorer_database_password` | `string` | no | `null` | Explorer PostgreSQL password. Defaults to the generated main DB password. |
| `explorer_database_parameters` | `string` | no | `"sslmode=disable"` | Additional PostgreSQL connection parameters for Explorer. |
| `explorer_database_passwordless_aws` | `bool` | no | `false` | Use EC2 instance profile IAM authentication for the Explorer database (RDS IAM auth). |
| `explorer_database_aws_region` | `string` | no | current region | AWS region for Explorer IAM database auth. |
| `tags` | `map(string)` | no | `{}` | Extra AWS tags applied to all resources. |

## Outputs

| Name | Description |
| --- | --- |
| `tfe_url` | HTTPS URL of the TFE instance (`https://<eip>`). |
| `tfe_hostname` | Public IP (Elastic IP) of the TFE instance. |
| `public_ip` | Elastic IP attached to the instance. |
| `instance_id` | EC2 instance ID. |
| `security_group_id` | Security group ID for the TFE host. |
| `s3_bucket_name` | S3 bucket used for TFE object storage. |
| `database_name` | PostgreSQL database name for TFE. |
| `database_user` | PostgreSQL user for TFE. |
| `ssm_prefix` | Base SSM path used by bootstrap. |
| `ssm_admin_token_path` | SSM path for the TFE admin API token. |
| `ssm_org_token_path` | SSM path for the TFE organization token. |
| `retrieve_admin_token_cmd` | Ready-to-run `aws ssm` command to retrieve the admin token. |
| `vpc_id` | Resolved VPC ID. |
| `subnet_id` | Resolved subnet ID. |

## External mode defaults

The module deploys TFE in `external` operational mode with:

- a local `postgres:16` sidecar for the main TFE and Explorer databases
- S3 for object storage via EC2 instance profile (no credentials required)
- `sslmode=disable` for both database connections (appropriate for the local postgres sidecar)
- a bootstrap PostgreSQL init script that creates required schemas/extensions and the `tfe_explorer` database

Explorer is configured only with official `TFE_EXPLORER_DATABASE_*` environment variables and is enabled by default using the postgres sidecar.

## TFE Explorer

Explorer is available at `https://<tfe_hostname>/app/<org_name>/explorer` once TFE is running. Query across workspaces using the API:

```bash
curl -s \
  -H "Authorization: Bearer <admin_token>" \
  "https://<tfe_hostname>/api/v2/organizations/<org_name>/explorer?type=workspaces" | jq .
```

Available query types: `workspaces`, `tf_versions`, `providers`, `modules`.

## Bring your own networking

By default the module creates a new VPC and public subnet. To deploy into an existing network, set `create_networking = false` and supply your own IDs:

```hcl
create_networking = false
vpc_id            = "vpc-0abc123"
subnet_id         = "subnet-0def456"
```

The subnet must be public (or have a route to the internet via NAT) so the EC2 instance can reach the TFE image registry and AWS SSM endpoints. The module attaches an Elastic IP to the instance regardless of which networking path is used.

## Bring your own certificate

By default the module generates a self-signed certificate on first boot using the instance's Elastic IP as the Subject Alternative Name. To use a certificate from your own CA instead, supply all three `tls_*` variables:

```hcl
tfe_hostname      = "tfe.example.com"  # hostname the cert was issued for
tls_cert_pem      = file("tfe.crt")    # PEM certificate (leaf + intermediates)
tls_key_pem       = file("tfe.key")    # PEM private key
tls_ca_bundle_pem = file("ca.crt")     # PEM CA bundle (used by TFE agent containers)
```

> All three `tls_*` variables must be set together — supplying only some of them has no effect and the module will fall back to a self-signed cert.

The certificate material is stored in AWS SSM Parameter Store as `SecureString` values at apply time. The instance fetches them over SSM at boot — this avoids the 16 KB EC2 user-data size limit that would be hit by embedding PEM content directly.

If your cert is issued for a domain name rather than a bare IP, set `tfe_hostname` to that domain and point its DNS A record to the `public_ip` output after apply.

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

## Troubleshooting

Infrastructure deploys successfully but TFE never comes online? The most common cause is a bad or expired license. Use the steps below to diagnose from the EC2 instance.

### 1. Connect to the instance

SSM Session Manager (no key pair required):

```bash
aws ssm start-session --target <instance_id> --region <region>
```

If you provided a `key_pair_name`, you can also SSH directly:

```bash
ssh ubuntu@<public_ip>
```

### 2. Check the bootstrap log

All cloud-init activity is written to `/var/log/tfe-init.log`:

```bash
tail -100 /var/log/tfe-init.log
```

A bad license causes the Docker registry login to fail immediately — look for:

```
Error response from daemon: unauthorized: ... license
```

or the health-check timeout at the end of bootstrap:

```
ERROR: TFE did not become healthy after 10 minutes
```

### 3. Check the container status

```bash
# See if the containers are running, restarting, or have exited
docker ps -a --filter name=terraform-enterprise

# Check the Docker Compose service status
docker compose -f /etc/tfe/compose.yaml ps
```

A container in `Exited` or constant `Restarting` state almost always indicates a license or configuration problem.

### 4. Inspect the TFE container logs

```bash
# Last 100 lines — license errors surface here
docker compose -f /etc/tfe/compose.yaml logs --tail=100 tfe

# Or stream live
docker compose -f /etc/tfe/compose.yaml logs -f tfe
```

A bad license typically produces one of these messages:

- `invalid license`
- `license is expired`
- `failed to validate license`
- `unauthorized` during the registry login step

### 5. Check the internal supervisor and health endpoint

```bash
# Confirm the task-worker process is up inside the container
docker exec terraform-enterprise-tfe-1 supervisorctl status

# Hit the health endpoint (returns 200 when TFE is fully ready)
curl -sk -o /dev/null -w "%{http_code}\n" https://localhost/api/v1/health/readiness
```

### 6. Fixing a bad license

1. Obtain a valid license string from your HashiCorp account.
2. Update `tfe_license` in your `terraform.tfvars`.
3. Re-run `terraform apply` — this replaces the instance and re-runs cloud-init with the corrected value.

## References

- [Deploy TFE to Docker](https://developer.hashicorp.com/terraform/enterprise/deploy/docker)
- [TFE configuration reference](https://developer.hashicorp.com/terraform/enterprise/deploy/reference/configuration)
- [Connect to PostgreSQL](https://developer.hashicorp.com/terraform/enterprise/deploy/configuration/storage/connect-database/postgres)
- [Enable TFE Explorer](https://developer.hashicorp.com/terraform/enterprise/deploy/configuration/enable-explorer)
- [TFE data storage overview](https://developer.hashicorp.com/terraform/enterprise/deploy/configuration/storage)
