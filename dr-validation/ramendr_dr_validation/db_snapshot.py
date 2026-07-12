#!/usr/bin/env python3
"""Export PostgreSQL DR validation snapshots as JSON."""

from __future__ import annotations

import os

from psycopg2 import sql

from ramendr_dr_validation.backends.postgres import PostgresBackend
from ramendr_dr_validation.db_audit import load_env_file, validate_table_name
from ramendr_dr_validation.db_snapshot_common import (
    build_snapshot_payload,
    format_committed_at,
    run_snapshot_cli,
)


def fetch_audit_records(conn, backend: PostgresBackend) -> list[dict]:
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
            if not bool(cur.fetchone()[0]):
                continue
            cur.execute(
                sql.SQL("SELECT COUNT(*) FROM {}.{}").format(
                    sql.Identifier(backend.schema),
                    sql.Identifier(table),
                )
            )
            counts[table] = int(cur.fetchone()[0])
    return counts


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
              AND c.relname IN ('dr_validation_audit', 'warehouse')
            """,
            (backend.schema,),
        )
        for name, tablespace in cur.fetchall():
            components[str(name)] = str(tablespace)

    audit_ts = components.get(backend.audit_table, "pg_default")
    tpcc_ts = components.get("warehouse", "pg_default")
    return {
        "dual_disk": audit_ts == "ramendr_os" and tpcc_ts == "pg_default",
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
        audit_records = fetch_audit_records(conn, backend)
        tpcc_counts = fetch_tpcc_counts(conn, backend)
        storage = fetch_storage_layout(conn, backend)
    finally:
        conn.close()

    return build_snapshot_payload(
        database_backend="postgres",
        database=backend.database,
        audit_records=audit_records,
        tpcc_counts=tpcc_counts,
        vm_name=vm_name,
        storage=storage,
    )


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
        fetch_tpcc_counts=fetch_tpcc_counts,
        fetch_storage_layout=fetch_storage_layout,
    )


if __name__ == "__main__":
    raise SystemExit(main())
