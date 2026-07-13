"""Unit tests for HammerDB PostgreSQL snapshot validation."""

from __future__ import annotations

import json
from datetime import datetime, timezone
from pathlib import Path

import pytest

from ramendr_dr_validation.db_validator import (
    compare_cross_disk_coherence,
    validate_snapshot_file,
)


def _snapshot(
    records: list[dict],
    tpcc: dict[str, int] | None = None,
    *,
    storage: dict | None = None,
) -> dict:
    payload = {
        "collected_at_utc": "2026-06-15T12:00:00.000Z",
        "vm_name": "edgenode-0",
        "database_backend": "postgres",
        "database": "tpcc",
        "audit": {
            "record_count": len(records),
            "first_seq": records[0]["seq"] if records else None,
            "last_seq": records[-1]["seq"] if records else None,
            "records": records,
        },
        "tpcc": tpcc
        or {
            "warehouse": 1,
            "district": 10,
            "customer": 3000,
            "stock": 100_000,
            "item": 100_000,
            "orders": 900,
            "order_line": 0,
            "new_order": 0,
            "history": 0,
        },
    }
    if storage is not None:
        payload["storage"] = storage
    return payload


def _write_snapshot(path: Path, payload: dict) -> None:
    path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")


def test_validate_continuous_audit_passes(tmp_path: Path) -> None:
    records = [
        {
            "seq": i,
            "committed_at": f"2026-06-15T12:00:{i:02d}.000Z",
            "hostname": "edgenode-0",
            "source": "db_audit",
        }
        for i in range(1, 6)
    ]
    after = tmp_path / "edgenode-0.db-snapshot.json"
    _write_snapshot(after, _snapshot(records))

    payload = validate_snapshot_file(after, interval=10.0)
    assert payload["ok"] is True
    assert payload["seq_gaps"] == []


def test_validate_detects_audit_gap(tmp_path: Path) -> None:
    records = [
        {
            "seq": 1,
            "committed_at": "2026-06-15T12:00:01.000Z",
            "hostname": "edgenode-0",
            "source": "db_audit",
        },
        {
            "seq": 3,
            "committed_at": "2026-06-15T12:00:11.000Z",
            "hostname": "edgenode-0",
            "source": "db_audit",
        },
    ]
    after = tmp_path / "edgenode-0.db-snapshot.json"
    _write_snapshot(after, _snapshot(records))

    payload = validate_snapshot_file(after, interval=10.0)
    assert payload["ok"] is False
    assert payload["max_seq_gap"] == 1
    assert payload["estimated_rpo_seconds_upper_bound"] == 10.0


def test_validate_tpcc_regression_against_baseline(tmp_path: Path) -> None:
    before_records = [
        {
            "seq": i,
            "committed_at": f"2026-06-15T12:00:{i:02d}.000Z",
            "hostname": "edgenode-0",
            "source": "db_audit",
        }
        for i in range(1, 4)
    ]
    after_records = before_records + [
        {
            "seq": 4,
            "committed_at": "2026-06-15T12:00:40.000Z",
            "hostname": "edgenode-0",
            "source": "db_audit",
        }
    ]
    before = tmp_path / "before.json"
    after = tmp_path / "after.json"
    _write_snapshot(
        before,
        _snapshot(
            before_records,
            tpcc={
                "customer": 3000,
                "orders": 900,
                "warehouse": 1,
                "district": 10,
                "stock": 100_000,
                "item": 100_000,
                "order_line": 0,
                "new_order": 0,
                "history": 0,
            },
        ),
    )
    _write_snapshot(
        after,
        _snapshot(
            after_records,
            tpcc={
                "customer": 2990,
                "orders": 890,
                "warehouse": 1,
                "district": 10,
                "stock": 100_000,
                "item": 100_000,
                "order_line": 0,
                "new_order": 0,
                "history": 0,
            },
        ),
    )

    payload = validate_snapshot_file(
        after,
        before_path=before,
        interval=10.0,
    )
    assert payload["ok"] is False
    assert payload["tpcc_regressions"]


def test_rpo_from_cutoff_uses_last_pre_cutoff_record(tmp_path: Path) -> None:
    records = [
        {
            "seq": 1,
            "committed_at": "2026-06-15T12:00:00.000Z",
            "hostname": "edgenode-0",
            "source": "db_audit",
        },
        {
            "seq": 2,
            "committed_at": "2026-06-15T12:00:30.000Z",
            "hostname": "edgenode-0",
            "source": "db_audit",
        },
        {
            "seq": 3,
            "committed_at": "2026-06-15T12:02:00.000Z",
            "hostname": "edgenode-0",
            "source": "db_audit",
        },
    ]
    after = tmp_path / "edgenode-0.db-snapshot.json"
    _write_snapshot(after, _snapshot(records))

    payload = validate_snapshot_file(
        after,
        interval=10.0,
        cutoff_utc=datetime(2026, 6, 15, 12, 1, 0, tzinfo=timezone.utc).isoformat(),
    )
    assert payload["rpo_from_cutoff_seconds"] == 30.0


def test_validate_fails_when_baseline_compare_missing(tmp_path: Path) -> None:
    after = tmp_path / "edgenode-0.db-snapshot.json"
    _write_snapshot(
        after,
        _snapshot(
            [
                {
                    "seq": 1,
                    "committed_at": "2026-06-15T12:00:01.000Z",
                    "hostname": "edgenode-0",
                    "source": "db_audit",
                }
            ]
        ),
    )
    missing_baseline = tmp_path / "missing-baseline.json"

    payload = validate_snapshot_file(
        after,
        before_path=missing_baseline,
        interval=10.0,
    )

    assert payload["ok"] is False
    assert any("Baseline snapshot not found" in err for err in payload["parse_errors"])


def test_validate_rejects_non_positive_interval(tmp_path: Path) -> None:
    after = tmp_path / "edgenode-0.db-snapshot.json"
    _write_snapshot(
        after,
        _snapshot(
            [
                {
                    "seq": 1,
                    "committed_at": "2026-06-15T12:00:01.000Z",
                    "hostname": "edgenode-0",
                    "source": "db_audit",
                }
            ]
        ),
    )

    with pytest.raises(ValueError, match="interval must be positive"):
        validate_snapshot_file(after, interval=0)


def test_compare_cross_disk_detects_audit_only_recovery() -> None:
    dual = {"dual_disk": True, "audit_tablespace": "ramendr_os"}
    before = _snapshot(
        [
            {
                "seq": 10,
                "committed_at": "2026-06-15T12:00:10.000Z",
                "hostname": "edgenode-0",
                "source": "db_audit",
            }
        ],
        tpcc={"orders": 900, "order_line": 0, "new_order": 0, "history": 0},
        storage=dual,
    )
    after = _snapshot(
        [
            {
                "seq": 15,
                "committed_at": "2026-06-15T12:01:00.000Z",
                "hostname": "edgenode-0",
                "source": "db_audit",
            }
        ],
        tpcc={"orders": 900, "order_line": 0, "new_order": 0, "history": 0},
        storage=dual,
    )

    issues = compare_cross_disk_coherence(before, after)
    assert issues
    assert "OS-disk-only" in issues[0]


def test_compare_cross_disk_detects_tpcc_only_recovery() -> None:
    dual = {"dual_disk": True, "audit_tablespace": "ramendr_os"}
    before = _snapshot(
        [
            {
                "seq": 10,
                "committed_at": "2026-06-15T12:00:10.000Z",
                "hostname": "edgenode-0",
                "source": "db_audit",
            }
        ],
        tpcc={"orders": 900, "order_line": 0, "new_order": 0, "history": 0},
        storage=dual,
    )
    after = _snapshot(
        [
            {
                "seq": 10,
                "committed_at": "2026-06-15T12:00:10.000Z",
                "hostname": "edgenode-0",
                "source": "db_audit",
            }
        ],
        tpcc={"orders": 950, "order_line": 5, "new_order": 0, "history": 2},
        storage=dual,
    )

    issues = compare_cross_disk_coherence(before, after)
    assert issues
    assert "data-disk-only" in issues[0]


def test_validate_cross_disk_coherence_against_baseline(tmp_path: Path) -> None:
    dual = {"dual_disk": True, "audit_tablespace": "ramendr_os"}
    before_records = [
        {
            "seq": i,
            "committed_at": f"2026-06-15T12:00:{i:02d}.000Z",
            "hostname": "edgenode-0",
            "source": "db_audit",
        }
        for i in range(1, 4)
    ]
    after_records = before_records + [
        {
            "seq": 4,
            "committed_at": "2026-06-15T12:00:40.000Z",
            "hostname": "edgenode-0",
            "source": "db_audit",
        }
    ]
    tpcc_before = {
        "customer": 3000,
        "orders": 900,
        "warehouse": 1,
        "district": 10,
        "stock": 100_000,
        "item": 100_000,
        "order_line": 0,
        "new_order": 0,
        "history": 0,
    }
    tpcc_after = {**tpcc_before, "orders": 905, "history": 2}
    before = tmp_path / "before.json"
    after = tmp_path / "after.json"
    _write_snapshot(before, _snapshot(before_records, tpcc=tpcc_before, storage=dual))
    _write_snapshot(after, _snapshot(after_records, tpcc=tpcc_after, storage=dual))

    payload = validate_snapshot_file(
        after,
        before_path=before,
        interval=10.0,
    )
    assert payload["ok"] is True
    assert payload["cross_disk_inconsistencies"] == []
