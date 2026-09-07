"""TPC-C schema-ready thresholds used by install-on-vm.sh and status checks."""

from ramendr_dr_validation.tpcc_schema import (
    TPCC_MIN_ROW_COUNTS,
    validate_tpcc_populated,
)


def test_validate_tpcc_populated_accepts_one_warehouse_buildschema() -> None:
    counts = {table: minimum for table, minimum in TPCC_MIN_ROW_COUNTS.items()}
    assert validate_tpcc_populated(counts) == []


def test_validate_tpcc_populated_rejects_warehouse_loaded_before_customer() -> None:
    # HammerDB creates tables, then loads item/stock/warehouse, then customer.
    # A warehouse row with an empty customer table is not a finished schema.
    errors = validate_tpcc_populated(
        {
            "warehouse": 1,
            "district": 10,
            "customer": 0,
            "stock": 100_000,
            "item": 100_000,
            "orders": 0,
            "order_line": 0,
            "new_order": 0,
            "history": 0,
        }
    )
    assert any(err.startswith("customer:") for err in errors)
