# fitapp-infra

Infrastructure as Code for the FitApp DevSecOps project.
**Terraform** creates the Azure resources, **Ansible** configures the machines (hardening + k3s + Argo CD).
Nothing is created or changed by hand: every change goes through this repo.

## Architecture

```
                          Internet
                             │  22, 6443 : admin IPs only       80, 443 : everyone
                             ▼
   ┌───────────── Azure · swedencentral · fitapp-rg ─────────────────────────────┐
   │  VNet 10.0.0.0/16 · subnet 10.0.1.0/24                                      │
   │                                                                             │
   │  k3s-master   10.0.1.10  Standard_B2als_v2 (2 vCPU/4 GB)  public IP + NSG   │
   │       │  control plane · Argo CD · Traefik ingress · SSH bastion            │
   │       │                                                                     │
   │  k3s-worker-1 10.0.1.11  Standard_B2as_v2  (2 vCPU/8 GB)  outbound-only IP  │
   │  k3s-worker-2 10.0.1.12  Standard_B2as_v2  (worker_count = 2, final demo)   │
   │                                                                             │
   │  Key Vault kv-fitapp-xxxxxx (app secrets, read by nodes' managed identity)  │
   └─────────────────────────────────────────────────────────────────────────────┘
   ┌───────────── fitapp-tfstate-rg (PERMANENT, created once by bootstrap/) ─────┐
   │  Storage account: Terraform state (versioned) + backups · Budget alert      │
   └─────────────────────────────────────────────────────────────────────────────┘
```

| Layer | Tool | Lifetime |
|---|---|---|
| State storage, budget alert | `bootstrap/` (Terraform, local state) | permanent, created once |
| Network, VMs, IPs, Key Vault | `terraform/` | **ephemeral**: `up` for demos, `down` after |
| OS hardening, k3s cluster, Argo CD | `ansible/` | re-applied on every `up` |
| Everything inside Kubernetes | Argo CD + `fitapp-gitops` repo | follows git |

## Repository layout

```
bootstrap/            one-time: tfstate storage account, budget alert, writes terraform/backend.hcl
terraform/            network.tf · vms.tf · keyvault.tf · inventory.tf (generates the Ansible inventory)
ansible/
  site.yml            the playbook: wait → common → k3s_server → k3s_agent → kubeconfig → argocd
  group_vars/all.yml  pinned versions (k3s, Argo CD), gitops repo URL
  roles/              common · k3s_server · k3s_agent · kubeconfig · argocd
scripts/up.sh         terraform apply + ansible  (whole platform in ~15 min)
scripts/down.sh       terraform destroy          (cost back to ~0)
```

## Prerequisites (once per laptop)

```bash
az login --use-device-code
export ARM_SUBSCRIPTION_ID=$(az account show --query id -o tsv)   # add to ~/.zshrc
ssh-keygen -t ed25519 -f ~/.ssh/fitapp_azure -C "fitapp-azure"     # SSH key for the VMs
sudo apt install -y kubectl  # or: curl -LO https://dl.k8s.io/release/$(curl -Ls https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl
```

## Step 1 — Bootstrap (ONCE for the whole project)

```bash
cd bootstrap
cp terraform.tfvars.example terraform.tfvars   # set alert_email
terraform init
terraform apply
# wait ~2 minutes (role assignment propagation), then commit terraform/backend.hcl
```

`bootstrap/terraform.tfstate` stays on the laptop of whoever ran it (git-ignored). It only describes
the state storage account and the budget — keep it, but losing it is not dramatic.

## Step 2 — Bring the platform up (each demo)

```bash
cp terraform/terraform.tfvars.example terraform/terraform.tfvars   # first time only
./scripts/up.sh
export KUBECONFIG=~/.kube/fitapp-azure.yaml
kubectl get nodes -o wide
```

Argo CD UI: `kubectl -n argocd port-forward svc/argocd-server 8080:443` → https://localhost:8080
(user `admin`, password: `kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d`).

## Step 3 — Tear it down (after each demo)

```bash
./scripts/down.sh
```

## Common changes (always via a PR on this repo)

| I want to… | Change | Then |
|---|---|---|
| add the 2nd worker (final demo) | `worker_count = 2` in `terraform.tfvars` | `./scripts/up.sh` |
| let a teammate SSH / kubectl | add their IP to `admin_cidrs` | `terraform apply` |
| my home IP changed | nothing (auto-detected) | `terraform apply` |
| upgrade k3s / Argo CD | version in `ansible/group_vars/all.yml` | `ansible-playbook site.yml` |
| connect the gitops repo | `gitops_repo_url` in `ansible/group_vars/all.yml` | `ansible-playbook site.yml` |

## Security choices (DevSecOps)

- Only the master is reachable from the internet, and only on 80/443; SSH and the Kubernetes API are restricted to admin IPs.
- Workers accept nothing from the internet; Ansible reaches them through the master (bastion / ProxyCommand).
- SSH: keys only, no root login, fail2ban, automatic security updates.
- Trusted Launch (Secure Boot + vTPM) on every VM.
- Kubernetes Secrets encrypted at rest (`secrets-encryption`).
- Terraform state: Entra ID auth only (no storage keys), TLS 1.2+, versioned, soft-delete.
- Key Vault with RBAC; nodes get **read-only** access through their managed identity.
- No secret in git: SSH private key stays on the laptop, k3s join token is read at runtime, kubeconfig is git-ignored.
- Cost guardrails: budget alerts, nightly auto-shutdown, ephemeral infrastructure.

## Cost (Sweden Central, pay-as-you-go)

| Item | Price |
|---|---|
| master B2als_v2 | ~$0.039 / h |
| worker B2as_v2 | ~$0.078 / h each |
| 64 GB Standard SSD | ~$0.007 / h each |
| Standard public IP | ~$0.005 / h each |
| **1 demo day (8 h, master + 1 worker)** | **≈ $1.10** |
| Permanent (state storage) | a few cents / month |
