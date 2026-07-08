#!/usr/bin/env python3
"""Export SQL Server DR validation snapshots as JSON."""

from __future__ import annotations

import re

from ramendr_dr_validation.backends.mssql import MssqlBackend
from ramendr_dr_validation.db_audit_mssql import load_env_file
from ramendr_dr_validation.db_snapshot_common import (
    build_snapshot_payload,
    format_committed_at,
    run_snapshot_cli,
)


_VALID_MSSQL_IDENTIFIER = re.compile(r"^[a-z_][a-z0-9_]*$")


def _validate_mssql_identifier(name: str, kind: str) -> str:
    if not _VALID_MSSQL_IDENTIFIER.match(name):
        raise ValueError(f"Invalid MSSQL {kind}: {name!r}")
    return name


def _qualified_table(schema: str, table: str) -> str:
    schema = _validate_mssql_identifier(schema, "schema")
    table = _validate_mssql_identifier(table, "table")
    return f"[{schema}].[{table}]"


def fetch_audit_records(conn, backend: MssqlBackend) -> list[dict]:
    audit_table = _qualified_table(backend.schema, backend.audit_table)
    with conn.cursor() as cur:
        cur.execute(
            f"""
            SELECT seq, committed_at, hostname, source
            FROM {audit_table}
            ORDER BY seq
            """
        )
        rows = cur.fetchall()
    return [
        {
            "seq": int(seq),
            "committed_at": format_committed_at(committed_at),
            "hostname": str(hostname),
            "source": str(source),
        }
        for seq, committed_at, hostname, source in rows
    ]


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
            cur.execute(
                f"SELECT COUNT(*) FROM {_qualified_table(backend.schema, table)}"
            )
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

    return build_snapshot_payload(
        database_backend="mssql",
        database=backend.database,
        audit_records=audit_records,
        tpcc_counts=tpcc_counts,
        vm_name=vm_name,
    )


def main(argv: list[str] | None = None) -> int:
    return run_snapshot_cli(
        argv,
        description="Export DR validation SQL Server snapshot JSON.",
        default_env_file=r"C:\ProgramData\ramendr-dr-validation\db.env",
        database_backend="mssql",
        load_env_file=load_env_file,
        backend_factory=MssqlBackend.from_env,
        fetch_audit_records=fetch_audit_records,
        fetch_tpcc_counts=fetch_tpcc_counts,
    )


if __name__ == "__main__":
    raise SystemExit(main())
