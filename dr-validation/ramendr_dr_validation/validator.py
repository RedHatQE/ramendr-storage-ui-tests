#!/usr/bin/env python3
"""Analyze timestamp logs for gaps after RamenDR failover."""

from __future__ import annotations

import argparse
import json
import sys
from dataclasses import asdict, dataclass, field
from datetime import datetime, timezone
from pathlib import Path

from ramendr_dr_validation.records import TimestampRecord, parse_line


@dataclass
class SeqGap:
    """One discontinuity in the monotonic sequence number stream."""

    expected: int
    actual: int
    at_line: int


@dataclass
class ValidationReport:
    """Structured result of validating a timestamp log file."""

    log_path: str
    record_count: int
    first_seq: int | None
    last_seq: int | None
    first_timestamp: str | None
    last_timestamp: str | None
    unique_hostnames: list[str]
    seq_gaps: list[SeqGap] = field(default_factory=list)
    duplicate_seqs: list[int] = field(default_factory=list)
    parse_errors: list[str] = field(default_factory=list)
    timestamp_regressions: list[str] = field(default_factory=list)

    @property
    def ok(self) -> bool:
        """True when the log has no sequence gaps, duplicates, parse errors, or timestamp regressions."""
        return (
            not self.seq_gaps
            and not self.duplicate_seqs
            and not self.parse_errors
            and not self.timestamp_regressions
        )

    def max_seq_gap(self) -> int:
        """Return the largest missing run length between consecutive sequence numbers."""
        if not self.seq_gaps:
            return 0
        return max(g.actual - g.expected for g in self.seq_gaps)

    def estimated_rpo_seconds(self) -> float | None:
        """Upper-bound RPO hint from largest sequence gap and write interval."""
        gap = self.max_seq_gap()
        if gap <= 0:
            return 0.0
        return None  # filled by CLI when interval known


def load_records(path: Path) -> tuple[list[TimestampRecord], list[str]]:
    """Load all valid records from a log file; collect per-line parse errors."""
    records: list[TimestampRecord] = []
    errors: list[str] = []
    with path.open(encoding="utf-8") as handle:
        for line_no, line in enumerate(handle, start=1):
            try:
                records.append(parse_line(line, line_no))
            except ValueError as exc:
                errors.append(str(exc))
    return records, errors


def validate_records(records: list[TimestampRecord], log_path: str) -> ValidationReport:
    """Check sequence continuity, duplicates, and timestamp ordering in parsed records."""
    report = ValidationReport(
        log_path=log_path,
        record_count=len(records),
        first_seq=records[0].seq if records else None,
        last_seq=records[-1].seq if records else None,
        first_timestamp=records[0].timestamp.isoformat() if records else None,
        last_timestamp=records[-1].timestamp.isoformat() if records else None,
        unique_hostnames=sorted({r.hostname for r in records}),
    )
    if not records:
        return report

    seen: dict[int, int] = {}
    prev_ts: datetime | None = None
    prev_seq: int | None = None

    for rec in records:
        if rec.seq in seen:
            report.duplicate_seqs.append(rec.seq)
        else:
            seen[rec.seq] = rec.line_no

        if prev_seq is not None and rec.seq != prev_seq + 1:
            report.seq_gaps.append(
                SeqGap(expected=prev_seq + 1, actual=rec.seq, at_line=rec.line_no)
            )
        prev_seq = rec.seq

        if prev_ts is not None and rec.timestamp < prev_ts:
            report.timestamp_regressions.append(
                f"line {rec.line_no}: {rec.timestamp.isoformat()} < {prev_ts.isoformat()}"
            )
        prev_ts = rec.timestamp

    report.duplicate_seqs = sorted(set(report.duplicate_seqs))
    return report


def compare_logs(
    before: list[TimestampRecord],
    after: list[TimestampRecord],
) -> dict:
    """Compare logs from before and after DR (e.g. copied pre/post failover)."""
    before_last = before[-1].seq if before else 0
    after_first = after[0].seq if after else None
    overlap = [r for r in after if r.seq <= before_last]
    missing_in_after = []
    if before and after:
        after_seqs = {r.seq for r in after}
        missing_in_after = [r.seq for r in before if r.seq not in after_seqs]
    return {
        "before_count": len(before),
        "after_count": len(after),
        "before_last_seq": before_last,
        "after_first_seq": after_first,
        "continues_from_before": after_first == before_last + 1 if after_first is not None else None,
        "overlap_records_in_after": len(overlap),
        "missing_seqs_in_after": missing_in_after[:20],
        "missing_count": len(missing_in_after),
    }


def print_report(report: ValidationReport, *, interval: float | None, verbose: bool) -> None:
    """Print a JSON validation report to stdout (and PASS/FAIL to stderr if verbose)."""
    data = asdict(report)
    if interval is not None and report.max_seq_gap() > 0:
        data["estimated_rpo_seconds_upper_bound"] = report.max_seq_gap() * interval
    print(json.dumps(data, indent=2))
    if not verbose:
        return
    if report.ok:
        print("PASS: sequence is continuous with no parse errors.", file=sys.stderr)
    else:
        print("FAIL: validation found issues.", file=sys.stderr)


def main(argv: list[str] | None = None) -> int:
    """CLI entrypoint: validate one log file, optionally compare against a pre-failover baseline."""
    parser = argparse.ArgumentParser(description="Validate a DR timestamp log for sequence gaps.")
    parser.add_argument("log_path", type=Path, help="Path to timestamps.log")
    parser.add_argument(
        "--interval",
        type=float,
        default=None,
        help="Writer interval in seconds (for estimated RPO upper bound)",
    )
    parser.add_argument("--compare", type=Path, help="Second log captured before failover")
    parser.add_argument("-v", "--verbose", action="store_true")
    args = parser.parse_args(argv)

    records, parse_errors = load_records(args.log_path)
    report = validate_records(records, str(args.log_path))
    report.parse_errors = parse_errors

    if args.compare:
        before_records, before_errors = load_records(args.compare)
        report.parse_errors.extend(before_errors)
        comparison = compare_logs(before_records, records)
        print_report(report, interval=args.interval, verbose=args.verbose)
        print(json.dumps({"comparison": comparison}, indent=2))
        if comparison.get("missing_count", 0) > 0:
            return 1
    else:
        print_report(report, interval=args.interval, verbose=args.verbose)

    return 0 if report.ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
