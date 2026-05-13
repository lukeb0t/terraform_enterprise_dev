data "aws_region" "current" {}

data "aws_caller_identity" "current" {}

data "aws_availability_zones" "available" {
  state = "available"
}

data "aws_ami" "ubuntu_2204" {
  most_recent = true
  owners      = ["099720109477"]

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

locals {
  # Normalize SSM prefix for consistent outputs and IAM policies across modules.
  ssm_prefix = "/${trimsuffix(trimprefix(var.ssm_path_prefix, "/"), "/")}/${var.cluster_name}"

  # Use explicit bool instead of checking vpc_id == null to avoid count evaluation at plan time
  # when vpc_id comes from a module output (known only after apply).
  create_networking = var.create_networking
  vpc_id_resolved   = local.create_networking ? aws_vpc.tfe[0].id : var.vpc_id
  subnet_id_resolved = local.create_networking ? aws_subnet.tfe_public[0].id : var.subnet_id

  tfe_hostname = var.tfe_hostname != null ? var.tfe_hostname : aws_eip.tfe.public_ip

  storage_bucket = var.storage_bucket_name != null ? var.storage_bucket_name : "${var.cluster_name}-tfe-data-${random_id.bucket_suffix.hex}"

  # Explorer defaults to the postgres sidecar when no external host is supplied.
  explorer_db_host     = var.explorer_database_host != null ? var.explorer_database_host : "postgres:5432"
  explorer_db_user     = var.explorer_database_user != null ? var.explorer_database_user : var.database_user
  explorer_db_password = var.explorer_database_password != null ? var.explorer_database_password : random_password.database.result

  # Apply a consistent tag set to all resources.
  common_tags = merge({
    Module      = "tfe_deploy"
    ClusterName = var.cluster_name
  }, var.tags)
}

# Random token reused for TFE IACT bootstrap and disk encryption password.
resource "random_password" "iact_token" {
  length  = 32
  special = false # alphanumeric only for simple password entry during initial setup
}

# Auto-generated password for the PostgreSQL sidecar container.
resource "random_password" "database" {
  length  = 32
  special = false
}

# Random suffix to make the S3 bucket name globally unique.
resource "random_id" "bucket_suffix" {
  byte_length = 4
}

# Create a dedicated VPC when the caller does not provide one.
resource "aws_vpc" "tfe" {
  count = local.create_networking ? 1 : 0

  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = merge(local.common_tags, {
    Name = "${var.cluster_name}-vpc"
  })
}

# Attach an internet gateway for the public subnet.
resource "aws_internet_gateway" "tfe" {
  count = local.create_networking ? 1 : 0

  vpc_id = aws_vpc.tfe[0].id

  tags = merge(local.common_tags, {
    Name = "${var.cluster_name}-igw"
  })
}

# Public subnet for the TFE instance.
resource "aws_subnet" "tfe_public" {
  count = local.create_networking ? 1 : 0

  vpc_id                  = aws_vpc.tfe[0].id
  cidr_block              = var.subnet_cidr
  availability_zone       = data.aws_availability_zones.available.names[0]
  map_public_ip_on_launch = false

  tags = merge(local.common_tags, {
    Name = "${var.cluster_name}-public-subnet"
  })
}

# Route table with a default route to the internet gateway.
resource "aws_route_table" "tfe_public" {
  count = local.create_networking ? 1 : 0

  vpc_id = aws_vpc.tfe[0].id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.tfe[0].id
  }

  tags = merge(local.common_tags, {
    Name = "${var.cluster_name}-public-rt"
  })
}

# Associate the public route table with the subnet.
resource "aws_route_table_association" "tfe_public" {
  count = local.create_networking ? 1 : 0

  subnet_id      = aws_subnet.tfe_public[0].id
  route_table_id = aws_route_table.tfe_public[0].id
}

# Security group exposing TFE over HTTP/HTTPS and optional SSH.
resource "aws_security_group" "tfe" {
  name        = "${var.cluster_name}-tfe-sg"
  description = "Security group for Terraform Enterprise"
  vpc_id      = local.vpc_id_resolved

  ingress {
    description = "HTTPS"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = var.allowed_ingress_cidrs
  }

  ingress {
    description = "HTTP redirect"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = var.allowed_ingress_cidrs
  }

  dynamic "ingress" {
    for_each = var.ssh_ingress_cidr_blocks

    content {
      description = "SSH"
      from_port   = 22
      to_port     = 22
      protocol    = "tcp"
      cidr_blocks = [ingress.value] # allow iteration over CIDR list (empty = no SSH access)
    }
  }

  egress {
    description = "Allow all outbound traffic"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.common_tags, {
    Name = "${var.cluster_name}-tfe-sg"
  })
}

# EC2 role assumed by the TFE instance.
resource "aws_iam_role" "tfe" {
  name = "${var.cluster_name}-tfe-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })

  tags = local.common_tags
}

# Permit cloud-init to store and retrieve TFE bootstrap tokens in SSM.
resource "aws_iam_role_policy" "tfe_ssm" {
  name = "${var.cluster_name}-tfe-ssm"
  role = aws_iam_role.tfe.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ssm:PutParameter", # write admin and org tokens
          "ssm:GetParameter",
          "ssm:GetParameters"
        ]
        Resource = "arn:aws:ssm:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:parameter${local.ssm_prefix}/*"
      }
    ]
  })
}

# Store BYO TLS material in SSM so it is not embedded in user data.
resource "aws_ssm_parameter" "tls_cert" {
  count = var.tls_cert_pem != null ? 1 : 0
  name  = "${local.ssm_prefix}/tls-cert"
  type  = "SecureString"
  value = var.tls_cert_pem
  tags  = local.common_tags
}

resource "aws_ssm_parameter" "tls_key" {
  count = var.tls_key_pem != null ? 1 : 0
  name  = "${local.ssm_prefix}/tls-key"
  type  = "SecureString"
  value = var.tls_key_pem
  tags  = local.common_tags
}

resource "aws_ssm_parameter" "tls_bundle" {
  count = var.tls_ca_bundle_pem != null ? 1 : 0
  name  = "${local.ssm_prefix}/tls-bundle"
  type  = "SecureString"
  value = var.tls_ca_bundle_pem
  tags  = local.common_tags
}

# Enable Session Manager access without opening SSH.
resource "aws_iam_role_policy_attachment" "tfe_ssm_session_manager" {
  role       = aws_iam_role.tfe.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# Attach the IAM role to the EC2 instance.
resource "aws_iam_instance_profile" "tfe" {
  name = "${var.cluster_name}-tfe-profile"
  role = aws_iam_role.tfe.name

  tags = local.common_tags
}

# Reserve a stable public IP for the TFE instance.
resource "aws_eip" "tfe" {
  domain = "vpc"

  tags = merge(local.common_tags, {
    Name = "${var.cluster_name}-tfe-eip"
  })
}

# Launch Terraform Enterprise on Ubuntu 22.04 with Docker Compose.
resource "aws_instance" "tfe" {
  ami                    = data.aws_ami.ubuntu_2204.id
  instance_type          = var.instance_type
  subnet_id              = local.subnet_id_resolved
  vpc_security_group_ids = [aws_security_group.tfe.id]
  iam_instance_profile   = aws_iam_instance_profile.tfe.name
  key_name               = var.key_pair_name

  root_block_device {
    volume_type = "gp3"
    volume_size = var.root_volume_size_gb
    encrypted   = true # encrypt TFE state and application data at rest
  }

  # base64encode prevents Terraform from interpreting template variables as HCL.
  user_data_base64 = base64encode(templatefile("${path.module}/templates/cloud-init.sh.tpl", {
    tfe_hostname        = local.tfe_hostname
    tfe_license         = var.tfe_license
    tfe_version         = var.tfe_version
    iact_token          = random_password.iact_token.result
    admin_email         = var.admin_email
    admin_password      = var.admin_password
    org_name            = var.org_name
    ssm_prefix          = local.ssm_prefix
    region              = data.aws_region.current.name
    tls_cert_ssm_path   = var.tls_cert_pem != null ? "${local.ssm_prefix}/tls-cert" : ""
    tls_key_ssm_path    = var.tls_key_pem != null ? "${local.ssm_prefix}/tls-key" : ""
    tls_bundle_ssm_path = var.tls_ca_bundle_pem != null ? "${local.ssm_prefix}/tls-bundle" : ""
    # External mode
    database_name       = var.database_name
    database_user       = var.database_user
    database_password   = random_password.database.result
    database_parameters = var.database_parameters
    storage_bucket      = local.storage_bucket
    # Explorer — always enabled; defaults to the postgres sidecar
    explorer_database_host                 = local.explorer_db_host
    explorer_database_name                 = var.explorer_database_name
    explorer_database_user                 = local.explorer_db_user
    explorer_database_password             = local.explorer_db_password
    explorer_database_parameters           = var.explorer_database_parameters
    explorer_database_passwordless_aws     = var.explorer_database_passwordless_aws
    explorer_database_aws_region           = var.explorer_database_aws_region != "" ? var.explorer_database_aws_region : data.aws_region.current.name
  }))

  tags = merge(local.common_tags, {
    Name = "${var.cluster_name}-tfe"
  })
}

# Bind the reserved public IP to the instance after launch.
resource "aws_eip_association" "tfe" {
  allocation_id = aws_eip.tfe.id
  instance_id   = aws_instance.tfe.id
}

# ── S3 object storage for TFE external mode ────────────────────────────────────

resource "aws_s3_bucket" "tfe" {
  bucket        = local.storage_bucket
  force_destroy = true

  tags = merge(local.common_tags, {
    Name = "${var.cluster_name}-tfe-data"
  })
}

resource "aws_s3_bucket_versioning" "tfe" {
  bucket = aws_s3_bucket.tfe.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "tfe" {
  bucket = aws_s3_bucket.tfe.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "tfe" {
  bucket                  = aws_s3_bucket.tfe.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_iam_role_policy" "tfe_s3" {
  name = "${var.cluster_name}-tfe-s3"
  role = aws_iam_role.tfe.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:DeleteObject",
          "s3:GetObjectTagging",
          "s3:PutObjectTagging",
        ]
        Resource = "${aws_s3_bucket.tfe.arn}/*"
      },
      {
        Effect   = "Allow"
        Action   = ["s3:ListBucket"]
        Resource = aws_s3_bucket.tfe.arn
      }
    ]
  })
}
