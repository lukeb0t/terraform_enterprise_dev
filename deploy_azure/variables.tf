variable "cluster_name" {
  # Name prefix applied to all TFE resources.
  type = string
}

variable "location" {
  # Azure region for all resources (e.g. "eastus", "westeurope").
  type = string
}

variable "tfe_version" {
  # Terraform Enterprise image tag to deploy.
  type    = string
  default = "2.0.1"
}

variable "tfe_license" {
  # Terraform Enterprise license string.
  type      = string
  sensitive = true
}

variable "admin_email" {
  # Email address for the initial TFE admin user.
  type = string
}

variable "admin_password" {
  # Initial password for the TFE admin user.
  type      = string
  sensitive = true
}

variable "org_name" {
  # Organization name created during bootstrap.
  type    = string
  default = "hashicorp-demo"
}

variable "create_networking" {
  # Set to false when providing vnet_id/subnet_id from an existing network.
  type    = bool
  default = true
}

variable "vnet_id" {
  # Existing VNet ID to reuse; only used in outputs when create_networking = false.
  type    = string
  default = null
}

variable "subnet_id" {
  # Existing subnet ID; required when create_networking = false.
  type    = string
  default = null

  validation {
    condition     = var.create_networking || var.subnet_id != null
    error_message = "subnet_id must be set when create_networking = false."
  }
}

variable "vnet_address_space" {
  # Address space for the new VNet.
  type    = string
  default = "10.101.0.0/16"
}

variable "subnet_address_prefix" {
  # Address prefix for the new subnet.
  type    = string
  default = "10.101.1.0/24"
}

variable "vm_size" {
  # Azure VM size; TFE requires at least 4 vCPU and 8 GB RAM.
  type    = string
  default = "Standard_D2s_v3"
}

variable "os_disk_size_gb" {
  # OS disk size in GiB for the TFE VM.
  type    = number
  default = 200
}

variable "admin_username" {
  # Local admin username on the VM.
  type    = string
  default = "tfeadmin"
}

variable "ssh_public_key" {
  # SSH public key for the admin user. When null, password auth is enabled with a random password.
  type    = string
  default = null
}

variable "allowed_ingress_cidrs" {
  # CIDRs allowed to reach the TFE HTTP/HTTPS endpoints.
  type    = list(string)
  default = ["0.0.0.0/0"]
}

variable "ssh_ingress_cidr_blocks" {
  # CIDRs allowed to SSH to the VM; empty means no SSH NSG rule is created.
  type    = list(string)
  default = []
}

variable "tfe_hostname" {
  # Overrides the hostname TFE uses for TLS and URL construction.
  # Defaults to the allocated static public IP. Set this when providing a
  # certificate issued for a specific domain name.
  type    = string
  default = null
}

variable "tls_cert_pem" {
  # PEM-encoded TLS certificate. When all three tls_* variables are set,
  # self-signed certificate generation is skipped.
  type      = string
  default   = null
  sensitive = true
}

variable "tls_key_pem" {
  # PEM-encoded TLS private key.
  type      = string
  default   = null
  sensitive = true
}

variable "tls_ca_bundle_pem" {
  # PEM-encoded CA bundle. Should include the signing CA so TFE and
  # agent containers trust the certificate.
  type      = string
  default   = null
  sensitive = true
}

variable "tags" {
  # Additional tags applied to all Azure resources.
  type    = map(string)
  default = {}
}

# ── External mode: database ────────────────────────────────────────────────────

variable "database_name" {
  # Name of the PostgreSQL database created for TFE.
  type    = string
  default = "tfe"
}

variable "database_user" {
  # PostgreSQL username used by TFE.
  type    = string
  default = "tfe"
}

variable "database_parameters" {
  # Additional PostgreSQL connection URI parameters.
  # sslmode=disable is appropriate for the local compose sidecar.
  type    = string
  default = "sslmode=disable"
}

# ── External mode: object storage ─────────────────────────────────────────────

variable "storage_container_name" {
  # Override the auto-generated Azure Blob container name.
  # Defaults to "<cluster_name>-tfe-data-<random>".
  type    = string
  default = null
}

# ── TFE Explorer ───────────────────────────────────────────────────────────────

variable "explorer_database_host" {
  # PostgreSQL host for the Explorer database (HOST or HOST:PORT).
  # Defaults to the local postgres sidecar when null.
  type    = string
  default = null
}

variable "explorer_database_name" {
  # Name of the PostgreSQL database used to store Explorer data.
  type    = string
  default = "tfe_explorer"
}

variable "explorer_database_user" {
  # PostgreSQL username for the Explorer database.
  type    = string
  default = null
}

variable "explorer_database_password" {
  # PostgreSQL password for the Explorer database.
  # Not required when using Azure passwordless authentication.
  type      = string
  default   = null
  sensitive = true
}

variable "explorer_database_parameters" {
  # Additional PostgreSQL connection URI parameters.
  # sslmode=disable is appropriate for the local compose sidecar.
  type    = string
  default = "sslmode=disable"
}

variable "explorer_database_passwordless_azure" {
  # Use Azure managed identity auth for the Explorer database.
  type    = bool
  default = false
}
