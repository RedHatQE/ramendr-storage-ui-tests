#!/usr/bin/env bash
set -euo pipefail

# Wait for edge VMs + routes, install DR validation workload, verify recording.
# Invoked automatically from scripts/redeploy.sh unless SKIP_DR_VALIDATION=1.
# HammerDB bootstrap waits for Linux VMs only (see bootstrap-hammerdb.sh).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

if dr_validation_uses_hammerdb; then
  log "DR validation mode: hammerdb (all edge VMs when DR_VALIDATION_HAMMERDB_ALL_VMS=1)"
  "$SCRIPT_DIR/bootstrap-hammerdb.sh"
  exit $?
fi

# After redeploy: wait for gitops edge VMs on the DR primary, then install writers.
wait_for_primary_vms_healthy

if [[ "${DR_VALIDATION_INCLUSTER_INSTALL:-1}" == "1" ]]; then
  # Spokes use NodePort on private workers; install from a pod on the primary spoke.
  wait_for_edge_vms
  "$SCRIPT_DIR/install-writer-incluster.sh"
  sleep 5
  if ! verify_writers_recording; then
    err "Timestamp writer verification failed after in-cluster install."
    exit 1
  fi
else
  wait_for_edge_vms
  "$SCRIPT_DIR/install-writer.sh"
  sleep 5
  if ! verify_writers_recording; then
    err "Timestamp writer verification failed after SSH install."
    exit 1
  fi
fi

initial_stamp="$(date +%Y%m%d-%H%M%S)"
initial_dir="${AUTO_SNAPSHOT_ROOT}/${initial_stamp}"
log "Saving initial timestamp baseline snapshot -> ${initial_dir}"
if [[ "${DR_VALIDATION_INCLUSTER_COLLECT:-1}" == "1" ]]; then
  if ! "$SCRIPT_DIR/collect-logs-incluster.sh" "$initial_dir"; then
    err "Could not collect initial timestamp baseline snapshot."
    exit 1
  fi
elif ! collect_logs_to_dir "$initial_dir"; then
  err "Could not collect initial timestamp baseline snapshot."
  exit 1
fi
