variable "cluster_name" {
  # Name prefix applied to all TFE resources.
  type = string
}

variable "tfe_version" {
  # Terraform Enterprise image tag to deploy.
  type    = string
  default = "v202505-1"
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
  default = "m5.xlarge"
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

variable "tags" {
  # Additional tags applied to created AWS resources.
  type    = map(string)
  default = {}
}
