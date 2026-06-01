"""Unit tests for DR timestamp log validation."""

from __future__ import annotations

from datetime import datetime, timezone
from pathlib import Path


from ramendr_dr_validation.records import TimestampRecord, format_record, parse_line
from ramendr_dr_validation.validator import compare_logs, load_records, validate_records


def test_parse_line_roundtrip() -> None:
    line = format_record(
        1,
        "host-a",
        99,
        when=datetime(2026, 5, 17, 12, 0, 0, 123000, tzinfo=timezone.utc),
    )
    rec = parse_line(line, 1)
    assert rec.seq == 1
    assert rec.hostname == "host-a"
    assert rec.pid == 99


def test_validate_continuous_log(tmp_path: Path) -> None:
    log = tmp_path / "timestamps.log"
    lines = [format_record(i, "vm-0", 1) for i in range(1, 11)]
    log.write_text("".join(lines), encoding="utf-8")
    records, errors = load_records(log)
    assert not errors
    report = validate_records(records, str(log))
    assert report.ok
    assert report.record_count == 10
    assert report.last_seq == 10


def test_validate_detects_timestamp_regression(tmp_path: Path) -> None:
    log = tmp_path / "timestamps.log"
    log.write_text(
        format_record(
            1, "vm-0", 1, when=datetime(2026, 1, 1, 12, 0, 0, tzinfo=timezone.utc)
        )
        + format_record(
            2, "vm-0", 1, when=datetime(2026, 1, 1, 11, 0, 0, tzinfo=timezone.utc)
        ),
        encoding="utf-8",
    )
    records, _ = load_records(log)
    report = validate_records(records, str(log))
    assert not report.ok
    assert report.timestamp_regressions


def test_validate_detects_gap(tmp_path: Path) -> None:
    log = tmp_path / "timestamps.log"
    log.write_text(
        format_record(1, "vm-0", 1)
        + format_record(2, "vm-0", 1)
        + format_record(5, "vm-0", 1),
        encoding="utf-8",
    )
    records, _ = load_records(log)
    report = validate_records(records, str(log))
    assert not report.ok
    assert len(report.seq_gaps) == 1
    assert report.seq_gaps[0].expected == 3
    assert report.seq_gaps[0].actual == 5


def test_compare_before_after() -> None:
    before = [
        TimestampRecord(1, datetime(2026, 1, 1, tzinfo=timezone.utc), "h", 1, 1),
        TimestampRecord(2, datetime(2026, 1, 1, tzinfo=timezone.utc), "h", 1, 2),
    ]
    after = [
        TimestampRecord(1, datetime(2026, 1, 1, tzinfo=timezone.utc), "h", 1, 1),
        TimestampRecord(2, datetime(2026, 1, 1, tzinfo=timezone.utc), "h", 1, 2),
        TimestampRecord(3, datetime(2026, 1, 1, tzinfo=timezone.utc), "h", 1, 3),
    ]
    result = compare_logs(before, after)
    assert result["continues_from_before"] is True
    assert result["missing_count"] == 0


def test_compare_detects_missing() -> None:
    before = [
        TimestampRecord(i, datetime(2026, 1, 1, tzinfo=timezone.utc), "h", 1, i)
        for i in range(1, 6)
    ]
    after = [
        TimestampRecord(6, datetime(2026, 1, 1, tzinfo=timezone.utc), "h", 1, 1),
    ]
    result = compare_logs(before, after)
    assert result["continues_from_before"] is False
    assert result["missing_count"] == 5
