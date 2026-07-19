#!/usr/bin/env python3
"""Export PostgreSQL DR validation snapshots as JSON."""

from __future__ import annotations

import os

from psycopg2 import sql

from ramendr_dr_validation.backends.postgres import PostgresBackend
from ramendr_dr_validation.db_audit import load_env_file, validate_table_name
from ramendr_dr_validation.db_snapshot_common import (
    audit_tail_limit,
    build_snapshot_payload,
    format_committed_at,
    run_snapshot_cli,
)
from ramendr_dr_validation.tpcc_counts import (
    fetch_tpcc_counts_postgres_dr,
    fetch_tpcc_counts_postgres_status,
)


def fetch_audit_records(conn, backend: PostgresBackend) -> list[dict]:
    """Return audit rows for DR snapshots (tail window, not full history)."""
    return fetch_audit_records_tail(conn, backend, audit_tail_limit())


def fetch_audit_records_tail(conn, backend: PostgresBackend, limit: int) -> list[dict]:
    """Return the most recent ``limit`` audit rows ordered by sequence."""
    if limit <= 0:
        return fetch_audit_records_all(conn, backend)

    audit_table = validate_table_name(backend.audit_table)
    with conn.cursor() as cur:
        cur.execute(
            sql.SQL(
                """
            SELECT seq, committed_at, hostname, source
            FROM {}
            ORDER BY seq DESC
            LIMIT %s
            """
            ).format(sql.Identifier(audit_table)),
            (limit,),
        )
        rows = list(reversed(cur.fetchall()))
    return [
        {
            "seq": int(seq),
            "committed_at": format_committed_at(committed_at),
            "hostname": hostname,
            "source": source,
        }
        for seq, committed_at, hostname, source in rows
    ]


def fetch_audit_records_all(conn, backend: PostgresBackend) -> list[dict]:
    """Return all audit rows ordered by sequence."""
    audit_table = validate_table_name(backend.audit_table)
    with conn.cursor() as cur:
        cur.execute(
            sql.SQL(
                """
            SELECT seq, committed_at, hostname, source
            FROM {}
            ORDER BY seq
            """
            ).format(sql.Identifier(audit_table))
        )
        rows = cur.fetchall()
    return [
        {
            "seq": int(seq),
            "committed_at": format_committed_at(committed_at),
            "hostname": hostname,
            "source": source,
        }
        for seq, committed_at, hostname, source in rows
    ]


def fetch_audit_summary(conn, backend: PostgresBackend) -> dict:
    """Return audit row count and latest commit time without exporting full history."""
    audit_table = validate_table_name(backend.audit_table)
    with conn.cursor() as cur:
        cur.execute(
            sql.SQL(
                """
            SELECT COUNT(*), MIN(seq), MAX(seq), MAX(committed_at)
            FROM {}
            """
            ).format(sql.Identifier(audit_table))
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


def fetch_tpcc_counts(conn, backend: PostgresBackend) -> dict[str, int]:
    """Return row counts for HammerDB TPC-C tables (DR snapshot mode)."""
    return fetch_tpcc_counts_postgres_dr(conn, backend)


def fetch_tpcc_counts_status(conn, backend: PostgresBackend) -> dict[str, int]:
    """Return fast row counts for health / status snapshots."""
    return fetch_tpcc_counts_postgres_status(conn, backend)


def fetch_storage_layout(conn, backend: PostgresBackend) -> dict:
    """Report whether audit and TPC-C data span OS vs DR data disk tablespaces."""
    components: dict[str, str] = {}
    with conn.cursor() as cur:
        cur.execute(
            """
            SELECT c.relname, COALESCE(ts.spcname, 'pg_default')
            FROM pg_class c
            JOIN pg_namespace n ON n.oid = c.relnamespace
            LEFT JOIN pg_tablespace ts ON ts.oid = c.reltablespace
            WHERE n.nspname = %s
              AND c.relkind = 'r'
              AND c.relname IN (%s, %s)
            """,
            (backend.schema, backend.audit_table, "warehouse"),
        )
        for name, tablespace in cur.fetchall():
            components[str(name)] = str(tablespace)

    audit_ts = components.get(backend.audit_table, "pg_default")
    tpcc_ts = components.get("warehouse", "pg_default")
    os_tablespace = os.environ.get("DR_VALIDATION_OS_TABLESPACE", "ramendr_os")
    return {
        "dual_disk": audit_ts == os_tablespace and tpcc_ts == "pg_default",
        "audit_tablespace": audit_ts,
        "tpcc_tablespace": tpcc_ts,
        "data_disk_mount": os.environ.get("DR_VALIDATION_DATA_DISK_MOUNT"),
        "pgdata": os.environ.get("DR_VALIDATION_PGDATA"),
    }


def collect_snapshot(
    backend: PostgresBackend,
    *,
    vm_name: str | None = None,
) -> dict:
    """Build a JSON-serializable snapshot of audit + TPC-C state."""
    conn = backend.connect()
    try:
        summary = fetch_audit_summary(conn, backend)
        audit_records = fetch_audit_records(conn, backend)
        tpcc_counts = fetch_tpcc_counts(conn, backend)
        storage = fetch_storage_layout(conn, backend)
    finally:
        conn.close()

    payload = build_snapshot_payload(
        database_backend="postgres",
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
    """CLI entrypoint: print a snapshot JSON document to stdout."""
    return run_snapshot_cli(
        argv,
        description="Export DR validation DB snapshot JSON.",
        default_env_file="/etc/ramendr-dr-validation/db.env",
        database_backend="postgres",
        load_env_file=load_env_file,
        backend_factory=PostgresBackend.from_env,
        fetch_audit_records=fetch_audit_records,
        fetch_audit_summary=fetch_audit_summary,
        fetch_tpcc_counts=fetch_tpcc_counts,
        fetch_tpcc_counts_status=fetch_tpcc_counts_status,
        fetch_storage_layout=fetch_storage_layout,
    )


if __name__ == "__main__":
    raise SystemExit(main())
