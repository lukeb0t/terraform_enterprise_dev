# tfe_deploy_azure

Deploys Terraform Enterprise on a single Ubuntu 22.04 Azure VM using Docker Compose.

## Architecture

```text
                    +-----------------------------+
Internet ---------> |  Static Public IP           |
                    |  https://<pip>              |
                    +--------------+--------------+
                                   |
                            80 / 443 to VM
                                   |
                    +--------------v--------------+
                    | Ubuntu 22.04 Azure VM       |
                    | Docker + Docker Compose     |
                    |                             |
                    |  TFE container (read-only)  |
                    |  +-----------------------+  |
                    |  | /var/lib/tfe (bind)   |  |  <-- Premium_LRS OS disk (application data)
                    |  | /etc/tfe-tls (bind)   |  |  <-- self-signed or BYO TLS cert
                    |  | cache volume (rw)     |  |  <-- Terraform binary cache
                    |  +-----------------------+  |
                    |                             |
                    +------+---------------+------+
                           |               |
                  Premium_LRS OS disk   Azure Key Vault
                  /var/lib/tfe          admin-token
                                        org-token
```

## Prerequisites

- Azure subscription with permissions to create VMs, VNets, Key Vaults, and Managed Identities
- Terraform Enterprise license
- Azure credentials configured (via `az login` or `ARM_*` environment variables)

## Quick start

1. Copy `terraform.tfvars.example` to `terraform.tfvars` and fill in your values.
2. Run `terraform init`.
3. Run `terraform apply`.
4. Wait ~5 minutes for cloud-init to complete — TFE pulls its image and bootstraps on first boot.
5. Open the `tfe_url` output in a browser (accept the self-signed cert warning, if using self-signed certs).
6. Retrieve tokens from Key Vault as shown below.

## Inputs

| Name | Type | Required | Default | Description |
| --- | --- | --- | --- | --- |
| `cluster_name` | `string` | yes | — | Name prefix for all resources. |
| `location` | `string` | yes | — | Azure region (e.g. `"eastus"`). |
| `tfe_license` | `string` | yes | — | TFE Enterprise license string. |
| `admin_email` | `string` | yes | — | Email for the initial TFE admin user. |
| `admin_password` | `string` | yes | — | Initial admin password (min 8 chars, mixed case + number + symbol recommended). |
| `tfe_version` | `string` | no | `"v202505-1"` | TFE Docker image tag to deploy. |
| `org_name` | `string` | no | `"hashicorp-demo"` | TFE organization created during bootstrap. |
| `create_networking` | `bool` | no | `true` | Create a VNet/subnet. Set `false` when reusing an existing network. |
| `vnet_id` | `string` | no | `null` | Existing VNet ID; used in outputs when `create_networking = false`. |
| `subnet_id` | `string` | no | `null` | Existing subnet ID; required when `create_networking = false`. |
| `vnet_address_space` | `string` | no | `"10.101.0.0/16"` | Address space for the new VNet. |
| `subnet_address_prefix` | `string` | no | `"10.101.1.0/24"` | Address prefix for the new subnet. |
| `vm_size` | `string` | no | `"Standard_D2s_v3"` | Azure VM size. 8 GB RAM minimum recommended. |
| `os_disk_size_gb` | `number` | no | `200` | OS disk size in GiB (holds TFE application data). |
| `admin_username` | `string` | no | `"tfeadmin"` | Local admin username on the VM. |
| `ssh_public_key` | `string` | no | `null` | SSH public key for the admin user. When null, password auth is enabled with a random password. |
| `allowed_ingress_cidrs` | `list(string)` | no | `["0.0.0.0/0"]` | CIDRs allowed to reach TFE on ports 80/443. |
| `ssh_ingress_cidr_blocks` | `list(string)` | no | `[]` | CIDRs allowed SSH (port 22). Empty = no SSH NSG rule. |
| `tfe_hostname` | `string` | no | Public IP | Overrides the hostname used for TLS and TFE URLs. Set when providing a cert issued for a domain name. |
| `tls_cert_pem` | `string` | no | `null` | PEM-encoded TLS certificate. All three `tls_*` vars must be set together to skip self-signed generation. |
| `tls_key_pem` | `string` | no | `null` | PEM-encoded TLS private key. |
| `tls_ca_bundle_pem` | `string` | no | `null` | PEM-encoded CA bundle. Should include the signing CA so TFE and agent containers trust the certificate. |
| `tags` | `map(string)` | no | `{}` | Extra Azure tags applied to all resources. |

## Outputs

| Name | Description |
| --- | --- |
| `tfe_url` | HTTPS URL of the TFE instance. |
| `tfe_hostname` | Public IP (or hostname) of the TFE instance. |
| `public_ip` | Static public IP address. |
| `vm_id` | Azure VM resource ID. |
| `resource_group_name` | Resource group containing all TFE resources. |
| `key_vault_name` | Key Vault name used for bootstrap secrets. |
| `key_vault_uri` | Key Vault URI. |
| `key_vault_admin_token_secret` | Key Vault secret name for the TFE admin API token. |
| `key_vault_org_token_secret` | Key Vault secret name for the TFE organization API token. |
| `retrieve_admin_token_cmd` | Ready-to-run `az keyvault` command to retrieve the admin token. |
| `vnet_id` | Resolved VNet ID. |
| `subnet_id` | Resolved subnet ID. |

## Bring your own networking

By default the module creates a new VNet and subnet. To deploy into an existing network, set `create_networking = false` and supply the subnet ID:

```hcl
create_networking = false
subnet_id         = "/subscriptions/.../subnets/my-subnet"
vnet_id           = "/subscriptions/.../virtualNetworks/my-vnet"  # optional, for outputs only
```

The subnet must have internet access (direct or via NAT gateway) so the VM can reach the TFE image registry and Azure IMDS/Key Vault endpoints. The module always creates the resource group, NSG, public IP, and Key Vault in `var.location` regardless of which networking path is used.

## Bring your own certificate

By default the module generates a self-signed certificate on first boot using the VM's static public IP as the Subject Alternative Name. To use a certificate from your own CA instead, supply all three `tls_*` variables:

```hcl
tfe_hostname      = "tfe.example.com"  # hostname the cert was issued for
tls_cert_pem      = file("tfe.crt")    # PEM certificate (leaf + intermediates)
tls_key_pem       = file("tfe.key")    # PEM private key
tls_ca_bundle_pem = file("ca.crt")    # PEM CA bundle (used by TFE agent containers)
```

> All three `tls_*` variables must be set together — supplying only some of them has no effect and the module will fall back to a self-signed cert.

The certificate material is stored in Azure Key Vault as secrets at apply time. The VM fetches them via the Azure Instance Metadata Service (IMDS) using the managed identity at boot — no Azure CLI installation required.

If your cert is issued for a domain name, set `tfe_hostname` to that domain and point its DNS A record to the `public_ip` output after apply.

## Retrieve tokens from Key Vault

```bash
# Admin token (used for API calls and workspace runs)
az keyvault secret show \
  --vault-name "<key_vault_name>" \
  --name "admin-token" \
  --query value -o tsv

# Organization token
az keyvault secret show \
  --vault-name "<key_vault_name>" \
  --name "org-token" \
  --query value -o tsv
```

## References

- [Deploy TFE to Docker](https://developer.hashicorp.com/terraform/enterprise/deploy/docker)
- [TFE configuration reference](https://developer.hashicorp.com/terraform/enterprise/deploy/reference/configuration)
- [Azure Key Vault RBAC](https://learn.microsoft.com/en-us/azure/key-vault/general/rbac-guide)
