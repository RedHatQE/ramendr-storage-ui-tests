#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

if [[ ! -f "$SNAPSHOT_DAEMON_PID_FILE" ]]; then
  log "Snapshot daemon is not running (no pid file)."
  exit 0
fi

pid=$(cat "$SNAPSHOT_DAEMON_PID_FILE")
if kill -0 "$pid" 2>/dev/null; then
  proc=$(ps -p "$pid" -o args= 2>/dev/null || ps -p "$pid" -o comm= 2>/dev/null || true)
  if [[ "$proc" == *snapshot-daemon.sh* ]]; then
    kill "$pid" 2>/dev/null || true
    log "Stopped snapshot daemon (pid ${pid})."
  else
    warn "PID ${pid} is not snapshot-daemon (${proc:-unknown}); removing stale pid file."
    rm -f "$SNAPSHOT_DAEMON_PID_FILE"
    exit 0
  fi
else
  log "Snapshot daemon pid ${pid} was not running."
fi
rm -f "$SNAPSHOT_DAEMON_PID_FILE"
