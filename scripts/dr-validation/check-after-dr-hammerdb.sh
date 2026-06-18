#!/usr/bin/env bash
set -euo pipefail

# Validate HammerDB PostgreSQL data after failover/relocate.
# Uses the pre-DR baseline snapshot (auto/latest) when available.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

export PYTHONPATH="${DR_VALIDATION_DIR}:${PYTHONPATH:-}"
INTERVAL="${DR_VALIDATION_INTERVAL:-10.0}"
MAX_RPO_SECONDS="${DR_VALIDATION_MAX_RPO_SECONDS:-120}"
CUTOFF_UTC="${DR_VALIDATION_CUTOFF_UTC:-}"
CHECK_ROOT="${REPO_ROOT}/.work/dr-validation-db/checks"
STAMP="$(date +%Y%m%d-%H%M%S)"
AFTER_DIR="${CHECK_ROOT}/${STAMP}"
SUMMARY="${AFTER_DIR}/summary.txt"
AUTO_DB_SNAPSHOT_ROOT="${DR_VALIDATION_DB_SNAPSHOT_ROOT}"

require_cmd python3 oc

echo ""
echo "======================================================"
echo " RamenDR HammerDB data check (after failover/relocate)"
echo "======================================================"
echo ""

ensure_hub_kubeconfig
PRIMARY="$(determine_primary_cluster)"
[[ -z "$PRIMARY" ]] && PRIMARY="(unknown)"
echo "Current primary cluster: ${PRIMARY}"
echo "HammerDB VM:           ${DR_VALIDATION_HAMMERDB_VM}"
echo "RPO standard (max):    ${MAX_RPO_SECONDS}s"
if [[ -n "$CUTOFF_UTC" ]]; then
  echo "DR initiation cutoff:  ${CUTOFF_UTC}"
else
  echo "DR initiation cutoff:  (not set — cutoff-based RPO check skipped)"
fi
echo ""

BASELINE_DIR=""
if [[ -L "${AUTO_DB_SNAPSHOT_ROOT}/latest" ]]; then
  if BASELINE_DIR="$(cd "${AUTO_DB_SNAPSHOT_ROOT}/latest" 2>/dev/null && pwd)"; then
    echo "Baseline (DB snapshot): ${BASELINE_DIR}"
  else
    warn "Baseline symlink auto/latest is dangling (target directory was removed)."
    echo "  Tip: run ./scripts/dr-validation/save-db-baseline-snapshot.sh before DR."
  fi
else
  warn "No DB baseline snapshot yet."
  echo "  Tip: run redeploy or ./scripts/dr-validation/save-db-baseline-snapshot.sh before DR."
fi
echo ""

log "Collecting current DB snapshot from ${DR_VALIDATION_HAMMERDB_VM}..."
mkdir -p "$AFTER_DIR"
if ! "$SCRIPT_DIR/collect-db-snapshot-incluster.sh" "$AFTER_DIR"; then
  err "Could not collect DB snapshot. Fix SSH/services on ${DR_VALIDATION_HAMMERDB_VM}, then retry."
  exit 1
fi
echo ""

overall_fail=0
{
  echo "RamenDR HammerDB data check summary"
  echo "==================================="
  echo "Time (UTC): $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "Primary:    ${PRIMARY}"
  echo "HammerDB VM:${DR_VALIDATION_HAMMERDB_VM}"
  echo "RPO max:    ${MAX_RPO_SECONDS}s"
  echo "Baseline:   ${BASELINE_DIR:-none}"
  echo "After:      ${AFTER_DIR}"
  echo ""
  printf "%-28s %-8s %s\n" "TARGET" "RESULT" "NOTES"
  printf "%-28s %-8s %s\n" "----------------------------" "--------" "-----"
} >"$SUMMARY"

shopt -s nullglob
snapshot_files=("$AFTER_DIR"/*.db-snapshot.json)
if [[ ${#snapshot_files[@]} -eq 0 ]] || [[ ! -e "${snapshot_files[0]}" ]]; then
  overall_fail=1
  printf "%-28s %-8s %s\n" "(none)" "FAIL" "no DB snapshots collected in ${AFTER_DIR}" | tee -a "$SUMMARY"
else
  for after_file in "${snapshot_files[@]}"; do
    name=$(basename "$after_file" .db-snapshot.json)
    result="PASS"
    notes="continuous"
    before_file=""
    if [[ -n "$BASELINE_DIR" ]] && [[ -f "${BASELINE_DIR}/$(basename "$after_file")" ]]; then
      before_file="${BASELINE_DIR}/$(basename "$after_file")"
    fi
    validate_json="${AFTER_DIR}/${name}.validate.json"
    validate_err="${AFTER_DIR}/${name}.validate.err"

    compare_args=()
    [[ -n "$before_file" ]] && compare_args+=(--compare "$before_file")
    [[ -n "$CUTOFF_UTC" ]] && compare_args+=(--cutoff-utc "$CUTOFF_UTC")

    if ! python3 -m ramendr_dr_validation.db_validator "$after_file" \
      --interval "$INTERVAL" \
      "${compare_args[@]}" \
      -o "$validate_json" >"$validate_err" 2>&1; then
      result="FAIL"
      notes="database continuity/compare failed (see ${name}.validate.err)"
      overall_fail=1
    fi

    if [[ -f "$validate_json" ]]; then
      read -r estimated_rpo missing_count gap_exceeded cutoff_rpo cutoff_exceeded tpcc_issues < <(
        python3 - "$validate_json" "$MAX_RPO_SECONDS" <<'PY'
import sys
from pathlib import Path

data = __import__("json").loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
max_rpo = float(sys.argv[2])
estimated = float(data.get("estimated_rpo_seconds_upper_bound", 0.0))
missing = int(data.get("missing_count", 0))
gap_exceeded = 1 if estimated > max_rpo else 0
cutoff_val = data.get("rpo_from_cutoff_seconds")
cutoff_rpo = int(cutoff_val) if cutoff_val is not None else -1
cutoff_exceeded = 1 if (cutoff_val is not None and cutoff_rpo > max_rpo) else 0
tpcc_issues = len(data.get("tpcc_regressions") or [])
print(estimated, missing, gap_exceeded, cutoff_rpo, cutoff_exceeded, tpcc_issues)
PY
      )
      if [[ "$gap_exceeded" == "1" ]]; then
        result="FAIL"
        notes="audit-gap RPO ${estimated_rpo}s > ${MAX_RPO_SECONDS}s"
        overall_fail=1
      elif [[ "$cutoff_exceeded" == "1" ]]; then
        result="FAIL"
        notes="cutoff RPO ${cutoff_rpo}s > ${MAX_RPO_SECONDS}s"
        overall_fail=1
      elif [[ "$tpcc_issues" != "0" ]]; then
        result="FAIL"
        notes="TPC-C row-count regression (${tpcc_issues} table(s))"
        overall_fail=1
      elif [[ "$result" == "PASS" ]]; then
        if [[ "$missing_count" != "0" ]]; then
          result="FAIL"
          notes="missing baseline audit sequences=${missing_count}"
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
  echo -e "${GREEN}Overall: PASS${NC} — HammerDB PostgreSQL continuity and RPO standard satisfied."
else
  echo -e "${RED}Overall: FAIL${NC} — database validation breached continuity or RPO standard."
fi
echo ""
echo "Full report folder: ${AFTER_DIR}"
echo "Summary file:       ${SUMMARY}"
echo ""

exit "$overall_fail"
