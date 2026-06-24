#!/usr/bin/env bash
set -euo pipefail

# Wait for Linux edge VMs, install HammerDB PostgreSQL, verify, and seed the first baseline snapshot.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

wait_for_bootstrap_vms_healthy
wait_for_bootstrap_ssh_endpoints
"$SCRIPT_DIR/install-hammerdb-incluster.sh"

log "Verifying HammerDB PostgreSQL workload is recording..."
if ! "$SCRIPT_DIR/status-hammerdb.sh"; then
  err "HammerDB status check failed immediately after install."
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

log "HammerDB bootstrap complete (PostgreSQL TPC-C populated + audit recording)."
