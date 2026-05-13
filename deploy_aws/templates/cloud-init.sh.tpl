#!/bin/bash
# =============================================================================
# Terraform Enterprise bootstrap for Ubuntu 22.04.
# Template vars: tfe_hostname, tfe_license, tfe_version, iact_token,
# admin_email, admin_password, org_name, ssm_prefix, region,
# tls_cert_ssm_path, tls_key_ssm_path, tls_bundle_ssm_path (optional; omit to generate self-signed).
# Explorer (official vars per https://developer.hashicorp.com/terraform/enterprise/deploy/configuration/enable-explorer):
#   TFE_EXPLORER_DATABASE_HOST       — enables Explorer; defaults to the postgres sidecar
#   TFE_EXPLORER_DATABASE_NAME       — defaults to "tfe_explorer"
#   TFE_EXPLORER_DATABASE_USER/PASSWORD — default to the main DB credentials
#   TFE_EXPLORER_DATABASE_PARAMETERS — optional connection URI params
#   TFE_EXPLORER_DATABASE_PASSWORDLESS_AWS_* — optional IAM auth for external RDS
# =============================================================================
set -euo pipefail

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a /var/log/tfe-init.log; }

REGION="${region}"
SSM_PREFIX="${ssm_prefix}"
TFE_HOSTNAME="${tfe_hostname}"
TFE_VERSION="${tfe_version}"
IACT_TOKEN="${iact_token}"
ORG_NAME="${org_name}"
ADMIN_EMAIL="${admin_email}"

log "=== TFE bootstrap starting ==="
log "Waiting for dpkg lock..."
while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1; do sleep 2; done

log "Installing packages..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -q
# Install prereqs for adding Docker's official apt repo
apt-get install -y ca-certificates curl gnupg lsb-release jq awscli openssl psmisc

# Add Docker's official GPG key and repo (docker-compose-plugin lives here, not in Ubuntu's repo)
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
chmod a+r /etc/apt/keyrings/docker.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
  https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" \
  > /etc/apt/sources.list.d/docker.list
apt-get update -q
apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
systemctl enable --now docker

log "Authenticating with HashiCorp container registry..."
echo "${tfe_license}" | docker login images.releases.hashicorp.com \
  --username terraform --password-stdin

%{ if tls_cert_ssm_path != "" ~}
log "Fetching provided TLS certificate from SSM..."
mkdir -p /etc/tfe-tls
aws ssm get-parameter --name "${tls_cert_ssm_path}" --with-decryption \
  --region "$REGION" --query Parameter.Value --output text > /etc/tfe-tls/cert.pem
aws ssm get-parameter --name "${tls_key_ssm_path}" --with-decryption \
  --region "$REGION" --query Parameter.Value --output text > /etc/tfe-tls/key.pem
aws ssm get-parameter --name "${tls_bundle_ssm_path}" --with-decryption \
  --region "$REGION" --query Parameter.Value --output text > /etc/tfe-tls/bundle.pem
chmod 644 /etc/tfe-tls/*.pem
log "TLS certificate written to /etc/tfe-tls/"
%{ else ~}
log "Generating self-signed TLS certificate for $TFE_HOSTNAME..."
mkdir -p /etc/tfe-tls

cat > /tmp/tfe-openssl.cnf << 'OPENSSLCFG'
[req]
default_bits       = 4096
prompt             = no
default_md         = sha256
distinguished_name = dn
x509_extensions    = v3_req

[dn]
CN = TFE

[v3_req]
subjectAltName = @alt_names

[alt_names]
OPENSSLCFG

echo "IP.1 = $TFE_HOSTNAME" >> /tmp/tfe-openssl.cnf

openssl req -x509 -newkey rsa:4096 -nodes \
  -keyout /etc/tfe-tls/key.pem \
  -out    /etc/tfe-tls/cert.pem \
  -days   365 \
  -config /tmp/tfe-openssl.cnf

cp /etc/tfe-tls/cert.pem /etc/tfe-tls/bundle.pem
chmod 644 /etc/tfe-tls/*.pem
log "TLS certificate written to /etc/tfe-tls/"
%{ endif ~}

log "Writing PostgreSQL init script..."
mkdir -p /etc/tfe/pg-init
cat > /etc/tfe/pg-init/01-init.sh << 'PGINIT'
#!/bin/bash
set -e

# Create schemas and extensions in the main TFE database required per
# https://developer.hashicorp.com/terraform/enterprise/deploy/configuration/storage/connect-database/postgres
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" \
  -c 'CREATE SCHEMA IF NOT EXISTS rails' \
  -c 'CREATE SCHEMA IF NOT EXISTS registry' \
  -c 'CREATE EXTENSION IF NOT EXISTS hstore WITH SCHEMA rails' \
  -c 'CREATE EXTENSION IF NOT EXISTS "uuid-ossp" WITH SCHEMA rails' \
  -c 'CREATE EXTENSION IF NOT EXISTS citext WITH SCHEMA registry'

# Create the separate Explorer database. TFE automatically creates the
# 'explorer' schema within it on first start — no extensions needed.
# https://developer.hashicorp.com/terraform/enterprise/deploy/configuration/enable-explorer
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" \
  -c "CREATE DATABASE ${explorer_database_name}"
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" \
  -c "GRANT ALL PRIVILEGES ON DATABASE ${explorer_database_name} TO \"$POSTGRES_USER\""
PGINIT
chmod +x /etc/tfe/pg-init/01-init.sh

log "Pulling TFE image $TFE_VERSION..."
docker pull "images.releases.hashicorp.com/hashicorp/terraform-enterprise:$TFE_VERSION"

mkdir -p /etc/tfe
log "Writing Docker Compose configuration..."
cat > /etc/tfe/compose.yaml << 'COMPOSEYML'
name: terraform-enterprise
services:
  postgres:
    image: postgres:16
    restart: unless-stopped
    environment:
      POSTGRES_DB: "${database_name}"
      POSTGRES_USER: "${database_user}"
      POSTGRES_PASSWORD: "${database_password}"
    volumes:
      - type: bind
        source: /etc/tfe/pg-init
        target: /docker-entrypoint-initdb.d
      - type: volume
        source: postgres-data
        target: /var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U ${database_user} -d ${database_name}"]
      interval: 5s
      timeout: 5s
      retries: 12

  tfe:
    image: images.releases.hashicorp.com/hashicorp/terraform-enterprise:${tfe_version}
    depends_on:
      postgres:
        condition: service_healthy
    environment:
      TFE_LICENSE: "${tfe_license}"
      TFE_HOSTNAME: "${tfe_hostname}"
      TFE_OPERATIONAL_MODE: "external"
      TFE_ENCRYPTION_PASSWORD: "${iact_token}"
      TFE_DATABASE_HOST: "postgres:5432"
      TFE_DATABASE_NAME: "${database_name}"
      TFE_DATABASE_USER: "${database_user}"
      TFE_DATABASE_PASSWORD: "${database_password}"
      TFE_DATABASE_PARAMETERS: "${database_parameters}"
      TFE_OBJECT_STORAGE_TYPE: "s3"
      TFE_OBJECT_STORAGE_S3_BUCKET: "${storage_bucket}"
      TFE_OBJECT_STORAGE_S3_REGION: "${region}"
      TFE_OBJECT_STORAGE_S3_USE_INSTANCE_PROFILE: "true"
      TFE_TLS_CERT_FILE: "/etc/ssl/private/terraform-enterprise/cert.pem"
      TFE_TLS_KEY_FILE: "/etc/ssl/private/terraform-enterprise/key.pem"
      TFE_TLS_CA_BUNDLE_FILE: "/etc/ssl/private/terraform-enterprise/bundle.pem"
      TFE_IACT_SUBNETS: "0.0.0.0/0" # allow IACT from any subnet during initial setup
      TFE_IACT_TOKEN: "${iact_token}"
      TFE_EXPLORER_DATABASE_HOST: "${explorer_database_host}"
      TFE_EXPLORER_DATABASE_NAME: "${explorer_database_name}"
      TFE_EXPLORER_DATABASE_USER: "${explorer_database_user}"
      TFE_EXPLORER_DATABASE_PASSWORD: "${explorer_database_password}"
      TFE_EXPLORER_DATABASE_PARAMETERS: "${explorer_database_parameters}"
%{ if explorer_database_passwordless_aws ~}
      TFE_EXPLORER_DATABASE_PASSWORDLESS_AWS_USE_INSTANCE_PROFILE: "true"
      TFE_EXPLORER_DATABASE_PASSWORDLESS_AWS_REGION: "${explorer_database_aws_region}"
%{ endif ~}
    cap_add:
      - IPC_LOCK
    read_only: true
    tmpfs:
      - /tmp:mode=01777
      - /run
      - /var/log/terraform-enterprise
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - type: bind
        source: /var/run/docker.sock
        target: /run/docker.sock
      - type: bind
        source: /etc/tfe-tls
        target: /etc/ssl/private/terraform-enterprise
      - type: volume
        source: terraform-enterprise-cache
        target: /var/cache/tfe-task-worker/terraform

volumes:
  postgres-data:
  terraform-enterprise-cache:
    name: terraform-enterprise_terraform-enterprise-cache
COMPOSEYML
log "Compose file written to /etc/tfe/compose.yaml"

log "Starting TFE with Docker Compose..."
docker compose -f /etc/tfe/compose.yaml up -d

log "Waiting for TFE container and task-worker to be ready..."
for i in $(seq 1 90); do
  if docker ps --format '{{.Names}}' | grep -qx 'terraform-enterprise-tfe-1'; then
    tw_status="$(docker exec terraform-enterprise-tfe-1 supervisorctl status tfe:task-worker 2>/dev/null || true)"
    if echo "$tw_status" | grep -q "RUNNING"; then
      log "task-worker is RUNNING"
      break
    fi
  fi
  sleep 2
done

log "Waiting for TFE to become healthy (this may take up to 10 minutes)..."
for i in $(seq 1 20); do
  HTTP_CODE=$(curl -sk -o /dev/null -w "%%{http_code}" "https://$TFE_HOSTNAME/_health_check" 2>/dev/null || echo "000")
  if [ "$HTTP_CODE" = "200" ]; then
    log "TFE is healthy (attempt $i/20)"
    break
  fi
  if [ "$i" -eq 20 ]; then
    log "ERROR: TFE did not become healthy after 10 minutes"
    docker compose -f /etc/tfe/compose.yaml logs --tail=50 >&2
    exit 1
  fi
  log "Attempt $i/20 — HTTP $HTTP_CODE — waiting 30s..."
  sleep 30
done

log "Creating initial admin user..."
ADMIN_PAYLOAD='{"username":"admin","email":"${admin_email}","password":"${admin_password}"}'
ADMIN_RESP=$(curl -sk \
  --header "Content-Type: application/json" \
  --request POST \
  --data "$ADMIN_PAYLOAD" \
  "https://$TFE_HOSTNAME/admin/initial-admin-user?token=$IACT_TOKEN")

ADMIN_TOKEN=$(echo "$ADMIN_RESP" | jq -r '.token // empty')
if [ -z "$ADMIN_TOKEN" ]; then
  log "Initial admin creation did not return a token; trying existing admin token from SSM..."
  ADMIN_TOKEN=$(aws ssm get-parameter \
    --region "$REGION" \
    --name "$SSM_PREFIX/admin-token" \
    --with-decryption \
    --query Parameter.Value \
    --output text 2>/dev/null || true)
  if [ -z "$ADMIN_TOKEN" ]; then
    log "ERROR: Failed to create admin user and no existing admin token found. Response: $ADMIN_RESP"
    exit 1
  fi
  ADMIN_STATUS=$(curl -sk -o /dev/null -w "%%{http_code}" \
    --header "Authorization: Bearer $ADMIN_TOKEN" \
    "https://$TFE_HOSTNAME/api/v2/account/details" || true)
  if [ "$ADMIN_STATUS" != "200" ]; then
    log "ERROR: Existing admin token is invalid (HTTP $ADMIN_STATUS). Response: $ADMIN_RESP"
    exit 1
  fi
  log "Using existing valid admin token from SSM"
else
  log "Admin user created successfully"
fi

log "Storing admin token in SSM: $SSM_PREFIX/admin-token"
aws ssm put-parameter \
  --region "$REGION" \
  --name "$SSM_PREFIX/admin-token" \
  --description "TFE admin API token — ${org_name}" \
  --value "$ADMIN_TOKEN" \
  --type "SecureString" \
  --overwrite

log "Creating TFE organization: $ORG_NAME..."
ORG_PAYLOAD='{"data":{"type":"organizations","attributes":{"name":"'$ORG_NAME'","email":"${admin_email}","cost-estimation-enabled":false}}}'
ORG_RESP=$(curl -sk \
  --header "Authorization: Bearer $ADMIN_TOKEN" \
  --header "Content-Type: application/vnd.api+json" \
  --request POST \
  --data "$ORG_PAYLOAD" \
  "https://$TFE_HOSTNAME/api/v2/organizations")

ORG_NAME_RESP=$(echo "$ORG_RESP" | jq -r '.data.attributes.name // empty')
if [ -n "$ORG_NAME_RESP" ]; then
  log "Organization '$ORG_NAME_RESP' created"
elif echo "$ORG_RESP" | jq -e '.errors[]? | select(.status=="422")' >/dev/null 2>&1; then
  log "Organization '$ORG_NAME' already exists; continuing"
else
  log "ERROR: Failed to create organization. Response: $ORG_RESP"
  exit 1
fi

log "Creating organization API token..."
TOKEN_RESP=$(curl -sk \
  --header "Authorization: Bearer $ADMIN_TOKEN" \
  --header "Content-Type: application/vnd.api+json" \
  --request POST \
  "https://$TFE_HOSTNAME/api/v2/organizations/$ORG_NAME/authentication-token")

ORG_TOKEN=$(echo "$TOKEN_RESP" | jq -r '.data.attributes.token // empty')
if [ -z "$ORG_TOKEN" ]; then
  log "ERROR: Failed to create org token. Response: $TOKEN_RESP"
  exit 1
fi
log "Organization API token created"

log "Storing org token in SSM: $SSM_PREFIX/org-token"
aws ssm put-parameter \
  --region "$REGION" \
  --name "$SSM_PREFIX/org-token" \
  --description "TFE organization API token — $ORG_NAME" \
  --value "$ORG_TOKEN" \
  --type "SecureString" \
  --overwrite

unset ADMIN_TOKEN ORG_TOKEN ADMIN_PAYLOAD ADMIN_RESP ORG_PAYLOAD ORG_RESP TOKEN_RESP

log "=== TFE initialization complete ==="
log "    URL           : https://$TFE_HOSTNAME"
log "    Organization  : $ORG_NAME"
log "    Admin token   : aws ssm get-parameter --name '$SSM_PREFIX/admin-token' --with-decryption --region $REGION --query Parameter.Value --output text"
log "    Org token     : aws ssm get-parameter --name '$SSM_PREFIX/org-token' --with-decryption --region $REGION --query Parameter.Value --output text"
