#!/usr/bin/env python3
"""Validate PostgreSQL audit snapshots after RamenDR failover or relocate."""

from __future__ import annotations

import argparse
import json
from dataclasses import asdict, dataclass, field
from datetime import datetime, timezone
from pathlib import Path

from ramendr_dr_validation.records import TimestampRecord, parse_timestamp
from ramendr_dr_validation.tpcc_schema import validate_tpcc_populated
from ramendr_dr_validation.validator import SeqGap, compare_logs


@dataclass(frozen=True)
class AuditRecord:
    """One row from dr_validation_audit exported in a snapshot."""

    seq: int
    timestamp: datetime
    hostname: str
    source: str
    line_no: int


@dataclass
class DbValidationReport:
    """Structured result of validating a database snapshot."""

    snapshot_path: str
    vm_name: str
    record_count: int
    first_seq: int | None
    last_seq: int | None
    seq_gaps: list[SeqGap] = field(default_factory=list)
    duplicate_seqs: list[int] = field(default_factory=list)
    parse_errors: list[str] = field(default_factory=list)
    timestamp_regressions: list[str] = field(default_factory=list)
    tpcc_counts: dict[str, int] = field(default_factory=dict)
    tpcc_regressions: list[str] = field(default_factory=list)
    cross_disk_inconsistencies: list[str] = field(default_factory=list)

    @property
    def ok(self) -> bool:
        """True when audit continuity and TPC-C counts show no regressions."""
        return (
            not self.seq_gaps
            and not self.duplicate_seqs
            and not self.parse_errors
            and not self.timestamp_regressions
            and not self.tpcc_regressions
            and not self.cross_disk_inconsistencies
        )

    def max_seq_gap(self) -> int:
        """Return the largest missing run length between consecutive audit sequences."""
        if not self.seq_gaps:
            return 0
        return max(g.actual - g.expected for g in self.seq_gaps)


def audit_records_from_snapshot(snapshot: dict) -> tuple[list[AuditRecord], list[str]]:
    """Parse audit records from a snapshot JSON document."""
    records: list[AuditRecord] = []
    errors: list[str] = []
    audit = snapshot.get("audit") or {}
    raw_records = audit.get("records") or []
    for line_no, item in enumerate(raw_records, start=1):
        try:
            seq = int(item["seq"])
            ts = parse_timestamp(str(item["committed_at"]))
            hostname = str(item.get("hostname", ""))
            source = str(item.get("source", "db_audit"))
        except (KeyError, TypeError, ValueError) as exc:
            errors.append(f"audit record {line_no}: {exc}")
            continue
        records.append(
            AuditRecord(
                seq=seq,
                timestamp=ts,
                hostname=hostname,
                source=source,
                line_no=line_no,
            )
        )
    return records, errors


def validate_audit_records(records: list[AuditRecord]) -> DbValidationReport:
    """Check audit sequence continuity and timestamp ordering."""
    report = DbValidationReport(
        snapshot_path="",
        vm_name="",
        record_count=len(records),
        first_seq=records[0].seq if records else None,
        last_seq=records[-1].seq if records else None,
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


_TPCC_MUTABLE_COUNTERS = ("orders", "order_line", "new_order", "history")


def _last_audit_seq(snapshot: dict) -> int | None:
    audit = snapshot.get("audit") or {}
    last_seq = audit.get("last_seq")
    if last_seq is not None:
        try:
            return int(last_seq)
        except (TypeError, ValueError):
            pass
    records = audit.get("records") or []
    if not records:
        return None
    try:
        return int(records[-1]["seq"])
    except (KeyError, TypeError, ValueError):
        return None


def _last_audit_timestamp(snapshot: dict) -> datetime | None:
    records = (snapshot.get("audit") or {}).get("records") or []
    if not records:
        return None
    try:
        return parse_timestamp(str(records[-1]["committed_at"]))
    except (KeyError, TypeError, ValueError):
        return None


def compare_cross_disk_coherence(before: dict, after: dict) -> list[str]:
    """Detect split-brain DR where only one disk's data appears to have survived.

    For dual-disk HammerDB (TPC-C on the data disk, audit on the OS disk), both sides
    should advance together under normal load. A large delta on one side with no
    movement on the other suggests partial protection or recovery.
    """
    after_storage = after.get("storage") or {}
    before_storage = before.get("storage") or {}
    before_dual = bool(before_storage.get("dual_disk"))
    after_dual = bool(after_storage.get("dual_disk"))
    if not before_dual and not after_dual:
        return []

    inconsistencies: list[str] = []
    if before_dual and not after_dual:
        inconsistencies.append(
            "cross-disk: baseline snapshot had dual_disk=True but after snapshot "
            "omits or clears dual_disk metadata"
        )
        return inconsistencies

    before_seq = _last_audit_seq(before)
    after_seq = _last_audit_seq(after)
    if before_seq is None or after_seq is None:
        return []

    audit_delta = after_seq - before_seq
    before_tpcc = dict(before.get("tpcc") or {})
    after_tpcc = dict(after.get("tpcc") or {})
    tpcc_deltas = {
        table: int(after_tpcc.get(table, 0)) - int(before_tpcc.get(table, 0))
        for table in _TPCC_MUTABLE_COUNTERS
    }
    tpcc_advanced = any(delta > 0 for delta in tpcc_deltas.values())

    if audit_delta > 0 and not tpcc_advanced:
        inconsistencies.append(
            "cross-disk: audit seq advanced "
            f"({before_seq} -> {after_seq}) but TPC-C transactional counters "
            f"({', '.join(_TPCC_MUTABLE_COUNTERS)}) did not increase "
            "(possible OS-disk-only recovery)"
        )
    if tpcc_advanced and audit_delta <= 0:
        advanced = ", ".join(
            f"{table}+{tpcc_deltas[table]}"
            for table in _TPCC_MUTABLE_COUNTERS
            if tpcc_deltas[table] > 0
        )
        inconsistencies.append(
            "cross-disk: TPC-C counters advanced "
            f"({advanced}) but audit seq did not increase "
            f"({before_seq} -> {after_seq}) "
            "(possible data-disk-only recovery)"
        )

    before_ts = _last_audit_timestamp(before)
    after_ts = _last_audit_timestamp(after)
    if (
        before_ts is not None
        and after_ts is not None
        and audit_delta >= 0
        and after_ts < before_ts
    ):
        inconsistencies.append(
            "cross-disk: last audit committed_at regressed "
            f"({before_ts.isoformat()} -> {after_ts.isoformat()}) "
            "while audit seq did not decrease"
        )
    return inconsistencies


def compare_tpcc_counts(before: dict[str, int], after: dict[str, int]) -> list[str]:
    """Return human-readable errors when any TPC-C table row count decreases."""
    regressions: list[str] = []
    for table, before_count in sorted(before.items()):
        after_count = after.get(table)
        if after_count is None:
            regressions.append(f"{table}: missing after DR (had {before_count} rows)")
            continue
        if after_count < before_count:
            regressions.append(
                f"{table}: row count decreased {before_count} -> {after_count}"
            )
    return regressions


def audit_to_timestamp_records(records: list[AuditRecord]) -> list[TimestampRecord]:
    """Adapt audit rows to the shared timestamp comparison helpers."""
    return [
        TimestampRecord(
            seq=r.seq,
            timestamp=r.timestamp,
            hostname=r.hostname,
            pid=0,
            line_no=r.line_no,
        )
        for r in records
    ]


def rpo_from_cutoff_seconds(
    records: list[AuditRecord], cutoff_raw: str
) -> float | None:
    """Compute RPO as seconds between last pre-cutoff audit row and DR initiation."""
    if not cutoff_raw or not records:
        return None
    try:
        cutoff_s = (
            cutoff_raw if not cutoff_raw.endswith("Z") else cutoff_raw[:-1] + "+00:00"
        )
        cutoff_dt = datetime.fromisoformat(cutoff_s)
        if cutoff_dt.tzinfo is None:
            cutoff_dt = cutoff_dt.replace(tzinfo=timezone.utc)
    except (ValueError, TypeError):
        return None

    pre_cutoff = [
        r
        for r in records
        if (
            r.timestamp
            if r.timestamp.tzinfo
            else r.timestamp.replace(tzinfo=timezone.utc)
        )
        <= cutoff_dt
    ]
    if not pre_cutoff:
        return None
    last_ts = pre_cutoff[-1].timestamp
    if last_ts.tzinfo is None:
        last_ts = last_ts.replace(tzinfo=timezone.utc)
    return (cutoff_dt - last_ts).total_seconds()


def require_positive_interval(interval: float) -> None:
    """Reject non-positive intervals used for RPO upper-bound math."""
    if interval <= 0:
        raise ValueError(f"interval must be positive, got {interval}")


def validate_snapshot_file(
    after_path: Path,
    *,
    before_path: Path | None = None,
    interval: float,
    cutoff_utc: str = "",
) -> dict:
    """Validate one after snapshot, optionally comparing to a baseline snapshot."""
    require_positive_interval(interval)
    snapshot = json.loads(after_path.read_text(encoding="utf-8"))
    records, parse_errors = audit_records_from_snapshot(snapshot)
    report = validate_audit_records(records)
    report.snapshot_path = str(after_path)
    report.vm_name = str(snapshot.get("vm_name", after_path.stem))
    report.parse_errors = parse_errors
    report.tpcc_counts = dict(snapshot.get("tpcc") or {})

    comparison = None
    missing_count = 0
    report.tpcc_regressions = []
    baseline_missing = False
    if before_path is not None:
        if not before_path.is_file():
            baseline_missing = True
            report.parse_errors.append(f"Baseline snapshot not found: {before_path}")
        else:
            before_snapshot = json.loads(before_path.read_text(encoding="utf-8"))
            before_records, before_errors = audit_records_from_snapshot(before_snapshot)
            report.parse_errors.extend(before_errors)
            comparison = compare_logs(
                audit_to_timestamp_records(before_records),
                audit_to_timestamp_records(records),
            )
            missing_count = int(comparison.get("missing_count", 0))
            report.tpcc_regressions = compare_tpcc_counts(
                dict(before_snapshot.get("tpcc") or {}),
                report.tpcc_counts,
            )
            report.cross_disk_inconsistencies = compare_cross_disk_coherence(
                before_snapshot,
                snapshot,
            )
    report.tpcc_regressions.extend(validate_tpcc_populated(report.tpcc_counts))

    max_gap = report.max_seq_gap()
    estimated_rpo = max_gap * interval if max_gap > 0 else 0.0
    cutoff_rpo = rpo_from_cutoff_seconds(records, cutoff_utc)

    payload = {
        **asdict(report),
        "max_seq_gap": max_gap,
        "estimated_rpo_seconds_upper_bound": estimated_rpo,
        "rpo_from_cutoff_seconds": cutoff_rpo,
        "comparison": comparison,
        "missing_count": missing_count,
        "ok": report.ok and missing_count == 0 and not baseline_missing,
    }
    return payload


def main(argv: list[str] | None = None) -> int:
    """CLI entrypoint for validating exported DB snapshot JSON."""
    parser = argparse.ArgumentParser(
        description="Validate a DR database snapshot JSON file."
    )
    parser.add_argument("after_snapshot", type=Path)
    parser.add_argument(
        "--compare", type=Path, help="Baseline snapshot captured before DR"
    )
    parser.add_argument(
        "--interval",
        type=float,
        default=float(__import__("os").environ.get("DR_VALIDATION_INTERVAL", "10.0")),
    )
    parser.add_argument(
        "--cutoff-utc",
        default="",
        help="DR initiation timestamp (ISO-8601) for cutoff-based RPO",
    )
    parser.add_argument(
        "-o", "--output", type=Path, help="Write validation JSON report"
    )
    args = parser.parse_args(argv)

    try:
        require_positive_interval(args.interval)
    except ValueError as exc:
        print(exc, file=__import__("sys").stderr)
        return 2

    payload = validate_snapshot_file(
        args.after_snapshot,
        before_path=args.compare,
        interval=args.interval,
        cutoff_utc=args.cutoff_utc,
    )
    text = json.dumps(payload, indent=2)
    if args.output:
        args.output.write_text(text + "\n", encoding="utf-8")
    else:
        print(text)
    return 0 if payload.get("ok") else 1


if __name__ == "__main__":
    raise SystemExit(main())
