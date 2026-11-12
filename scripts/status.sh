#!/usr/bin/env bash
# Shows VM power states and, if the cluster is up, nodes + Argo CD.
set -uo pipefail
# shellcheck source=_lib.sh
source "$(dirname "$0")/_lib.sh"

[ -n "${ARM_SUBSCRIPTION_ID:-}" ] || ARM_SUBSCRIPTION_ID="$(az account show --query id -o tsv)"
export ARM_SUBSCRIPTION_ID

if ! rg_exists; then
  echo "Platform: DESTROYED (resource group $RG does not exist). Run ./scripts/up.sh"
  exit 0
fi

echo "VMs in $RG:"
running=0
for vm in $(vm_names); do
  state="$(vm_power "$vm")"
  [ "$state" = running ] && running=1
  printf '  %-15s %s\n' "$vm" "$state"
done

if [ "$running" = 1 ] && [ -f "$KUBECONFIG" ]; then
  echo
  kubectl get nodes -o wide 2>/dev/null || echo "  (Kubernetes API not reachable yet)"
  echo
  kubectl -n argocd get pods 2>/dev/null
  echo
  echo "kubectl:   export KUBECONFIG=$KUBECONFIG"
  echo "Argo CD:   kubectl -n argocd port-forward svc/argocd-server 8080:443   -> https://localhost:8080"
  echo "password:  kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo"
fi
