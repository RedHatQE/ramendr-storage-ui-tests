#!/usr/bin/env python3
"""Export SQL Server DR validation snapshots as JSON."""

from __future__ import annotations

import argparse
import json
import os
import socket
import sys
from datetime import datetime, timezone
from pathlib import Path

from ramendr_dr_validation.backends.mssql import MssqlBackend
from ramendr_dr_validation.db_audit_mssql import load_env_file


def utc_now_iso() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%f")[:-3] + "Z"


def fetch_audit_records(conn, backend: MssqlBackend) -> list[dict]:
    with conn.cursor() as cur:
        cur.execute(
            f"""
            SELECT seq, committed_at, hostname, source
            FROM dbo.{backend.audit_table}
            ORDER BY seq
            """
        )
        rows = cur.fetchall()
    records: list[dict] = []
    for seq, committed_at, hostname, source in rows:
        ts = committed_at
        if isinstance(ts, datetime):
            if ts.tzinfo is None:
                ts = ts.replace(tzinfo=timezone.utc)
            else:
                ts = ts.astimezone(timezone.utc)
            committed = ts.strftime("%Y-%m-%dT%H:%M:%S.%f")[:-3] + "Z"
        else:
            committed = str(committed_at)
        records.append(
            {
                "seq": int(seq),
                "committed_at": committed,
                "hostname": str(hostname),
                "source": str(source),
            }
        )
    return records


def fetch_tpcc_counts(conn, backend: MssqlBackend) -> dict[str, int]:
    counts: dict[str, int] = {}
    with conn.cursor() as cur:
        for table in backend.tpcc_tables:
            cur.execute(
                """
                SELECT COUNT(*)
                FROM INFORMATION_SCHEMA.TABLES
                WHERE TABLE_SCHEMA = %s AND TABLE_NAME = %s
                """,
                (backend.schema, table),
            )
            if not int(cur.fetchone()[0]):
                continue
            cur.execute(f"SELECT COUNT(*) FROM dbo.{table}")
            counts[table] = int(cur.fetchone()[0])
    return counts


def collect_snapshot(
    backend: MssqlBackend,
    *,
    vm_name: str | None = None,
) -> dict:
    conn = backend.connect()
    try:
        audit_records = fetch_audit_records(conn, backend)
        tpcc_counts = fetch_tpcc_counts(conn, backend)
    finally:
        conn.close()

    return {
        "collected_at_utc": utc_now_iso(),
        "vm_name": vm_name or socket.gethostname(),
        "database_backend": "mssql",
        "database": backend.database,
        "audit": {
            "record_count": len(audit_records),
            "first_seq": audit_records[0]["seq"] if audit_records else None,
            "last_seq": audit_records[-1]["seq"] if audit_records else None,
            "records": audit_records,
        },
        "tpcc": tpcc_counts,
    }


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Export DR validation SQL Server snapshot JSON."
    )
    parser.add_argument(
        "--env-file",
        default=os.environ.get(
            "DR_VALIDATION_DB_ENV_FILE",
            r"C:\ProgramData\ramendr-dr-validation\db.env",
        ),
    )
    parser.add_argument(
        "--vm-name", default=os.environ.get("DR_VALIDATION_HAMMERDB_VM", "")
    )
    parser.add_argument("-o", "--output", type=Path)
    args = parser.parse_args(argv)
    load_env_file(Path(args.env_file))
    snapshot = collect_snapshot(
        MssqlBackend.from_env(),
        vm_name=args.vm_name or None,
    )
    payload = json.dumps(snapshot, indent=2)
    if args.output:
        args.output.write_text(payload + "\n", encoding="utf-8")
    else:
        try:
            print(payload)
        except BrokenPipeError:
            sys.stdout.close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
