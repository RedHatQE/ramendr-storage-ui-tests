"""Unit tests for fast HammerDB TPC-C count helpers."""

from __future__ import annotations

from ramendr_dr_validation.tpcc_counts import validate_tpcc_static_only
from ramendr_dr_validation.tpcc_schema import TPCC_STATIC_TABLES


def test_validate_tpcc_static_only_accepts_static_tables_only() -> None:
    counts = {
        "warehouse": 1,
        "district": 10,
        "customer": 3000,
        "stock": 100_000,
        "item": 100_000,
    }
    assert validate_tpcc_static_only(counts) == []


def test_validate_tpcc_static_only_rejects_missing_static_table() -> None:
    counts = {table: 1 for table in TPCC_STATIC_TABLES if table != "customer"}
    errors = validate_tpcc_static_only(counts)
    assert any("customer" in err for err in errors)


def test_validate_tpcc_static_only_ignores_mutable_tables() -> None:
    counts = {
        "warehouse": 1,
        "district": 10,
        "customer": 3000,
        "stock": 100_000,
        "item": 100_000,
    }
    assert validate_tpcc_static_only(counts) == []
