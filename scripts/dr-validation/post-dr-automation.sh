#!/usr/bin/env bash
set -euo pipefail

# Single automated flow after DR in the UI (for Playwright or CI — no manual steps):
#   1. Safe cleanup on non-primary cluster
#   2. Wait for edge VMs Running on new primary
#   3. Validate timestamp logs (check-after-dr)
#
# Usage (from repo root, hub KUBECONFIG set):
#   ./scripts/dr-validation/post-dr-automation.sh
#
# Playwright: shell out to this script after the UI shows the cleanup message.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

AUTO_CONFIRM="${AUTO_CONFIRM:-yes}"
export AUTO_CONFIRM

ensure_hub_kubeconfig

echo ""
echo "============================================================"
echo " Post-DR automation (cleanup + health wait + data validate)"
echo "============================================================"
echo ""

log "Step 1/3: Cleanup orphaned VMs on non-primary cluster..."
if ! "$REPO_ROOT/scripts/cleanup-gitops-vms-non-primary.sh" --yes; then
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
