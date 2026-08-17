#!/usr/bin/env python3
"""Export SQL Server DR validation snapshots as JSON."""

from __future__ import annotations

import os
import re

from ramendr_dr_validation.backends.mssql import MssqlBackend
from ramendr_dr_validation.db_audit_mssql import load_env_file
from ramendr_dr_validation.db_snapshot_common import (
    audit_tail_limit,
    build_snapshot_payload,
    format_committed_at,
    run_snapshot_cli,
)
from ramendr_dr_validation.tpcc_counts import (
    fetch_tpcc_counts_mssql_dr,
    fetch_tpcc_counts_mssql_status,
)

_VALID_MSSQL_IDENTIFIER = re.compile(r"^[a-z_][a-z0-9_]*$")


def _validate_mssql_identifier(name: str, kind: str) -> str:
    """Return ``name`` when it is a safe MSSQL identifier, else raise ``ValueError``."""
    if not _VALID_MSSQL_IDENTIFIER.match(name):
        raise ValueError(f"Invalid MSSQL {kind}: {name!r}")
    return name


def _qualified_table(schema: str, table: str) -> str:
    """Build a bracket-quoted ``[schema].[table]`` reference for dynamic SQL."""
    schema = _validate_mssql_identifier(schema, "schema")
    table = _validate_mssql_identifier(table, "table")
    return f"[{schema}].[{table}]"


def fetch_audit_records(conn, backend: MssqlBackend) -> list[dict]:
    """Return audit rows for DR snapshots (tail window, not full history)."""
    return fetch_audit_records_tail(conn, backend, audit_tail_limit())


def fetch_audit_records_tail(conn, backend: MssqlBackend, limit: int) -> list[dict]:
    """Return the most recent ``limit`` audit rows ordered by sequence."""
    audit_table = _qualified_table(backend.schema, backend.audit_table)
    if limit <= 0:
        return fetch_audit_records_all(conn, backend)

    with conn.cursor() as cur:
        cur.execute(
            f"""
            SELECT seq, committed_at, hostname, source
            FROM (
                SELECT TOP (%s) seq, committed_at, hostname, source
                FROM {audit_table}
                ORDER BY seq DESC
            ) recent
            ORDER BY seq
            """,
            (limit,),
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


def fetch_audit_records_all(conn, backend: MssqlBackend) -> list[dict]:
    """Return all audit rows for ``backend.audit_table`` ordered by sequence."""
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


def fetch_audit_summary(conn, backend: MssqlBackend) -> dict:
    """Return audit row count and latest commit time without exporting full history."""
    audit_table = _qualified_table(backend.schema, backend.audit_table)
    with conn.cursor() as cur:
        cur.execute(
            f"""
            SELECT COUNT(*), MIN(seq), MAX(seq), MAX(committed_at)
            FROM {audit_table}
            """
        )
        count, first_seq, last_seq, last_committed_at = cur.fetchone()
    return {
        "record_count": int(count),
        "first_seq": int(first_seq) if first_seq is not None else None,
        "last_seq": int(last_seq) if last_seq is not None else None,
        "last_committed_at": (
            format_committed_at(last_committed_at) if last_committed_at else None
        ),
    }


def fetch_tpcc_counts(conn, backend: MssqlBackend) -> dict[str, int]:
    """Return row counts for HammerDB TPC-C tables (DR snapshot mode)."""
    return fetch_tpcc_counts_mssql_dr(conn, backend)


def fetch_tpcc_counts_status(conn, backend: MssqlBackend) -> dict[str, int]:
    """Return fast row counts for health / status snapshots."""
    return fetch_tpcc_counts_mssql_status(conn, backend)


def fetch_storage_layout(conn, backend: MssqlBackend) -> dict:
    """Report whether audit and TPC-C data span OS vs DR data disk filegroups."""
    components: dict[str, str] = {}
    with conn.cursor() as cur:
        cur.execute(
            """
            SELECT t.name, fg.name
            FROM sys.tables t
            INNER JOIN sys.schemas s ON s.schema_id = t.schema_id
            INNER JOIN sys.indexes i ON t.object_id = i.object_id AND i.index_id IN (0, 1)
            INNER JOIN sys.filegroups fg ON i.data_space_id = fg.data_space_id
            WHERE s.name = %s AND t.name IN (%s, %s)
            """,
            (backend.schema, backend.audit_table, "warehouse"),
        )
        for name, filegroup in cur.fetchall():
            components[str(name)] = str(filegroup)

    audit_fg = components.get(backend.audit_table, "PRIMARY")
    tpcc_fg = components.get("warehouse", "PRIMARY")
    data_root = os.environ.get("DR_VALIDATION_MSSQL_DATA_ROOT", "")
    os_filegroup = os.environ.get("DR_VALIDATION_OS_FILEGROUP", "ramendr_os")
    return {
        "dual_disk": audit_fg == os_filegroup and tpcc_fg == "PRIMARY",
        "audit_filegroup": audit_fg,
        "tpcc_filegroup": tpcc_fg,
        "data_disk_drive": os.environ.get("DR_VALIDATION_DATA_DISK_DRIVE"),
        "mssql_data_root": data_root or None,
    }


def collect_snapshot(
    backend: MssqlBackend,
    *,
    vm_name: str | None = None,
) -> dict:
    """Build a JSON-serializable snapshot of audit + TPC-C state on SQL Server."""
    conn = backend.connect()
    try:
        summary = fetch_audit_summary(conn, backend)
        audit_records = fetch_audit_records(conn, backend)
        tpcc_counts = fetch_tpcc_counts(conn, backend)
        storage = fetch_storage_layout(conn, backend)
    finally:
        conn.close()

    payload = build_snapshot_payload(
        database_backend="mssql",
        database=backend.database,
        audit_records=audit_records,
        tpcc_counts=tpcc_counts,
        vm_name=vm_name,
        storage=storage,
        snapshot_mode="dr",
    )
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
    return payload


def main(argv: list[str] | None = None) -> int:
    """CLI entrypoint: print a SQL Server snapshot JSON document to stdout."""
    return run_snapshot_cli(
        argv,
        description="Export DR validation SQL Server snapshot JSON.",
        default_env_file=r"C:\ProgramData\ramendr-dr-validation\db.env",
        database_backend="mssql",
        load_env_file=load_env_file,
        backend_factory=MssqlBackend.from_env,
        fetch_audit_records=fetch_audit_records,
        fetch_audit_summary=fetch_audit_summary,
        fetch_tpcc_counts=fetch_tpcc_counts,
        fetch_tpcc_counts_status=fetch_tpcc_counts_status,
        fetch_storage_layout=fetch_storage_layout,
    )


if __name__ == "__main__":
    raise SystemExit(main())
