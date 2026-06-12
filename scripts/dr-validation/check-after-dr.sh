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
INTERVAL="${DR_VALIDATION_INTERVAL:-10.0}"
# Default aligns with the 2m-vm DRPolicy: ≤120 s data loss is acceptable.
# Override with DR_VALIDATION_MAX_RPO_SECONDS if the policy schedule changes.
MAX_RPO_SECONDS="${DR_VALIDATION_MAX_RPO_SECONDS:-120}"
# UTC datetime of the "Initiate" UI click (ISO-8601).  Set by test_sanity.py via
# DR_VALIDATION_CUTOFF_UTC.  When empty the cutoff-based RPO check is skipped.
CUTOFF_UTC="${DR_VALIDATION_CUTOFF_UTC:-}"
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
echo "RPO standard (max): ${MAX_RPO_SECONDS}s"
if [[ -n "$CUTOFF_UTC" ]]; then
  echo "DR initiation cutoff: ${CUTOFF_UTC}"
else
  echo "DR initiation cutoff: (not set — cutoff-based RPO check skipped)"
fi
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
  echo "RPO max:    ${MAX_RPO_SECONDS}s"
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
  notes="continuous"
  before_file=""
  if [[ -n "$BASELINE_DIR" ]] && [[ -f "${BASELINE_DIR}/$(basename "$after_file")" ]]; then
    before_file="${BASELINE_DIR}/$(basename "$after_file")"
  fi
  validate_json="${AFTER_DIR}/${name}.validate.json"
  validate_err="${AFTER_DIR}/${name}.validate.err"

  if ! python3 - "$after_file" "$before_file" "$INTERVAL" "$validate_json" "$CUTOFF_UTC" >"$validate_err" 2>&1 <<'PY'; then
import json
import sys
from datetime import datetime, timezone
from pathlib import Path

from ramendr_dr_validation.validator import compare_logs, load_records, validate_records

after_path = Path(sys.argv[1])
before_path_raw = sys.argv[2]
interval = float(sys.argv[3])
report_path = Path(sys.argv[4])
cutoff_raw = sys.argv[5] if len(sys.argv) > 5 else ""

records, parse_errors = load_records(after_path)
report = validate_records(records, str(after_path))
report.parse_errors = parse_errors

comparison = None
missing_count = 0
if before_path_raw:
    before_path = Path(before_path_raw)
    before_records, before_errors = load_records(before_path)
    report.parse_errors.extend(before_errors)
    comparison = compare_logs(before_records, records)
    missing_count = int(comparison.get("missing_count", 0))

max_gap = report.max_seq_gap()
estimated_rpo = max_gap * interval if max_gap > 0 else 0.0

# RPO relative to the DR initiation click: (cutoff_time - last_pre_cutoff_vm_timestamp).
# Measures how stale the last replicated snapshot was when we declared the disaster.
#
# We filter to records written BEFORE the cutoff because after failover/relocate the
# VMs resume writing new timestamps on the target cluster.  Using records[-1] (the
# latest overall) would yield a negative or near-zero RPO that hides real data loss.
rpo_from_cutoff_seconds = None
if cutoff_raw and records:
    try:
        cutoff_s = cutoff_raw if not cutoff_raw.endswith("Z") else cutoff_raw[:-1] + "+00:00"
        cutoff_dt = datetime.fromisoformat(cutoff_s)
        if cutoff_dt.tzinfo is None:
            cutoff_dt = cutoff_dt.replace(tzinfo=timezone.utc)
        pre_cutoff = [
            r for r in records
            if (r.timestamp if r.timestamp.tzinfo else r.timestamp.replace(tzinfo=timezone.utc))
            <= cutoff_dt
        ]
        if pre_cutoff:
            last_ts = pre_cutoff[-1].timestamp
            if last_ts.tzinfo is None:
                last_ts = last_ts.replace(tzinfo=timezone.utc)
            rpo_from_cutoff_seconds = (cutoff_dt - last_ts).total_seconds()
    except (ValueError, TypeError):
        pass

payload = {
    "log": str(after_path),
    "record_count": report.record_count,
    "ok": report.ok,
    "seq_gap_count": len(report.seq_gaps),
    "parse_error_count": len(report.parse_errors),
    "duplicate_seq_count": len(report.duplicate_seqs),
    "timestamp_regression_count": len(report.timestamp_regressions),
    "max_seq_gap": max_gap,
    "estimated_rpo_seconds_upper_bound": estimated_rpo,
    "rpo_from_cutoff_seconds": rpo_from_cutoff_seconds,
    "comparison": comparison,
    "missing_count": missing_count,
}

report_path.write_text(json.dumps(payload, indent=2), encoding="utf-8")
if (not report.ok) or missing_count > 0:
    print(json.dumps(payload, indent=2))
    raise SystemExit(1)
PY
    result="FAIL"
    notes="sequence continuity/compare failed (see ${name}.validate.err)"
    overall_fail=1
  fi

  if [[ -f "$validate_json" ]]; then
    read -r estimated_rpo missing_count gap_exceeded cutoff_rpo cutoff_exceeded < <(
      python3 - "$validate_json" "$MAX_RPO_SECONDS" <<'PY'
import sys
from pathlib import Path

data = __import__("json").loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
max_rpo = float(sys.argv[2])
estimated = float(data.get("estimated_rpo_seconds_upper_bound", 0.0))
missing = int(data.get("missing_count", 0))
gap_exceeded = 1 if estimated > max_rpo else 0
cutoff_val = data.get("rpo_from_cutoff_seconds")
cutoff_rpo = float(cutoff_val) if cutoff_val is not None else -1.0
cutoff_exceeded = 1 if (cutoff_val is not None and cutoff_rpo > max_rpo) else 0
print(estimated, missing, gap_exceeded, cutoff_rpo, cutoff_exceeded)
PY
    )
    if [[ "$gap_exceeded" == "1" ]]; then
      result="FAIL"
      notes="sequence-gap RPO ${estimated_rpo}s > ${MAX_RPO_SECONDS}s"
      overall_fail=1
    elif [[ "$cutoff_exceeded" == "1" ]]; then
      result="FAIL"
      notes="cutoff RPO ${cutoff_rpo}s > ${MAX_RPO_SECONDS}s (data older than initiation by >${MAX_RPO_SECONDS}s)"
      overall_fail=1
    elif [[ "$result" == "PASS" ]]; then
      if [[ "$missing_count" != "0" ]]; then
        result="FAIL"
        notes="missing baseline sequences=${missing_count}"
        overall_fail=1
      elif [[ "$cutoff_rpo" != "-1" ]]; then
        notes="cutoff RPO ${cutoff_rpo}s <= ${MAX_RPO_SECONDS}s (gap RPO ${estimated_rpo}s)"
      else
        notes="gap RPO ${estimated_rpo}s <= ${MAX_RPO_SECONDS}s"
      fi
    fi
  elif [[ "$result" == "PASS" ]]; then
    result="FAIL"
    notes="missing validation report ${name}.validate.json"
    overall_fail=1
  fi

  printf "%-28s %-8s %s\n" "$name" "$result" "$notes" | tee -a "$SUMMARY"
done
fi

echo ""
if [[ "$overall_fail" -eq 0 ]]; then
  echo -e "${GREEN}Overall: PASS${NC} — timestamp continuity and RPO standard satisfied."
else
  echo -e "${RED}Overall: FAIL${NC} — at least one VM breached continuity or RPO standard."
fi
echo ""
echo "Full report folder: ${AFTER_DIR}"
echo "Summary file:       ${SUMMARY}"
echo "Attach this folder to your Jira ticket."
echo ""

exit "$overall_fail"
