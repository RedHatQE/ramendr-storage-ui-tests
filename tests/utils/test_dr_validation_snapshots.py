"""Unit tests for multi-VM HammerDB snapshot assertions."""

from __future__ import annotations

import json
from pathlib import Path

import pytest

from tests.utils.dr_validation import (
    assert_all_hammerdb_snapshots_ready,
    assert_hammerdb_snapshot_ready,
)

_POPULATED_TPCC = {
    "warehouse": 1,
    "district": 10,
    "customer": 3000,
    "stock": 100_000,
    "item": 100_000,
    "orders": 1,
    "order_line": 1,
    "new_order": 0,
    "history": 0,
}


def _snapshot(*, backend: str, tpcc: dict | None = None) -> dict:
    return {
        "database_backend": backend,
        "audit": {"records": [{"seq": 1, "committed_at": "2026-01-01T00:00:00Z"}]},
        "tpcc": tpcc if tpcc is not None else dict(_POPULATED_TPCC),
    }


def test_assert_hammerdb_snapshot_ready_enforces_tpcc_thresholds() -> None:
    assert_hammerdb_snapshot_ready(_snapshot(backend="postgres"))
    assert_hammerdb_snapshot_ready(_snapshot(backend="mssql"))

    with pytest.raises(AssertionError, match="customer"):
        assert_hammerdb_snapshot_ready(
            _snapshot(backend="mssql", tpcc={**_POPULATED_TPCC, "customer": 10})
        )


def test_assert_all_hammerdb_snapshots_ready_validates_each_vm(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setenv("DR_VALIDATION_HAMMERDB_ALL_VMS", "0")
    monkeypatch.delenv("DR_VALIDATION_HAMMERDB_VMS", raising=False)

    (tmp_path / "linux.db-snapshot.json").write_text(
        json.dumps(_snapshot(backend="postgres")), encoding="utf-8"
    )
    (tmp_path / "windows.db-snapshot.json").write_text(
        json.dumps(_snapshot(backend="mssql")), encoding="utf-8"
    )

    assert_all_hammerdb_snapshots_ready(tmp_path)


def test_assert_all_hammerdb_snapshots_ready_reports_per_vm_failures(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setenv("DR_VALIDATION_HAMMERDB_ALL_VMS", "0")
    monkeypatch.delenv("DR_VALIDATION_HAMMERDB_VMS", raising=False)

    (tmp_path / "good.db-snapshot.json").write_text(
        json.dumps(_snapshot(backend="postgres")), encoding="utf-8"
    )
    (tmp_path / "bad.db-snapshot.json").write_text(
        json.dumps(
            _snapshot(
                backend="mssql",
                tpcc={**_POPULATED_TPCC, "item": 0},
            )
        ),
        encoding="utf-8",
    )

    with pytest.raises(AssertionError, match=r"bad \(mssql\)"):
        assert_all_hammerdb_snapshots_ready(tmp_path)
