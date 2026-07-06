#!/usr/bin/env bash
set -euo pipefail

# Report DR timestamp writer status (for QA / redeploy show_status).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

if dr_validation_uses_hammerdb; then
  exec "$SCRIPT_DIR/status-hammerdb.sh"
fi

hub_install_dir="${HUB_INSTALL_DIR:-$HOME/git/hub-cluster-install}"
if [[ -z "${KUBECONFIG:-}" ]] && [[ -f "${hub_install_dir}/auth/kubeconfig" ]]; then
  export KUBECONFIG="${hub_install_dir}/auth/kubeconfig"
fi

echo "Log on each VM: ${DR_VALIDATION_LOG_PATH}"
echo "Format: seq,utc-timestamp,hostname,pid"
if [[ "${DR_VALIDATION_INCLUSTER_COLLECT:-1}" == "1" ]]; then
  echo "Checking writers via in-cluster collect (NodePort SSH is cluster-internal only)..."
  expected="${DR_VALIDATION_EXPECTED_VMS}"
  max_age="${DR_VALIDATION_STATUS_MAX_AGE_SEC:-300}"
  mkdir -p "${REPO_ROOT}/.work"
  dest="$(mktemp -d "${REPO_ROOT}/.work/dr-validation-logs/status-check.XXXXXX")"
  trap 'rm -rf "$dest"' EXIT

  if ! "$SCRIPT_DIR/collect-logs-incluster.sh" "$dest"; then
    err "In-cluster collect failed."
    exit 1
  fi

  overall_fail=0
  shopt -s nullglob
  log_files=("$dest"/*.timestamps.log)
  if [[ ${#log_files[@]} -eq 0 ]] || [[ ! -e "${log_files[0]}" ]]; then
    err "No timestamp logs collected (expected ${expected} file(s) in ${dest})."
    exit 1
  fi

  if [[ ${#log_files[@]} -lt "$expected" ]]; then
    warn "Only ${#log_files[@]}/${expected} log file(s) collected."
    overall_fail=1
  fi

  for f in "${log_files[@]}"; do
    name=$(basename "$f" .timestamps.log)
    if [[ ! -f "$f" ]]; then
      warn "  FAIL ${name} (missing file)"
      overall_fail=1
      continue
    fi
    age="$(log_last_record_age_seconds "$f")"
    if [[ "$age" -lt 0 ]] || [[ "$age" -gt "$max_age" ]]; then
      warn "  FAIL ${name} (log older than ${max_age}s)"
      overall_fail=1
      continue
    fi
    lines=$(grep -cE '^[0-9]+,20[0-9]{2}-' "$f" || true)
    if [[ "$lines" -ge 1 ]]; then
      log "  OK ${name} (${lines} records in snapshot)"
    else
      warn "  FAIL ${name} (no records)"
      overall_fail=1
    fi
  done

  exit "$overall_fail"
fi
verify_writers_recording
