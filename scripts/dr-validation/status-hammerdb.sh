#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

export PYTHONPATH="${DR_VALIDATION_DIR}:${PYTHONPATH:-}"

hub_install_dir="${HUB_INSTALL_DIR:-$HOME/git/hub-cluster-install}"
if [[ -z "${KUBECONFIG:-}" ]] && [[ -f "${hub_install_dir}/auth/kubeconfig" ]]; then
  export KUBECONFIG="${hub_install_dir}/auth/kubeconfig"
fi

echo "Validation mode: hammerdb (all edge VMs when DR_VALIDATION_HAMMERDB_ALL_VMS=1)"
echo "Checking HammerDB workload via in-cluster DB snapshot..."

export DR_VALIDATION_SNAPSHOT_STATUS_ONLY=1

mkdir -p "${REPO_ROOT}/.work/dr-validation-db"
dest="$(mktemp -d "${REPO_ROOT}/.work/dr-validation-db/status-check.XXXXXX")"
trap 'rm -rf "$dest"' EXIT

if ! "$SCRIPT_DIR/collect-db-snapshot-incluster.sh" "$dest"; then
  err "In-cluster DB snapshot collect failed."
  exit 1
fi

shopt -s nullglob
snapshots=("$dest"/*.db-snapshot.json)
if [[ ${#snapshots[@]} -eq 0 ]]; then
  err "No DB snapshot collected for HammerDB target VM(s)."
  exit 1
fi

max_age="${DR_VALIDATION_STATUS_MAX_AGE_SEC:-300}"
# Allow VM clocks slightly ahead of the collector (negative age) without false FAIL.
clock_skew="${DR_VALIDATION_STATUS_CLOCK_SKEW_SEC:-30}"
overall_fail=0
expected_snapshots="$(hammerdb_target_vm_count)"
if [[ ${#snapshots[@]} -lt "$expected_snapshots" ]]; then
  warn "Expected ${expected_snapshots} snapshot(s), collected ${#snapshots[@]}."
  overall_fail=1
fi
for f in "${snapshots[@]}"; do
  name=$(basename "$f" .db-snapshot.json)
  read -r record_count last_seq age_ok tpcc_ok age_sec last_ts collected_at < <(
    python3 - "$f" "$max_age" "$clock_skew" <<'PY'
import json
import sys
from datetime import datetime, timezone
from pathlib import Path


from ramendr_dr_validation.tpcc_schema import validate_tpcc_populated
from ramendr_dr_validation.tpcc_counts import validate_tpcc_static_only

snap = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
max_age = float(sys.argv[2])
clock_skew = float(sys.argv[3])
audit = snap.get("audit") or {}
records = audit.get("records") or []
record_count = audit.get("record_count")
if record_count is None:
    record_count = len(records)
else:
    record_count = int(record_count)
last_seq = audit.get("last_seq") or 0
age_ok = 0
age = ""
last_ts = audit.get("last_committed_at") or ""
if not last_ts and records:
    last_ts = records[-1]["committed_at"]
ref_raw = snap.get("collected_at_utc") or ""
if last_ts:
    last_ts_norm = last_ts
    if last_ts_norm.endswith("Z"):
        last_ts_norm = last_ts_norm[:-1] + "+00:00"
    last_dt = datetime.fromisoformat(last_ts_norm)
    if last_dt.tzinfo is None:
        last_dt = last_dt.replace(tzinfo=timezone.utc)
    if ref_raw:
        ref_norm = ref_raw
        if ref_norm.endswith("Z"):
            ref_norm = ref_norm[:-1] + "+00:00"
        ref_dt = datetime.fromisoformat(ref_norm)
        if ref_dt.tzinfo is None:
            ref_dt = ref_dt.replace(tzinfo=timezone.utc)
    else:
        ref_dt = datetime.now(timezone.utc)
        ref_raw = ref_dt.strftime("%Y-%m-%dT%H:%M:%S.%f")[:-3] + "Z"
    age_val = (ref_dt - last_dt).total_seconds()
    age = f"{age_val:.1f}"
    # Permit small negative age when the VM clock is ahead of the collector.
    age_ok = 1 if -clock_skew <= age_val <= max_age else 0
tpcc = snap.get("tpcc") or {}
mode = snap.get("snapshot_mode", "dr")
if mode == "status-only":
    tpcc_errors = validate_tpcc_static_only(tpcc)
else:
    tpcc_errors = validate_tpcc_populated(tpcc)
tpcc_ok = 0 if tpcc_errors else 1
# Keep tokens single-field for bash read (timestamps are ISO-8601 without spaces).
print(
    record_count,
    last_seq,
    age_ok,
    tpcc_ok,
    age if age != "" else "n/a",
    last_ts or "n/a",
    ref_raw or "n/a",
)
PY
  )
  if [[ "$record_count" -ge 1 && "$age_ok" == "1" && "$tpcc_ok" == "1" ]]; then
    log "  OK ${name} (audit seq=${last_seq}, TPC-C populated)"
  else
    warn "  FAIL ${name} (records=${record_count}, fresh=${age_ok}, tpcc=${tpcc_ok})"
    warn "    age_sec=${age_sec} last_committed_at=${last_ts} collected_at_utc=${collected_at} (max_age=${max_age}s, clock_skew=${clock_skew}s)"
    if [[ "$tpcc_ok" != "1" ]]; then
      python3 - "$f" <<'PY' || true
import json, sys
from pathlib import Path
from ramendr_dr_validation.tpcc_schema import validate_tpcc_populated
from ramendr_dr_validation.tpcc_counts import validate_tpcc_static_only
snap = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
mode = snap.get("snapshot_mode", "dr")
errors = (
    validate_tpcc_static_only(snap.get("tpcc") or {})
    if mode == "status-only"
    else validate_tpcc_populated(snap.get("tpcc") or {})
)
for err in errors:
    print(f"    {err}")
PY
    fi
    overall_fail=1
  fi
done

exit "$overall_fail"
