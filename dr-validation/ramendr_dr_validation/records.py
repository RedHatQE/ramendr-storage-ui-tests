"""Shared log record format for DR timestamp validation."""

from __future__ import annotations

import csv
from dataclasses import dataclass
from datetime import datetime, timezone
from io import StringIO


@dataclass(frozen=True)
class TimestampRecord:
    seq: int
    timestamp: datetime
    hostname: str
    pid: int
    line_no: int


def parse_timestamp(value: str) -> datetime:
    if value.endswith("Z"):
        value = value[:-1] + "+00:00"
    return datetime.fromisoformat(value)


def parse_line(line: str, line_no: int) -> TimestampRecord:
    line = line.strip()
    if not line or line.startswith("#"):
        raise ValueError(f"line {line_no}: empty or comment")
    reader = csv.reader(StringIO(line))
    row = next(reader)
    if len(row) != 4:
        raise ValueError(f"line {line_no}: expected 4 CSV fields, got {len(row)}")
    seq_s, ts_s, host, pid_s = row
    try:
        seq = int(seq_s)
        pid = int(pid_s)
    except ValueError as exc:
        raise ValueError(f"line {line_no}: invalid seq or pid") from exc
    try:
        ts = parse_timestamp(ts_s)
    except ValueError as exc:
        raise ValueError(f"line {line_no}: invalid timestamp {ts_s!r}") from exc
    if ts.tzinfo is None:
        ts = ts.replace(tzinfo=timezone.utc)
    return TimestampRecord(seq=seq, timestamp=ts, hostname=host, pid=pid, line_no=line_no)


def format_record(seq: int, hostname: str, pid: int, when: datetime | None = None) -> str:
    when = when or datetime.now(timezone.utc)
    ts = when.strftime("%Y-%m-%dT%H:%M:%S.%f")[:-3] + "Z"
    buf = StringIO()
    csv.writer(buf, lineterminator="").writerow([seq, ts, hostname, pid])
    return buf.getvalue() + "\n"
