"""SQL Server backend helpers for HammerDB DR validation on Windows edge VMs."""

from __future__ import annotations

import os
from dataclasses import dataclass

from ramendr_dr_validation.tpcc_schema import TPCC_TABLE_NAMES


@dataclass(frozen=True)
class MssqlBackend:
    """Connection settings for the HammerDB SQL Server workload on a Windows VM."""

    user: str
    password: str
    host: str = "127.0.0.1"
    port: int = 1433
    database: str = "tpcc"
    instance: str = "SQLEXPRESS"
    schema: str = "dbo"
    audit_table: str = "dr_validation_audit"

    @classmethod
    def from_env(cls) -> MssqlBackend:
        """Build settings from DR_VALIDATION_MSSQL_* environment variables."""
        trusted = os.environ.get("DR_VALIDATION_MSSQL_TRUSTED", "0") == "1"
        user = os.environ.get("DR_VALIDATION_MSSQL_USER", "").strip()
        password = os.environ.get("DR_VALIDATION_MSSQL_PASSWORD", "").strip()
        if not trusted:
            if not user:
                raise ValueError("DR_VALIDATION_MSSQL_USER is required")
            if not password:
                raise ValueError("DR_VALIDATION_MSSQL_PASSWORD is required")
        return cls(
            host=os.environ.get("DR_VALIDATION_MSSQL_HOST", "127.0.0.1"),
            port=int(os.environ.get("DR_VALIDATION_MSSQL_PORT", "1433")),
            database=os.environ.get("DR_VALIDATION_MSSQL_DATABASE", "tpcc"),
            user=user,
            password=password,
            instance=os.environ.get("DR_VALIDATION_MSSQL_INSTANCE", "SQLEXPRESS"),
            schema=os.environ.get("DR_VALIDATION_MSSQL_SCHEMA", "dbo"),
            audit_table=os.environ.get(
                "DR_VALIDATION_MSSQL_AUDIT_TABLE", "dr_validation_audit"
            ),
        )

    def connect(self):
        """Open a pymssql connection (lazy import keeps validators pymssql-free)."""
        import pymssql

        server = self.host
        if self.instance:
            server = f"{self.host}\\{self.instance}"
        trusted = os.environ.get("DR_VALIDATION_MSSQL_TRUSTED", "0") == "1"
        connect_kwargs = {
            "server": server,
            "database": self.database,
        }
        if not self.instance:
            connect_kwargs["port"] = self.port
        if trusted:
            connect_kwargs["trusted"] = True
        else:
            connect_kwargs["user"] = self.user
            connect_kwargs["password"] = self.password
        return pymssql.connect(**connect_kwargs)

    @property
    def tpcc_tables(self) -> tuple[str, ...]:
        """HammerDB TPC-C tables used for row-count integrity checks."""
        return TPCC_TABLE_NAMES
