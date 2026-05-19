#!/usr/bin/env bash
set -euo pipefail

# Background loop: snapshot VM timestamp logs every DR_VALIDATION_SNAPSHOT_INTERVAL seconds (default 5 min).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

INTERVAL="${DR_VALIDATION_SNAPSHOT_INTERVAL:-300}"

log "Automatic snapshot daemon started (every ${INTERVAL}s)."
log "Snapshots: ${AUTO_SNAPSHOT_ROOT}/<timestamp>  (latest -> auto/latest)"

while true; do
  stamp="$(date +%Y%m%d-%H%M%S)"
  dest="${AUTO_SNAPSHOT_ROOT}/${stamp}"
  if [[ "${DR_VALIDATION_INCLUSTER_COLLECT:-1}" == "1" ]]; then
    collect_ok=0
    "$SCRIPT_DIR/collect-logs-incluster.sh" "$dest" 2>>"$SNAPSHOT_DAEMON_LOG" && collect_ok=1
  elif collect_logs_to_dir "$dest" 2>>"$SNAPSHOT_DAEMON_LOG"; then
    collect_ok=1
  else
    collect_ok=0
  fi
  if [[ "$collect_ok" -eq 1 ]]; then
    if ! update_latest_snapshot_link "$dest" 2>>"$SNAPSHOT_DAEMON_LOG"; then
      echo "[$(date -u +%H:%M:%S)] WARN update_latest_snapshot_link failed for ${dest}" >>"$SNAPSHOT_DAEMON_LOG"
    fi
    if ! prune_auto_snapshots 2>>"$SNAPSHOT_DAEMON_LOG"; then
      echo "[$(date -u +%H:%M:%S)] WARN prune_auto_snapshots failed" >>"$SNAPSHOT_DAEMON_LOG"
    fi
    echo "[$(date -u +%H:%M:%S)] Auto-snapshot saved: ${dest}" >>"$SNAPSHOT_DAEMON_LOG"
  else
    echo "[$(date -u +%H:%M:%S)] WARN Auto-snapshot failed at ${stamp}" >>"$SNAPSHOT_DAEMON_LOG"
  fi
  sleep "$INTERVAL"
done
