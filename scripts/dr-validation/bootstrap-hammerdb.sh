#!/usr/bin/env bash
set -euo pipefail

# Wait for all HammerDB edge VMs, install schema on each, verify TPC-C is present.
# Does not start OLTP writers or save a DR baseline (sanity does that before Initiate).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

wait_for_bootstrap_vms_healthy
wait_for_bootstrap_ssh_endpoints
"$SCRIPT_DIR/install-hammerdb-incluster.sh"

log "Verifying HammerDB TPC-C schema is present on all target edge VMs..."
status_attempts="${DR_VALIDATION_STATUS_ATTEMPTS:-6}"
status_sleep="${DR_VALIDATION_STATUS_RETRY_SLEEP_SEC:-30}"
status_ok=0
for attempt in $(seq 1 "$status_attempts"); do
  if "$SCRIPT_DIR/status-hammerdb.sh" --schema-only; then
    status_ok=1
    break
  fi
  if [[ "$attempt" -lt "$status_attempts" ]]; then
    warn "HammerDB schema status check not ready (attempt ${attempt}/${status_attempts}); retrying in ${status_sleep}s..."
    sleep "$status_sleep"
  fi
done
if [[ "$status_ok" -ne 1 ]]; then
  err "HammerDB schema status check failed after ${status_attempts} attempt(s)."
  exit 1
fi

log "HammerDB bootstrap complete (TPC-C schema on $(hammerdb_target_vm_count) edge VM(s); writers stopped)."
