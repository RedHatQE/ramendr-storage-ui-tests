"""Database backends for HammerDB-based DR validation."""

__all__ = ["PostgresBackend", "MssqlBackend"]


def __getattr__(name: str):
    if name == "PostgresBackend":
        from ramendr_dr_validation.backends.postgres import PostgresBackend

        return PostgresBackend
    if name == "MssqlBackend":
        from ramendr_dr_validation.backends.mssql import MssqlBackend

        return MssqlBackend
    raise AttributeError(f"module {__name__!r} has no attribute {name!r}")
