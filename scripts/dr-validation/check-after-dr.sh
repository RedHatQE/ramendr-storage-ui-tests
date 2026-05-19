#!/usr/bin/env bash
set -euo pipefail

# One command for QA after failover/relocate in the console:
#   ./scripts/dr-validation/check-after-dr.sh
#
# Uses the latest automatic snapshot as "before" and collects fresh logs as "after".

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

export PYTHONPATH="${DR_VALIDATION_DIR}:${PYTHONPATH:-}"
INTERVAL="${DR_VALIDATION_INTERVAL:-1.0}"
CHECK_ROOT="${REPO_ROOT}/.work/dr-validation-logs/checks"
STAMP="$(date +%Y%m%d-%H%M%S)"
AFTER_DIR="${CHECK_ROOT}/${STAMP}"
SUMMARY="${AFTER_DIR}/summary.txt"

require_cmd python3 oc
if [[ "${DR_VALIDATION_INCLUSTER_COLLECT:-1}" != "1" ]]; then
  require_cmd scp ssh
fi

echo ""
echo "=============================================="
echo " RamenDR data check (after failover/relocate)"
echo "=============================================="
echo ""

ensure_hub_kubeconfig
PRIMARY="$(determine_primary_cluster)"
[[ -z "$PRIMARY" ]] && PRIMARY="(unknown)"
echo "Current primary cluster: ${PRIMARY}"
echo ""

BASELINE_DIR=""
if [[ -L "${AUTO_SNAPSHOT_ROOT}/latest" ]]; then
  BASELINE_DIR="$(cd "${AUTO_SNAPSHOT_ROOT}/latest" && pwd)"
  if [[ -f "${BASELINE_DIR}/metadata.json" ]]; then
    echo "Baseline (auto snapshot): ${BASELINE_DIR}"
    python3 -c "import json; m=json.load(open('${BASELINE_DIR}/metadata.json')); print('  taken:', m.get('collected_at_utc','?'), '| primary:', m.get('primary_cluster','?'))" 2>/dev/null || true
  else
    echo "Baseline (auto snapshot): ${BASELINE_DIR}"
  fi
else
  warn "No automatic baseline yet (daemon may still be warming up)."
  echo "  Tip: wait 5 minutes after redeploy, or run: ./scripts/dr-validation/start-snapshot-daemon.sh"
fi
echo ""

log "Collecting current logs from VMs..."
collect_ok=0
if [[ "${DR_VALIDATION_INCLUSTER_COLLECT:-1}" == "1" ]]; then
  "$SCRIPT_DIR/collect-logs-incluster.sh" "$AFTER_DIR" && collect_ok=1
elif collect_logs_to_dir "$AFTER_DIR"; then
  collect_ok=1
fi
if [[ "$collect_ok" -ne 1 ]]; then
  err "Could not collect logs. Fix SSH/routes, then retry."
  exit 1
fi
echo ""

overall_fail=0
{
  echo "RamenDR data check summary"
  echo "=========================="
  echo "Time (UTC): $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "Primary:    ${PRIMARY}"
  echo "Baseline:   ${BASELINE_DIR:-none}"
  echo "After:      ${AFTER_DIR}"
  echo ""
  printf "%-28s %-8s %s\n" "VM" "RESULT" "NOTES"
  printf "%-28s %-8s %s\n" "----------------------------" "--------" "-----"
} >"$SUMMARY"

shopt -s nullglob
log_files=("$AFTER_DIR"/*.timestamps.log)
if [[ ${#log_files[@]} -eq 0 ]] || [[ ! -e "${log_files[0]}" ]]; then
  overall_fail=1
  printf "%-28s %-8s %s\n" "(none)" "FAIL" "no timestamp logs collected in ${AFTER_DIR}" | tee -a "$SUMMARY"
else
for after_file in "${log_files[@]}"; do
  name=$(basename "$after_file" .timestamps.log)
  result="PASS"
  notes="no sequence gaps"

  if [[ -n "$BASELINE_DIR" ]] && [[ -f "${BASELINE_DIR}/$(basename "$after_file")" ]]; then
    if ! python3 -m ramendr_dr_validation.validator "$after_file" \
      --compare "${BASELINE_DIR}/$(basename "$after_file")" \
      --interval "$INTERVAL" >/dev/null 2>"${AFTER_DIR}/${name}.validate.err"; then
      result="FAIL"
      notes=$(grep -E 'seq_gaps|missing_count|parse_errors' "${AFTER_DIR}/${name}.validate.err" 2>/dev/null | head -1 || echo "see ${name}.validate.err")
      overall_fail=1
    fi
  else
    if ! python3 -m ramendr_dr_validation.validator "$after_file" --interval "$INTERVAL" \
      >/dev/null 2>"${AFTER_DIR}/${name}.validate.err"; then
      result="FAIL"
      notes="sequence gaps or parse errors (see ${name}.validate.err)"
      overall_fail=1
    fi
  fi

  printf "%-28s %-8s %s\n" "$name" "$result" "$notes" | tee -a "$SUMMARY"
done
fi

echo ""
if [[ "$overall_fail" -eq 0 ]]; then
  echo -e "${GREEN}Overall: PASS${NC} — no data loss detected in timestamp logs."
else
  echo -e "${RED}Overall: FAIL${NC} — at least one VM shows missing sequence numbers (possible data loss)."
fi
echo ""
echo "Full report folder: ${AFTER_DIR}"
echo "Summary file:       ${SUMMARY}"
echo "Attach this folder to your Jira ticket."
echo ""

exit "$overall_fail"
