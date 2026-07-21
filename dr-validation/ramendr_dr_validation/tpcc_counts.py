"""Fast TPC-C row-count helpers for HammerDB snapshot exporters.

HammerDB autopilot grows ``orders`` / ``order_line`` without bound. Exact
``COUNT(*)`` on those tables can take minutes after long runs. Status checks
only need the fixed buildschema tables; DR baselines use planner statistics for
mutable tables instead of full table scans.
"""

from __future__ import annotations

from typing import Any, Protocol

from ramendr_dr_validation.tpcc_schema import (
    TPCC_MIN_ROW_COUNTS,
    TPCC_MUTABLE_TABLES,
    TPCC_STATIC_TABLES,
)


class TpccCountBackend(Protocol):
    schema: str
    tpcc_tables: tuple[str, ...]


def _postgres_table_exists(cur, schema: str, table: str) -> bool:
    cur.execute(
        """
        SELECT EXISTS (
            SELECT 1
            FROM information_schema.tables
            WHERE table_schema = %s AND table_name = %s
        )
        """,
        (schema, table),
    )
    return bool(cur.fetchone()[0])


def _postgres_exact_count(cur, schema: str, table: str) -> int:
    from psycopg2 import sql

    cur.execute(
        sql.SQL("SELECT COUNT(*) FROM {}.{}").format(
            sql.Identifier(schema),
            sql.Identifier(table),
        )
    )
    return int(cur.fetchone()[0])


def _postgres_estimate_count(cur, schema: str, table: str) -> int:
    cur.execute(
        """
        SELECT COALESCE(c.reltuples::bigint, 0)
        FROM pg_class c
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname = %s
          AND c.relname = %s
          AND c.relkind = 'r'
        """,
        (schema, table),
    )
    row = cur.fetchone()
    if row is None:
        return 0
    return max(int(row[0]), 0)


def fetch_tpcc_counts_postgres_status(
    conn: Any, backend: TpccCountBackend
) -> dict[str, int]:
    """Exact counts on fixed buildschema tables only (fast health check)."""
    counts: dict[str, int] = {}
    with conn.cursor() as cur:
        for table in TPCC_STATIC_TABLES:
            if table not in backend.tpcc_tables:
                continue
            if not _postgres_table_exists(cur, backend.schema, table):
                continue
            counts[table] = _postgres_exact_count(cur, backend.schema, table)
    return counts


def fetch_tpcc_counts_postgres_dr(
    conn: Any, backend: TpccCountBackend
) -> dict[str, int]:
    """Exact counts on static tables; planner estimates on mutable OLTP tables."""
    counts = fetch_tpcc_counts_postgres_status(conn, backend)
    with conn.cursor() as cur:
        for table in TPCC_MUTABLE_TABLES:
            if table not in backend.tpcc_tables:
                continue
            if not _postgres_table_exists(cur, backend.schema, table):
                continue
            counts[table] = _postgres_estimate_count(cur, backend.schema, table)
    return counts


def _mssql_table_exists(cur, schema: str, table: str) -> bool:
    cur.execute(
        """
        SELECT COUNT(*)
        FROM INFORMATION_SCHEMA.TABLES
        WHERE TABLE_SCHEMA = %s AND TABLE_NAME = %s
        """,
        (schema, table),
    )
    return bool(int(cur.fetchone()[0]))


def _mssql_qualified(schema: str, table: str) -> str:
    return f"[{schema}].[{table}]"


def _mssql_exact_count(cur, schema: str, table: str) -> int:
    cur.execute(f"SELECT COUNT(*) FROM {_mssql_qualified(schema, table)}")
    return int(cur.fetchone()[0])


def _mssql_estimate_count(cur, schema: str, table: str) -> int:
    cur.execute(
        """
        SELECT COALESCE(SUM(p.rows), 0)
        FROM sys.tables t
        INNER JOIN sys.schemas s ON s.schema_id = t.schema_id
        INNER JOIN sys.partitions p ON t.object_id = p.object_id AND p.index_id IN (0, 1)
        WHERE s.name = %s AND t.name = %s
        """,
        (schema, table),
    )
    return max(int(cur.fetchone()[0]), 0)


def fetch_tpcc_counts_mssql_status(
    conn: Any, backend: TpccCountBackend
) -> dict[str, int]:
    """Exact counts on fixed buildschema tables only (fast health check)."""
    counts: dict[str, int] = {}
    with conn.cursor() as cur:
        for table in TPCC_STATIC_TABLES:
            if table not in backend.tpcc_tables:
                continue
            if not _mssql_table_exists(cur, backend.schema, table):
                continue
            counts[table] = _mssql_exact_count(cur, backend.schema, table)
    return counts


def fetch_tpcc_counts_mssql_dr(conn: Any, backend: TpccCountBackend) -> dict[str, int]:
    """Exact counts on static tables; partition row estimates on mutable tables."""
    counts = fetch_tpcc_counts_mssql_status(conn, backend)
    with conn.cursor() as cur:
        for table in TPCC_MUTABLE_TABLES:
            if table not in backend.tpcc_tables:
                continue
            if not _mssql_table_exists(cur, backend.schema, table):
                continue
            counts[table] = _mssql_estimate_count(cur, backend.schema, table)
    return counts


def validate_tpcc_static_only(tpcc_counts: dict[str, int]) -> list[str]:
    """Validate only tables with fixed minimum row counts (status / smoke checks)."""
    errors: list[str] = []
    for table in TPCC_STATIC_TABLES:
        minimum = TPCC_MIN_ROW_COUNTS[table]
        count = tpcc_counts.get(table)
        if count is None:
            errors.append(f"{table}: missing (expected table to exist)")
        elif count < minimum:
            errors.append(f"{table}: {count} rows (expected at least {minimum})")
    return errors
