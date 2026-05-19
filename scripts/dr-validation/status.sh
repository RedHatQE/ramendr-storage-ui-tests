#!/usr/bin/env bash
set -euo pipefail

# Report DR timestamp writer status (for QA / redeploy show_status).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

if [[ -z "${KUBECONFIG:-}" ]] && [[ -f "${HUB_INSTALL_DIR:-$HOME/git/hub-cluster-install}/auth/kubeconfig" ]]; then
  export KUBECONFIG="${HUB_INSTALL_DIR}/auth/kubeconfig"
fi

echo "Log on each VM: ${DR_VALIDATION_LOG_PATH}"
echo "Format: seq,utc-timestamp,hostname,pid"
if [[ "${DR_VALIDATION_INCLUSTER_COLLECT:-1}" == "1" ]]; then
  echo "Checking writers via in-cluster collect (NodePort SSH is cluster-internal only)..."
  dest="${REPO_ROOT}/.work/dr-validation-logs/status-check"
  if "$SCRIPT_DIR/collect-logs-incluster.sh" "$dest"; then
    for f in "$dest"/*.timestamps.log; do
      [[ -f "$f" ]] || continue
      lines=$(grep -cE '^[0-9]+,20[0-9]{2}-' "$f" || true)
      name=$(basename "$f" .timestamps.log)
      if [[ "$lines" -ge 1 ]]; then
        log "  OK ${name} (${lines} records in snapshot)"
      else
        warn "  FAIL ${name} (no records)"
      fi
    done
    exit 0
  fi
  exit 1
fi
verify_writers_recording
