#!/usr/bin/env bash
# ============================================================================
#  ONE command to get the whole platform running:   ./scripts/up.sh
#
#  - first run only : creates the permanent bootstrap (Terraform state storage)
#  - Terraform      : creates/updates network, VMs, IPs, Key Vault
#  - Azure          : starts the VMs if they were stopped with stop.sh
#  - Ansible        : hardening + k3s cluster + Argo CD + kubeconfig on this laptop
#
#  Safe to run again at any time (everything is idempotent).
#  AUTO_APPROVE=1 ./scripts/up.sh   -> no "yes" prompts from Terraform
# ============================================================================
set -euo pipefail
# shellcheck source=_lib.sh
source "$(dirname "$0")/_lib.sh"
APPROVE=()
[ -n "${AUTO_APPROVE:-}" ] && APPROVE=(-auto-approve)

step "0/4 Prerequisites"
check_prereqs

if [ ! -f "$ROOT/terraform/backend.hcl" ]; then
  step "First run: bootstrap (permanent Terraform state storage)"
  cd "$ROOT/bootstrap"
  terraform init -input=false
  terraform apply "${APPROVE[@]}"
fi

step "1/4 Terraform: Azure infrastructure"
detect_admin_ip
terraform_init
terraform apply "${APPROVE[@]}"

step "2/4 Azure: make sure every VM is running"
power_all start

step "3/4 Ansible: hardening + k3s + Argo CD"
rm -f "$ROOT/ansible/.known_hosts" # rebuilt VMs have new SSH host keys
cd "$ROOT/ansible"
ansible-playbook site.yml

step "4/4 Status"
"$ROOT/scripts/status.sh"
