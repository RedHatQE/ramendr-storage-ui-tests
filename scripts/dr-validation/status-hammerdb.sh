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
overall_fail=0
expected_snapshots="$(hammerdb_target_vm_count)"
if [[ ${#snapshots[@]} -lt "$expected_snapshots" ]]; then
  warn "Expected ${expected_snapshots} snapshot(s), collected ${#snapshots[@]}."
  overall_fail=1
fi
for f in "${snapshots[@]}"; do
  name=$(basename "$f" .db-snapshot.json)
  read -r record_count last_seq age_ok tpcc_ok < <(
    python3 - "$f" "$max_age" <<'PY'
import json
import sys
from datetime import datetime, timezone
from pathlib import Path

from ramendr_dr_validation.tpcc_schema import validate_tpcc_populated

snap = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
max_age = float(sys.argv[2])
audit = snap.get("audit") or {}
records = audit.get("records") or []
record_count = len(records)
last_seq = audit.get("last_seq") or 0
age_ok = 0
if records:
    last_ts = records[-1]["committed_at"]
    if last_ts.endswith("Z"):
        last_ts = last_ts[:-1] + "+00:00"
    dt = datetime.fromisoformat(last_ts)
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    age = (datetime.now(timezone.utc) - dt).total_seconds()
    age_ok = 1 if age <= max_age else 0
tpcc = snap.get("tpcc") or {}
tpcc_errors = validate_tpcc_populated(tpcc)
tpcc_ok = 0 if tpcc_errors else 1
print(record_count, last_seq, age_ok, tpcc_ok)
PY
  )
  if [[ "$record_count" -ge 1 && "$age_ok" == "1" && "$tpcc_ok" == "1" ]]; then
    log "  OK ${name} (audit seq=${last_seq}, TPC-C populated)"
  else
    warn "  FAIL ${name} (records=${record_count}, fresh=${age_ok}, tpcc=${tpcc_ok})"
    if [[ "$tpcc_ok" != "1" ]]; then
      python3 - "$f" <<'PY' || true
import json, sys
from pathlib import Path
from ramendr_dr_validation.tpcc_schema import validate_tpcc_populated
snap = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
for err in validate_tpcc_populated(snap.get("tpcc") or {}):
    print(f"    {err}")
PY
    fi
    overall_fail=1
  fi
done

exit "$overall_fail"
