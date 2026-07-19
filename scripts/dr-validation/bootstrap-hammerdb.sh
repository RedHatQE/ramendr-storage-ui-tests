#!/usr/bin/env bash
set -euo pipefail

# Wait for all HammerDB edge VMs, install workload on each, verify, and seed baseline snapshot.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

wait_for_bootstrap_vms_healthy
wait_for_bootstrap_ssh_endpoints
"$SCRIPT_DIR/install-hammerdb-incluster.sh"

log "Verifying HammerDB workload is recording on all target edge VMs..."
status_attempts="${DR_VALIDATION_STATUS_ATTEMPTS:-6}"
status_sleep="${DR_VALIDATION_STATUS_RETRY_SLEEP_SEC:-30}"
status_ok=0
for attempt in $(seq 1 "$status_attempts"); do
  if "$SCRIPT_DIR/status-hammerdb.sh"; then
    status_ok=1
    break
  fi
  if [[ "$attempt" -lt "$status_attempts" ]]; then
    warn "HammerDB status check not ready (attempt ${attempt}/${status_attempts}); retrying in ${status_sleep}s..."
    sleep "$status_sleep"
  fi
done
if [[ "$status_ok" -ne 1 ]]; then
  err "HammerDB status check failed after ${status_attempts} attempt(s)."
  exit 1
fi

initial_stamp="$(date +%Y%m%d-%H%M%S)"
initial_dir="${DR_VALIDATION_DB_SNAPSHOT_ROOT}/${initial_stamp}"
log "Saving initial DB baseline snapshot -> ${initial_dir}"
if ! "$SCRIPT_DIR/collect-db-snapshot-incluster.sh" "$initial_dir"; then
  err "Could not collect initial HammerDB DB baseline snapshot."
  exit 1
fi
if [[ ! -L "${DR_VALIDATION_DB_SNAPSHOT_ROOT}/latest" ]]; then
  update_latest_db_snapshot_link "$initial_dir"
fi

log "HammerDB bootstrap complete (TPC-C + audit on $(hammerdb_target_vm_count) edge VM(s))."
