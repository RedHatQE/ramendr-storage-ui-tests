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
) -> dict:
    """Assemble the JSON snapshot document shared by all database backends."""
    return {
        "collected_at_utc": utc_now_iso(),
        "vm_name": vm_name or socket.gethostname(),
        "database_backend": database_backend,
        "database": database,
        "audit": {
            "record_count": len(audit_records),
            "first_seq": audit_records[0]["seq"] if audit_records else None,
            "last_seq": audit_records[-1]["seq"] if audit_records else None,
            "records": audit_records,
        },
        "tpcc": tpcc_counts,
    }


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
    parser.add_argument("-o", "--output", type=Path)
    args = parser.parse_args(argv)
    load_env_file(Path(args.env_file))
    backend = backend_factory()
    conn = backend.connect()
    try:
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
    )
    return emit_snapshot_payload(payload, args.output)
