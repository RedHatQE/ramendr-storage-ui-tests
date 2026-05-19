#!/usr/bin/env python3
"""Append-only timestamp writer for DR-protected VM disks."""

from __future__ import annotations

import argparse
import os
import socket
import sys
import time
from pathlib import Path

from ramendr_dr_validation.records import format_record


def read_last_seq(log_path: Path) -> int:
    """Return the highest sequence number in an existing log, or 0 if missing or empty."""
    if not log_path.exists():
        return 0
    last_seq = 0
    with log_path.open(encoding="utf-8") as handle:
        for line in handle:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            seq_s = line.split(",", 1)[0]
            try:
                last_seq = max(last_seq, int(seq_s))
            except ValueError:
                continue
    return last_seq


def append_record(
    log_path: Path,
    seq: int,
    *,
    fsync: bool,
) -> None:
    """Append one timestamp record to the log, creating parent directories if needed."""
    log_path.parent.mkdir(parents=True, exist_ok=True)
    line = format_record(seq, socket.gethostname(), os.getpid())
    with log_path.open("a", encoding="utf-8") as handle:
        handle.write(line)
        handle.flush()
        if fsync:
            os.fsync(handle.fileno())


def run_writer(
    log_path: Path,
    interval: float,
    *,
    fsync: bool,
    max_records: int | None,
) -> int:
    """Write records at a fixed interval until max_records is reached or interrupted."""
    seq = read_last_seq(log_path) + 1
    written = 0
    while max_records is None or written < max_records:
        append_record(log_path, seq, fsync=fsync)
        seq += 1
        written += 1
        if max_records is not None and written >= max_records:
            break
        time.sleep(interval)
    return written


def main(argv: list[str] | None = None) -> int:
    """CLI entrypoint: run the continuous timestamp writer loop."""
    parser = argparse.ArgumentParser(
        description="Continuously append sequence+timestamp records to a DR-protected log file.",
    )
    parser.add_argument(
        "--log-path",
        default=os.environ.get(
            "DR_VALIDATION_LOG_PATH",
            "/var/lib/ramendr-dr-validation/timestamps.log",
        ),
        help="Append-only log file on replicated VM storage (default: %(default)s)",
    )
    parser.add_argument(
        "--interval",
        type=float,
        default=float(os.environ.get("DR_VALIDATION_INTERVAL", "1.0")),
        help="Seconds between records (default: %(default)s)",
    )
    parser.add_argument(
        "--no-fsync",
        action="store_true",
        help="Skip fsync after each write (faster, weaker durability signal)",
    )
    parser.add_argument(
        "--max-records",
        type=int,
        default=None,
        help="Exit after N records (default: run until interrupted)",
    )
    args = parser.parse_args(argv)
    log_path = Path(args.log_path)
    if args.interval <= 0:
        print("interval must be positive", file=sys.stderr)
        return 2
    if args.max_records is not None and args.max_records <= 0:
        print("max-records must be positive", file=sys.stderr)
        return 2
    try:
        run_writer(
            log_path,
            args.interval,
            fsync=not args.no_fsync,
            max_records=args.max_records,
        )
    except KeyboardInterrupt:
        return 0
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
