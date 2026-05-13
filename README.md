# terraform_enterprise_dev

Terraform modules for deploying Terraform Enterprise (TFE) on Docker Compose.

## Modules

| Module | Description |
| --- | --- |
| [`deploy_aws`](./deploy_aws) | Deploys TFE on a single EC2 instance (Ubuntu 22.04) with an Elastic IP and SSM-backed secrets. |
| [`deploy_azure`](./deploy_azure) | Deploys TFE on a single Azure VM (Ubuntu 22.04) with a static public IP and Key Vault-backed secrets. |

Both modules support self-signed certificates (default) and BYO TLS certificates, optional BYO networking, and produce an admin API token at bootstrap.

## Troubleshooting

Infrastructure deploys successfully but TFE never comes online? The most common cause is a bad or expired license. Use the steps below to diagnose from the host.

### 1. Connect to the host

**AWS** — via SSM (no key pair required):
```bash
aws ssm start-session --target <instance_id> --region <region>
```

**Azure** — via SSH or the Azure CLI run-command:
```bash
az vm run-command invoke \
  --resource-group <resource_group_name> \
  --name <vm_name> \
  --command-id RunShellScript \
  --scripts "cat /var/log/tfe-init.log | tail -50"
```

### 2. Check the bootstrap log

All cloud-init activity is written to `/var/log/tfe-init.log`:

```bash
tail -100 /var/log/tfe-init.log
```

A bad license causes the Docker registry login to fail immediately — look for lines like:

```
Error response from daemon: unauthorized: ... license
```

or the container exiting during startup:

```
ERROR: TFE did not become healthy after 30 minutes
```

### 3. Check the container status

```bash
# See if the container is running, restarting, or has exited
docker ps -a --filter name=terraform-enterprise-tfe-1

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
curl -sk -o /dev/null -w "%{http_code}\n" https://localhost/_health_check
```

### 6. Fixing a bad license

1. Obtain a valid license string from your HashiCorp account.
2. Update `tfe_license` in your `terraform.tfvars`.
3. Re-run `terraform apply` — this replaces the instance and re-runs cloud-init with the corrected value.

## References

- [Deploy TFE to Docker](https://developer.hashicorp.com/terraform/enterprise/deploy/docker)
- [TFE configuration reference](https://developer.hashicorp.com/terraform/enterprise/deploy/reference/configuration)
