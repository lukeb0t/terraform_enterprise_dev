variable "cluster_name" {
  # Name prefix applied to all TFE resources.
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
  # Set to false when providing vpc_id/subnet_id from another module or data source.
  # This avoids "count depends on unknown value" errors when vpc_id is a module output.
  type    = bool
  default = true
}

variable "vpc_id" {
  # Existing VPC ID to reuse; null creates a new VPC.
  type    = string
  default = null
}

variable "subnet_id" {
  # Existing subnet ID to reuse; required when vpc_id is set.
  type    = string
  default = null

  validation {
    condition     = var.vpc_id == null || var.subnet_id != null
    error_message = "subnet_id must be set when vpc_id is provided."
  }
}

variable "vpc_cidr" {
  # CIDR block for a new VPC created by this module.
  type    = string
  default = "10.101.0.0/16"
}

variable "subnet_cidr" {
  # CIDR block for a new public subnet created by this module.
  type    = string
  default = "10.101.1.0/24"
}

variable "instance_type" {
  # EC2 instance size; TFE needs at least 4 vCPU and 8 GB RAM.
  type    = string
  default = "m5.large"
}

variable "root_volume_size_gb" {
  # Root EBS volume size in GiB for TFE application data.
  type    = number
  default = 200
}

variable "key_pair_name" {
  # Optional EC2 key pair name for SSH access.
  type    = string
  default = null
}

variable "allowed_ingress_cidrs" {
  # CIDR blocks allowed to reach the TFE HTTP/HTTPS endpoints.
  type    = list(string)
  default = ["0.0.0.0/0"]
}

variable "ssh_ingress_cidr_blocks" {
  # CIDR blocks allowed to SSH to the instance; empty means SSM-only access.
  type    = list(string)
  default = []
}

variable "ssm_path_prefix" {
  # Base SSM path where bootstrap stores generated tokens.
  type    = string
  default = "/tfe"
}

variable "tfe_hostname" {
  # Overrides the hostname TFE uses for TLS and URL construction.
  # Defaults to the allocated Elastic IP. Set this when providing your own
  # certificate issued for a specific domain name.
  type    = string
  default = null
}

variable "tls_cert_pem" {
  # PEM-encoded TLS certificate. When all three tls_* variables are set,
  # the self-signed certificate generation is skipped.
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
  # Additional tags applied to created AWS resources.
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

variable "storage_bucket_name" {
  # Override the auto-generated S3 bucket name. Must be globally unique.
  # Defaults to "<cluster_name>-tfe-data-<random>".
  type    = string
  default = null
}

# ── TFE Explorer ───────────────────────────────────────────────────────────────
# Explorer requires external or active-active operational mode.
# Setting explorer_database_host enables the feature.

variable "explorer_database_host" {
  # PostgreSQL host for the Explorer database (HOST or HOST:PORT).
  # Setting this variable enables the Explorer feature.
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
  # Not required when using IAM passwordless authentication.
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

variable "explorer_database_passwordless_aws" {
  # Use EC2 instance profile IAM auth for the Explorer database (RDS IAM).
  type    = bool
  default = false
}

variable "explorer_database_aws_region" {
  # AWS region of the Explorer RDS instance.
  # Defaults to the deployment region when left empty.
  type    = string
  default = ""
}
