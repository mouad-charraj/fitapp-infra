#!/usr/bin/env bash
# ============================================================================
#  Delete the platform:   ./scripts/destroy.sh
#
#  Destroys EVERYTHING created by terraform/ (VMs, disks, IPs, network, Key Vault).
#  KEPT: the permanent bootstrap (Terraform state storage) and this git repo,
#  so ./scripts/up.sh rebuilds the exact same platform in ~15 min.
#  AUTO_APPROVE=1 ./scripts/destroy.sh   -> no "yes" prompt
# ============================================================================
set -euo pipefail
# shellcheck source=_lib.sh
source "$(dirname "$0")/_lib.sh"
APPROVE=()
[ -n "${AUTO_APPROVE:-}" ] && APPROVE=(-auto-approve)

check_prereqs
[ -f "$ROOT/terraform/backend.hcl" ] || die "No backend.hcl: nothing was ever created."

step "Terraform destroy"
detect_admin_ip
terraform_init
terraform destroy "${APPROVE[@]}"

rm -f "$ROOT/ansible/.known_hosts" "$KUBECONFIG"
step "Destroyed. Cloud cost is back to ~0."
