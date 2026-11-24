#!/usr/bin/env bash
set -euo pipefail

# Single automated flow after DR in the UI (for Playwright or CI — no manual steps):
#   1. Workload cleanup on the non-primary (failed-over-from) cluster, preserving
#      the DR replica volumes
#   2. Wait for edge VMs Running on new primary
#   3. Validate DR data (check-after-dr)
#
# The cleanup runs with --skip-pvcs: it removes the VMs/VMIs so the PVCs are
# released, while keeping the demoted DataVolumes/PVCs that VolumeGroupReplication
# needs and that make a relocate back a promotion instead of a full restore.
# Full wipe (cleanup-gitops-vms-non-primary.sh --yes) is a teardown action, not a
# post-DR one.
#
# Set CLEANUP_STUCK_PVCS=1 to also delete PVCs left stuck on the failed-over-from
# cluster (ODF known issue: "some PVCs remain in the primary cluster after
# failover"). It never touches PVCs mounted by a pod or live VGR members.
#
# Usage (from repo root, hub KUBECONFIG set):
#   ./scripts/dr-validation/post-dr-automation.sh
#   CLEANUP_STUCK_PVCS=1 ./scripts/dr-validation/post-dr-automation.sh
#
# Playwright: shell out to this script after the UI shows the cleanup message.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

AUTO_CONFIRM="${AUTO_CONFIRM:-yes}"
export AUTO_CONFIRM
CLEANUP_STUCK_PVCS="${CLEANUP_STUCK_PVCS:-0}"

ensure_hub_kubeconfig

echo ""
echo "============================================================"
echo " Post-DR automation (cleanup + health wait + data validate)"
echo "============================================================"
echo ""

log "Step 1/3: Cleanup workload on non-primary cluster (DR replica volumes preserved)..."
cleanup_flags=(--yes --skip-pvcs)
if [[ "$CLEANUP_STUCK_PVCS" == "1" ]]; then
  log "  CLEANUP_STUCK_PVCS=1 — also removing PVCs left stuck by the failover."
  cleanup_flags+=(--cleanup-stuck-pvcs)
fi
if ! "$REPO_ROOT/scripts/cleanup-gitops-vms-non-primary.sh" "${cleanup_flags[@]}"; then
  err "Cleanup failed or was blocked by DRPC safety guards."
  exit 1
fi
echo ""

log "Step 2/3: Wait for edge VMs on current primary..."
if ! wait_for_primary_vms_healthy; then
  err "VMs not healthy on primary after cleanup."
  exit 1
fi
echo ""

log "Step 3/3: Validate DR data (${DR_VALIDATION_MODE})..."
if ! "$SCRIPT_DIR/check-after-dr.sh"; then
  err "Data validation FAILED (continuity/RPO or collect errors)."
  exit 1
fi

log "Post-DR automation completed successfully."
exit 0
