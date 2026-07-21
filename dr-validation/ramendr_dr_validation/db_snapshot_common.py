"""Shared helpers for PostgreSQL and SQL Server DR validation snapshots."""

from __future__ import annotations

import argparse
import json
import os
import socket
import sys
from collections.abc import Callable
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Protocol


class SnapshotBackend(Protocol):
    database: str
    tpcc_tables: tuple[str, ...]

    def connect(self): ...


def utc_now_iso() -> str:
    """Return current UTC time as ISO-8601."""
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%f")[:-3] + "Z"


def audit_tail_limit() -> int:
    """Maximum audit rows exported in DR snapshots (0 = unlimited)."""
    raw = os.environ.get("DR_VALIDATION_AUDIT_TAIL_ROWS", "5000")
    try:
        return max(int(raw), 0)
    except ValueError:
        return 5000


def format_committed_at(value: Any) -> str:
    """Normalize audit timestamps to UTC ISO-8601 strings."""
    if isinstance(value, datetime):
        ts = value
        if ts.tzinfo is None:
            ts = ts.replace(tzinfo=timezone.utc)
        else:
            ts = ts.astimezone(timezone.utc)
        return ts.strftime("%Y-%m-%dT%H:%M:%S.%f")[:-3] + "Z"
    return str(value)


def build_snapshot_payload(
    *,
    database_backend: str,
    database: str,
    audit_records: list[dict],
    tpcc_counts: dict[str, int],
    vm_name: str | None = None,
    storage: dict | None = None,
    snapshot_mode: str = "dr",
) -> dict:
    """Assemble the JSON snapshot document shared by all database backends."""
    payload = {
        "collected_at_utc": utc_now_iso(),
        "vm_name": vm_name or socket.gethostname(),
        "database_backend": database_backend,
        "database": database,
        "snapshot_mode": snapshot_mode,
        "audit": {
            "record_count": len(audit_records),
            "first_seq": audit_records[0]["seq"] if audit_records else None,
            "last_seq": audit_records[-1]["seq"] if audit_records else None,
            "last_committed_at": (
                audit_records[-1]["committed_at"] if audit_records else None
            ),
            "records": audit_records,
        },
        "tpcc": tpcc_counts,
    }
    if storage is not None:
        payload["storage"] = storage
    return payload


def emit_snapshot_payload(payload: dict, output: Path | None = None) -> int:
    """Write snapshot JSON to a file or stdout."""
    serialized = json.dumps(payload, indent=2)
    if output:
        output.write_text(serialized + "\n", encoding="utf-8")
    else:
        try:
            print(serialized)
        except BrokenPipeError:
            sys.stdout.close()
    return 0


def run_snapshot_cli(
    argv: list[str] | None,
    *,
    description: str,
    default_env_file: str,
    database_backend: str,
    load_env_file: Callable[[Path], None],
    backend_factory: Callable[[], SnapshotBackend],
    fetch_audit_records: Callable[[Any, SnapshotBackend], list[dict]],
    fetch_tpcc_counts: Callable[[Any, SnapshotBackend], dict[str, int]],
    fetch_storage_layout: Callable[[Any, SnapshotBackend], dict] | None = None,
    fetch_audit_summary: Callable[[Any, SnapshotBackend], dict] | None = None,
    fetch_tpcc_counts_status: Callable[[Any, SnapshotBackend], dict[str, int]]
    | None = None,
) -> int:
    """Shared CLI entrypoint for backend-specific snapshot exporters."""
    parser = argparse.ArgumentParser(description=description)
    parser.add_argument(
        "--env-file",
        default=os.environ.get("DR_VALIDATION_DB_ENV_FILE", default_env_file),
    )
    parser.add_argument(
        "--vm-name", default=os.environ.get("DR_VALIDATION_HAMMERDB_VM", "")
    )
    parser.add_argument(
        "--status-only",
        action="store_true",
        default=os.environ.get("DR_VALIDATION_SNAPSHOT_STATUS_ONLY", "") == "1",
        help="Export audit summary + TPC-C counts only (no full audit history)",
    )
    parser.add_argument("-o", "--output", type=Path)
    args = parser.parse_args(argv)
    load_env_file(Path(args.env_file))
    backend = backend_factory()
    conn = backend.connect()
    try:
        storage = fetch_storage_layout(conn, backend) if fetch_storage_layout else None
        if args.status_only:
            if fetch_audit_summary is None:
                print(
                    "status-only snapshot not supported for this backend",
                    file=sys.stderr,
                )
                return 1
            tpcc_fetch = fetch_tpcc_counts_status or fetch_tpcc_counts
            summary = fetch_audit_summary(conn, backend)
            tpcc_counts = tpcc_fetch(conn, backend)
            payload = build_snapshot_payload(
                database_backend=database_backend,
                database=backend.database,
                audit_records=[],
                tpcc_counts=tpcc_counts,
                vm_name=args.vm_name or None,
                storage=storage,
                snapshot_mode="status-only",
            )
            payload["audit"].update(
                {
                    "record_count": summary["record_count"],
                    "first_seq": summary.get("first_seq"),
                    "last_seq": summary.get("last_seq"),
                    "last_committed_at": summary.get("last_committed_at"),
                    "records": [],
                }
            )
            return emit_snapshot_payload(payload, args.output)

        summary = fetch_audit_summary(conn, backend) if fetch_audit_summary else None
        audit_records = fetch_audit_records(conn, backend)
        tpcc_counts = fetch_tpcc_counts(conn, backend)
    finally:
        conn.close()
    payload = build_snapshot_payload(
        database_backend=database_backend,
        database=backend.database,
        audit_records=audit_records,
        tpcc_counts=tpcc_counts,
        vm_name=args.vm_name or None,
        storage=storage,
        snapshot_mode="dr",
    )
    if summary is not None:
        payload["audit"].update(
            {
                "record_count": summary["record_count"],
                "first_seq": summary.get("first_seq"),
                "last_seq": summary.get("last_seq"),
                "last_committed_at": summary.get("last_committed_at"),
                "tail_rows": len(audit_records),
                "tail_limit": audit_tail_limit(),
            }
        )
    return emit_snapshot_payload(payload, args.output)
