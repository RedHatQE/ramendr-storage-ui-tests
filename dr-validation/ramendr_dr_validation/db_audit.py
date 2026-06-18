#!/usr/bin/env python3
"""Continuous audit writer for HammerDB PostgreSQL DR validation."""

from __future__ import annotations

import argparse
import os
import socket
import sys
import time
from pathlib import Path

from ramendr_dr_validation.backends.postgres import PostgresBackend


def read_last_seq(conn, table: str) -> int:
    """Return the highest audit sequence number, or 0 when the table is empty."""
    with conn.cursor() as cur:
        cur.execute(f"SELECT COALESCE(MAX(seq), 0) FROM {table}")
        row = cur.fetchone()
    return int(row[0]) if row else 0


def ensure_audit_table(conn, table: str) -> None:
    """Create the audit table if bootstrap did not already."""
    with conn.cursor() as cur:
        cur.execute(
            f"""
            CREATE TABLE IF NOT EXISTS {table} (
                seq BIGINT PRIMARY KEY,
                committed_at TIMESTAMPTZ NOT NULL,
                hostname TEXT NOT NULL,
                source TEXT NOT NULL DEFAULT 'db_audit'
            )
            """
        )
    conn.commit()


def append_audit_record(
    conn,
    *,
    table: str,
    seq: int,
    hostname: str,
    source: str,
) -> None:
    """Insert one audit row and commit immediately (fsync via PostgreSQL WAL)."""
    with conn.cursor() as cur:
        cur.execute(
            f"""
            INSERT INTO {table} (seq, committed_at, hostname, source)
            VALUES (%s, NOW() AT TIME ZONE 'UTC', %s, %s)
            """,
            (seq, hostname, source),
        )
    conn.commit()


def run_audit_writer(
    backend: PostgresBackend,
    interval: float,
    *,
    max_records: int | None,
    source: str,
) -> int:
    """Insert audit rows at a fixed interval until interrupted or max_records reached."""
    hostname = socket.gethostname()
    written = 0
    conn = backend.connect()
    try:
        ensure_audit_table(conn, backend.audit_table)
        seq = read_last_seq(conn, backend.audit_table) + 1
        while max_records is None or written < max_records:
            append_audit_record(
                conn,
                table=backend.audit_table,
                seq=seq,
                hostname=hostname,
                source=source,
            )
            seq += 1
            written += 1
            if max_records is not None and written >= max_records:
                break
            time.sleep(interval)
    finally:
        conn.close()
    return written


def load_env_file(path: Path) -> None:
    """Load KEY=VALUE lines from a dotenv-style file into os.environ."""
    if not path.is_file():
        return
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        os.environ.setdefault(key.strip(), value.strip())


def main(argv: list[str] | None = None) -> int:
    """CLI entrypoint for the continuous PostgreSQL audit writer."""
    parser = argparse.ArgumentParser(
        description="Continuously append audit rows to PostgreSQL on DR-protected storage.",
    )
    parser.add_argument(
        "--env-file",
        default=os.environ.get(
            "DR_VALIDATION_DB_ENV_FILE",
            "/etc/ramendr-dr-validation/db.env",
        ),
        help="Optional KEY=VALUE file with PostgreSQL settings",
    )
    parser.add_argument(
        "--interval",
        type=float,
        default=float(os.environ.get("DR_VALIDATION_INTERVAL", "10.0")),
        help="Seconds between audit inserts (default: %(default)s)",
    )
    parser.add_argument(
        "--max-records",
        type=int,
        default=None,
        help="Exit after N records (default: run until interrupted)",
    )
    parser.add_argument(
        "--source",
        default=os.environ.get("DR_VALIDATION_AUDIT_SOURCE", "db_audit"),
        help="Value stored in the audit source column",
    )
    args = parser.parse_args(argv)
    if args.interval <= 0:
        print("interval must be positive", file=sys.stderr)
        return 2
    load_env_file(Path(args.env_file))
    backend = PostgresBackend.from_env()
    try:
        run_audit_writer(
            backend,
            args.interval,
            max_records=args.max_records,
            source=args.source,
        )
    except KeyboardInterrupt:
        return 0
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
