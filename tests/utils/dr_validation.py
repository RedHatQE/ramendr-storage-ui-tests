"""Shared helpers for HammerDB DR validation in pytest."""

from __future__ import annotations

import json
import os
import subprocess
from pathlib import Path

from ramendr_dr_validation.tpcc_schema import validate_tpcc_populated

_REPO_ROOT = Path(__file__).resolve().parents[2]
_STATUS_TIMEOUT_SECONDS = float(os.getenv("RAMENDR_DR_STATUS_TIMEOUT_SECONDS", "600"))
_COLLECT_TIMEOUT_SECONDS = float(os.getenv("RAMENDR_DR_COLLECT_TIMEOUT_SECONDS", "600"))


def repo_root() -> Path:
    return _REPO_ROOT


def dr_validation_skipped() -> bool:
    return os.getenv("SKIP_DR_VALIDATION", "0") == "1"


def dr_validation_mode() -> str:
    return os.getenv("DR_VALIDATION_MODE", "hammerdb")


def hammerdb_mode_active() -> bool:
    return dr_validation_mode() == "hammerdb" and not dr_validation_skipped()


def hub_env(kubeconfig: str) -> dict[str, str]:
    env = os.environ.copy()
    env["KUBECONFIG"] = kubeconfig
    return env


def run_status_hammerdb(*, kubeconfig: str) -> subprocess.CompletedProcess[str]:
    script = repo_root() / "scripts" / "dr-validation" / "status-hammerdb.sh"
    return subprocess.run(  # noqa: S603
        ["bash", str(script)],  # noqa: S607
        cwd=repo_root(),
        env=hub_env(kubeconfig),
        text=True,
        capture_output=True,
        check=False,
        timeout=_STATUS_TIMEOUT_SECONDS,
    )


def collect_db_snapshot(
    *, kubeconfig: str, out_dir: Path
) -> subprocess.CompletedProcess[str]:
    script = (
        repo_root() / "scripts" / "dr-validation" / "collect-db-snapshot-incluster.sh"
    )
    out_dir.mkdir(parents=True, exist_ok=True)
    return subprocess.run(  # noqa: S603
        ["bash", str(script), str(out_dir)],  # noqa: S607
        cwd=repo_root(),
        env=hub_env(kubeconfig),
        text=True,
        capture_output=True,
        check=False,
        timeout=_COLLECT_TIMEOUT_SECONDS,
    )


def load_hammerdb_snapshot(
    snapshot_dir: Path,
    *,
    vm_name: str | None = None,
) -> dict:
    vm_name = vm_name or os.getenv("DR_VALIDATION_HAMMERDB_VM", "rhel9-node-001")
    expected = f"{vm_name}.db-snapshot.json"
    snapshot_path = snapshot_dir / expected
    if snapshot_path.is_file():
        return json.loads(snapshot_path.read_text(encoding="utf-8"))

    files = sorted(snapshot_dir.glob("*.db-snapshot.json"))
    assert files, f"No DB snapshot JSON found under {snapshot_dir}"
    if len(files) == 1:
        return json.loads(files[0].read_text(encoding="utf-8"))

    available = ", ".join(f.name for f in files)
    raise AssertionError(
        f"No DB snapshot for VM {vm_name!r} ({expected}) under {snapshot_dir}; "
        f"found: {available}"
    )


def assert_hammerdb_snapshot_ready(snapshot: dict) -> None:
    audit = snapshot.get("audit") or {}
    records = audit.get("records") or []
    assert records, "dr_validation_audit has no rows — workload not recording"

    tpcc = snapshot.get("tpcc") or {}
    tpcc_errors = validate_tpcc_populated(tpcc)
    assert not tpcc_errors, "TPC-C tables not populated after deploy:\n" + "\n".join(
        f"  - {err}" for err in tpcc_errors
    )

    assert tpcc.get("customer", 0) >= 3000, (
        "customer table should contain 3000 rows per warehouse (numeric c_id + profile fields)"
    )
