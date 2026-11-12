#!/usr/bin/env bash
# ============================================================================
#  Pause the platform:   ./scripts/stop.sh
#
#  Deallocates every VM -> no more compute cost. Disks, IPs and the whole
#  cluster state are KEPT: ./scripts/up.sh starts everything again in ~3 min.
#  Remaining cost while stopped: disks + public IPs ≈ $0.04/hour (~$1/day).
#  To get to ~$0, use ./scripts/destroy.sh instead.
# ============================================================================
set -euo pipefail
# shellcheck source=_lib.sh
source "$(dirname "$0")/_lib.sh"

check_prereqs
rg_exists || die "Resource group $RG does not exist (nothing to stop)."

step "Deallocating all VMs in $RG"
power_all deallocate
step "Stopped. Restart with ./scripts/up.sh"
