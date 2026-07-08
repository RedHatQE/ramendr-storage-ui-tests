#!/usr/bin/env python3
"""Continuous audit writer for HammerDB SQL Server DR validation."""

from __future__ import annotations

import argparse
import os
import re
import socket
import sys
import time
from pathlib import Path

from ramendr_dr_validation.backends.mssql import MssqlBackend

_VALID_TABLE_NAME = re.compile(r"^[a-z_][a-z0-9_]*$")


def validate_table_name(table: str) -> str:
    if not _VALID_TABLE_NAME.match(table):
        raise ValueError(f"Invalid audit table name: {table!r}")
    return table


def read_last_seq(conn, table: str) -> int:
    table = validate_table_name(table)
    with conn.cursor() as cur:
        cur.execute(f"SELECT COALESCE(MAX(seq), 0) FROM dbo.{table}")
        row = cur.fetchone()
    return int(row[0]) if row else 0


def ensure_audit_table(conn, table: str) -> None:
    table = validate_table_name(table)
    with conn.cursor() as cur:
        cur.execute(
            f"""
            IF OBJECT_ID(N'dbo.{table}', N'U') IS NULL
            BEGIN
                CREATE TABLE dbo.{table} (
                    seq BIGINT NOT NULL PRIMARY KEY,
                    committed_at DATETIME2 NOT NULL,
                    hostname NVARCHAR(256) NOT NULL,
                    source NVARCHAR(64) NOT NULL DEFAULT N'db_audit'
                );
            END
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
    table = validate_table_name(table)
    with conn.cursor() as cur:
        cur.execute(
            f"""
            INSERT INTO dbo.{table} (seq, committed_at, hostname, source)
            VALUES (%s, SYSUTCDATETIME(), %s, %s)
            """,
            (seq, hostname, source),
        )
    conn.commit()


def run_audit_writer(
    backend: MssqlBackend,
    interval: float,
    *,
    max_records: int | None,
    source: str,
) -> int:
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
    if not path.is_file():
        return
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        os.environ.setdefault(key.strip(), value.strip())


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Continuously append audit rows to SQL Server on DR-protected storage.",
    )
    parser.add_argument(
        "--env-file",
        default=os.environ.get(
            "DR_VALIDATION_DB_ENV_FILE",
            r"C:\ProgramData\ramendr-dr-validation\db.env",
        ),
    )
    parser.add_argument(
        "--interval",
        type=float,
        default=float(os.environ.get("DR_VALIDATION_INTERVAL", "10.0")),
    )
    parser.add_argument("--max-records", type=int, default=None)
    parser.add_argument(
        "--source",
        default=os.environ.get("DR_VALIDATION_AUDIT_SOURCE", "db_audit"),
    )
    args = parser.parse_args(argv)
    if args.interval <= 0:
        print("interval must be positive", file=sys.stderr)
        return 2
    load_env_file(Path(args.env_file))
    backend = MssqlBackend.from_env()
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
