#!/usr/bin/env python3
"""Export PostgreSQL DR validation snapshots as JSON."""

from __future__ import annotations

import argparse
import json
import os
import socket
from datetime import datetime, timezone
from pathlib import Path

from ramendr_dr_validation.backends.postgres import PostgresBackend
from ramendr_dr_validation.db_audit import load_env_file


def utc_now_iso() -> str:
    """Return current UTC time as ISO-8601."""
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%f")[:-3] + "Z"


def fetch_audit_records(conn, backend: PostgresBackend) -> list[dict]:
    """Return all audit rows ordered by sequence."""
    with conn.cursor() as cur:
        cur.execute(
            f"""
            SELECT seq, committed_at, hostname, source
            FROM {backend.audit_table}
            ORDER BY seq
            """
        )
        rows = cur.fetchall()
    records: list[dict] = []
    for seq, committed_at, hostname, source in rows:
        ts = committed_at
        if ts.tzinfo is None:
            ts = ts.replace(tzinfo=timezone.utc)
        else:
            ts = ts.astimezone(timezone.utc)
        records.append(
            {
                "seq": int(seq),
                "committed_at": ts.strftime("%Y-%m-%dT%H:%M:%S.%f")[:-3] + "Z",
                "hostname": hostname,
                "source": source,
            }
        )
    return records


def fetch_tpcc_counts(conn, backend: PostgresBackend) -> dict[str, int]:
    """Return row counts for HammerDB TPC-C tables that exist in the schema."""
    counts: dict[str, int] = {}
    with conn.cursor() as cur:
        for table in backend.tpcc_tables:
            cur.execute(
                """
                SELECT EXISTS (
                    SELECT 1
                    FROM information_schema.tables
                    WHERE table_schema = %s AND table_name = %s
                )
                """,
                (backend.schema, table),
            )
            exists = bool(cur.fetchone()[0])
            if not exists:
                continue
            cur.execute(f'SELECT COUNT(*) FROM "{table}"')
            counts[table] = int(cur.fetchone()[0])
    return counts


def collect_snapshot(
    backend: PostgresBackend,
    *,
    vm_name: str | None = None,
) -> dict:
    """Build a JSON-serializable snapshot of audit + TPC-C state."""
    conn = backend.connect()
    try:
        audit_records = fetch_audit_records(conn, backend)
        tpcc_counts = fetch_tpcc_counts(conn, backend)
    finally:
        conn.close()

    return {
        "collected_at_utc": utc_now_iso(),
        "vm_name": vm_name or socket.gethostname(),
        "database_backend": "postgres",
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
    """CLI entrypoint: print a snapshot JSON document to stdout."""
    parser = argparse.ArgumentParser(
        description="Export DR validation DB snapshot JSON."
    )
    parser.add_argument(
        "--env-file",
        default=os.environ.get(
            "DR_VALIDATION_DB_ENV_FILE",
            "/etc/ramendr-dr-validation/db.env",
        ),
    )
    parser.add_argument(
        "--vm-name", default=os.environ.get("DR_VALIDATION_HAMMERDB_VM", "")
    )
    parser.add_argument(
        "-o", "--output", type=Path, help="Write JSON to file instead of stdout"
    )
    args = parser.parse_args(argv)
    load_env_file(Path(args.env_file))
    snapshot = collect_snapshot(
        PostgresBackend.from_env(),
        vm_name=args.vm_name or None,
    )
    payload = json.dumps(snapshot, indent=2)
    if args.output:
        args.output.write_text(payload + "\n", encoding="utf-8")
    else:
        print(payload)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
