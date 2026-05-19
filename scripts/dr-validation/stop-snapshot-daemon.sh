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
if ! kill -0 "$pid" 2>/dev/null; then
  log "Snapshot daemon pid ${pid} was not running."
  rm -f "$SNAPSHOT_DAEMON_PID_FILE"
  exit 0
fi

proc=$(ps -p "$pid" -o args= 2>/dev/null || ps -p "$pid" -o comm= 2>/dev/null || true)
if [[ "$proc" != *snapshot-daemon.sh* ]]; then
  warn "PID ${pid} is not snapshot-daemon (${proc:-unknown}); removing stale pid file."
  rm -f "$SNAPSHOT_DAEMON_PID_FILE"
  exit 0
fi

kill "$pid" 2>/dev/null || true
stopped=0
for _ in 1 2 3 4 5 6 7 8 9 10; do
  if ! kill -0 "$pid" 2>/dev/null; then
    stopped=1
    break
  fi
  sleep 1
done

if [[ "$stopped" -eq 0 ]]; then
  warn "Snapshot daemon (pid ${pid}) did not exit after SIGTERM; sending SIGKILL."
  kill -9 "$pid" 2>/dev/null || true
  for _ in 1 2 3 4 5; do
    if ! kill -0 "$pid" 2>/dev/null; then
      stopped=1
      break
    fi
    sleep 1
  done
fi

if [[ "$stopped" -eq 1 ]]; then
  rm -f "$SNAPSHOT_DAEMON_PID_FILE"
  log "Stopped snapshot daemon (pid ${pid})."
else
  warn "Snapshot daemon (pid ${pid}) is still running; leaving pid file in place."
  exit 1
fi
