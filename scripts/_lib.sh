# shellcheck shell=bash
# Shared helpers for up.sh / stop.sh / destroy.sh / status.sh — not meant to be run directly.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RG="${RG:-fitapp-rg}"
SSH_KEY="${SSH_KEY:-$HOME/.ssh/fitapp_azure}"
export KUBECONFIG="${KUBECONFIG_FITAPP:-$HOME/.kube/fitapp-azure.yaml}"
export PATH="$HOME/.local/bin:$PATH"
API="api-version=2024-07-01"

step() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
log()  { printf '    %s\n' "$*"; }
die()  { printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

check_prereqs() {
  for bin in az terraform ansible-playbook ssh; do
    command -v "$bin" >/dev/null || die "'$bin' not found. See README > Prerequisites."
  done
  # kubectl is only needed to look at the cluster afterwards, not to build it.
  command -v kubectl >/dev/null || log "WARNING: kubectl not found (needed later to use the cluster)."
  az account show >/dev/null 2>&1 || die "Not logged in to Azure. Run: az login --use-device-code"
  if [ -z "${ARM_SUBSCRIPTION_ID:-}" ]; then
    ARM_SUBSCRIPTION_ID="$(az account show --query id -o tsv)"
    export ARM_SUBSCRIPTION_ID
  fi
  if [ ! -f "$SSH_KEY" ]; then
    log "No SSH key found, creating $SSH_KEY"
    ssh-keygen -t ed25519 -f "$SSH_KEY" -N "" -C "fitapp-azure" -q
  fi
  log "subscription: $(az account show --query name -o tsv) ($ARM_SUBSCRIPTION_ID)"
}

# Detects this laptop's public IP (several services, retries) and passes it to Terraform
# as the only address allowed to SSH / reach the Kubernetes API. Skipped if admin_cidrs is set in tfvars.
detect_admin_ip() {
  if grep -qE '^\s*admin_cidrs' "$ROOT/terraform/terraform.tfvars" 2>/dev/null; then
    log "admin_cidrs set in terraform.tfvars, not auto-detecting"
    return
  fi
  local ip="" u
  for u in https://checkip.amazonaws.com https://icanhazip.com https://ifconfig.me https://api.ipify.org; do
    ip="$(curl -s -4 --max-time 10 --retry 3 --retry-delay 2 "$u" | tr -d '[:space:]')" || true
    [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && break
    ip=""
  done
  [ -n "$ip" ] || die "Could not detect your public IP (DNS/network problem). Set admin_cidrs in terraform/terraform.tfvars."
  export TF_VAR_admin_cidrs="[\"$ip/32\"]"
  log "your public IP: $ip (only this IP can SSH / use kubectl)"
}

rg_url() { echo "https://management.azure.com/subscriptions/$ARM_SUBSCRIPTION_ID/resourceGroups/$RG"; }

rg_exists() {
  az rest --method get --url "$(rg_url)?api-version=2021-04-01" >/dev/null 2>&1
}

vm_names() {
  az rest --method get --url "$(rg_url)/providers/Microsoft.Compute/virtualMachines?$API" \
    --query "value[].name" -o tsv 2>/dev/null
}

vm_power() { # -> running | deallocated | stopped | starting | deallocating | unknown
  az rest --method get --url "$(rg_url)/providers/Microsoft.Compute/virtualMachines/$1/instanceView?$API" \
    --query "statuses[?starts_with(code,'PowerState/')].code | [0]" -o tsv 2>/dev/null | sed 's#PowerState/##' || echo unknown
}

# power_all start|deallocate  — acts on every VM of the resource group and waits for the end state.
power_all() {
  local action="$1" want vm state
  [ "$action" = start ] && want=running || want=deallocated
  for vm in $(vm_names); do
    state="$(vm_power "$vm")"
    if [ "$state" = "$want" ]; then
      log "$vm already $want"
    else
      log "$vm: $state -> $action"
      az rest --method post --url "$(rg_url)/providers/Microsoft.Compute/virtualMachines/$vm/$action?$API" >/dev/null
    fi
  done
  for vm in $(vm_names); do
    for _ in $(seq 1 60); do
      state="$(vm_power "$vm")"
      [ "$state" = "$want" ] && break
      sleep 10
    done
    log "$vm: $state"
  done
}

terraform_init() { # retries: right after bootstrap the storage RBAC role may need a minute to propagate
  cd "$ROOT/terraform"
  for i in 1 2 3 4 5 6; do
    if terraform init -backend-config=backend.hcl -input=false >/dev/null; then return 0; fi
    log "terraform init failed (attempt $i/6), RBAC may still be propagating, retrying in 30s..."
    sleep 30
  done
  die "terraform init kept failing (see errors above)"
}
