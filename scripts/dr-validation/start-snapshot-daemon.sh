#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

ensure_hub_kubeconfig

if [[ "${SKIP_DR_VALIDATION_SNAPSHOTS:-0}" == "1" ]] || [[ "${SKIP_DR_VALIDATION:-0}" == "1" ]]; then
  log "Automatic snapshots disabled (SKIP_DR_VALIDATION or SKIP_DR_VALIDATION_SNAPSHOTS)."
  exit 0
fi

mkdir -p "$(dirname "$SNAPSHOT_DAEMON_PID_FILE")" "$AUTO_SNAPSHOT_ROOT"

SNAPSHOT_DAEMON_LOCK_DIR="${REPO_ROOT}/.work/dr-validation-snapshot-daemon.lock.d"
if ! mkdir "$SNAPSHOT_DAEMON_LOCK_DIR" 2>/dev/null; then
  log "Another start-snapshot-daemon invocation holds the lock; exiting."
  exit 0
fi
trap 'rmdir "$SNAPSHOT_DAEMON_LOCK_DIR" 2>/dev/null || true' EXIT

if [[ -f "$SNAPSHOT_DAEMON_PID_FILE" ]]; then
  old_pid=$(cat "$SNAPSHOT_DAEMON_PID_FILE")
  if kill -0 "$old_pid" 2>/dev/null; then
    log "Snapshot daemon already running (pid ${old_pid})."
    exit 0
  fi
fi

if dr_validation_uses_hammerdb; then
  mkdir -p "$DR_VALIDATION_DB_SNAPSHOT_ROOT"
  seed_db_baseline_snapshot_if_missing
fi

nohup "$SCRIPT_DIR/snapshot-daemon.sh" >>"$SNAPSHOT_DAEMON_LOG" 2>&1 &
echo $! >"$SNAPSHOT_DAEMON_PID_FILE"
log "Snapshot daemon started (pid $(cat "$SNAPSHOT_DAEMON_PID_FILE"), every ${DR_VALIDATION_SNAPSHOT_INTERVAL:-300}s)."
log "Log file: ${SNAPSHOT_DAEMON_LOG}"
