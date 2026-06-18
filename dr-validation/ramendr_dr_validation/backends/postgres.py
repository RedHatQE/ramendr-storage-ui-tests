"""PostgreSQL backend helpers for DR validation snapshots."""

from __future__ import annotations

import os
from dataclasses import dataclass

from ramendr_dr_validation.tpcc_schema import TPCC_TABLE_NAMES


@dataclass(frozen=True)
class PostgresBackend:
    """Connection settings for the HammerDB PostgreSQL workload on an edge VM."""

    host: str = "127.0.0.1"
    port: int = 5432
    database: str = "tpcc"
    user: str = "hammerdb"
    password: str = "hammerdb"
    schema: str = "public"
    audit_table: str = "dr_validation_audit"

    @classmethod
    def from_env(cls) -> PostgresBackend:
        """Build settings from DR_VALIDATION_PG_* environment variables."""
        return cls(
            host=os.environ.get("DR_VALIDATION_PG_HOST", "127.0.0.1"),
            port=int(os.environ.get("DR_VALIDATION_PG_PORT", "5432")),
            database=os.environ.get("DR_VALIDATION_PG_DATABASE", "tpcc"),
            user=os.environ.get("DR_VALIDATION_PG_USER", "hammerdb"),
            password=os.environ.get("DR_VALIDATION_PG_PASSWORD", "hammerdb"),
            schema=os.environ.get("DR_VALIDATION_PG_SCHEMA", "public"),
            audit_table=os.environ.get(
                "DR_VALIDATION_PG_AUDIT_TABLE", "dr_validation_audit"
            ),
        )

    def connect(self):
        """Open a psycopg2 connection (lazy import keeps validators psycopg2-free)."""
        import psycopg2

        return psycopg2.connect(
            host=self.host,
            port=self.port,
            dbname=self.database,
            user=self.user,
            password=self.password,
        )

    @property
    def tpcc_tables(self) -> tuple[str, ...]:
        """HammerDB TPC-C tables used for row-count integrity checks."""
        return TPCC_TABLE_NAMES
