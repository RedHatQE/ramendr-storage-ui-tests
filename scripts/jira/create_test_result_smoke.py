#!/usr/bin/env python3
"""Controlled smoke-test CLI: report ONE Ramen DR Test Result to Jira (Phase B/C).

Defaults are maximally safe:

- ``JIRA_REPORT_RESULTS`` defaults to ``false`` -- with it unset/false, this
  never even reads from Jira; it just builds and prints the payload.
- ``JIRA_REPORT_DRY_RUN`` defaults to ``true`` -- even with reporting
  enabled, no write happens unless dry-run is explicitly disabled.
- A **real** Jira write additionally requires ``--confirm`` on the command
  line. Without it, the CLI refuses and exits non-zero rather than writing.

So a real write only happens when ALL of these are true at once:
``JIRA_REPORT_RESULTS=true`` and ``JIRA_REPORT_DRY_RUN=false`` and
``--confirm`` was passed. Any other combination is a safe, read-mostly
preview (or a pure offline payload build if reporting is disabled).

Usage (safe preview, no credentials needed):
    python scripts/jira/create_test_result_smoke.py \\
        --test-case failover_primary_to_secondary \\
        --scenario "Failover primary to secondary" \\
        --outcome PASS --compose RHEL-9.8.0

Usage (real write -- only after explicit approval):
    JIRA_REPORT_RESULTS=true JIRA_REPORT_DRY_RUN=false \\
    python scripts/jira/create_test_result_smoke.py \\
        --test-case failover_primary_to_secondary \\
        --scenario "Failover primary to secondary" \\
        --outcome PASS --confirm
"""

from __future__ import annotations

import argparse
import dataclasses
import json
import sys
import time
import uuid
from pathlib import Path

# Allow running this script directly (``python scripts/jira/...py``) without
# installing the project: add the repo root so ``reporting`` is importable.
_REPO_ROOT = Path(__file__).resolve().parents[2]
if str(_REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(_REPO_ROOT))

from reporting.jira_client import JiraClient, JiraClientError, config_from_env  # noqa: E402
from reporting.jira_config import reporting_config_from_env  # noqa: E402
from reporting.jira_models import TestOutcome, TestResultExecution  # noqa: E402
from reporting.jira_results import ParentValidationError, report_test_result  # noqa: E402
from reporting.jira_test_cases import RAMENDR_JIRA_TEST_CASES, resolve_test_case_key  # noqa: E402


def build_arg_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description=(
            "Controlled smoke test: report ONE Ramen DR Test Result to Jira. "
            "Refuses a real write unless reporting is enabled, dry-run is "
            "disabled, AND --confirm is given."
        )
    )
    parser.add_argument(
        "--test-case",
        required=True,
        choices=sorted(RAMENDR_JIRA_TEST_CASES),
        help="Approved Ramen DR scenario id (maps to a Jira Test Case key).",
    )
    parser.add_argument(
        "--scenario",
        required=True,
        help="Short human-readable label for the Jira summary/description.",
    )
    parser.add_argument(
        "--outcome",
        required=True,
        choices=[outcome.value for outcome in TestOutcome],
    )
    parser.add_argument(
        "--compose",
        default=None,
        help="Compose Version value; overrides $RAMENDR_COMPOSE_VERSION.",
    )
    parser.add_argument(
        "--run-id",
        default=None,
        help="Overrides $JIRA_RUN_ID; a random id is generated if neither is set.",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Force dry-run even if $JIRA_REPORT_DRY_RUN=false.",
    )
    parser.add_argument(
        "--confirm",
        action="store_true",
        help=(
            "Required (together with JIRA_REPORT_RESULTS=true and "
            "JIRA_REPORT_DRY_RUN=false) to perform a REAL Jira write. "
            "Never implied by any other flag."
        ),
    )
    return parser


def run(args: argparse.Namespace) -> int:
    config = reporting_config_from_env()
    if args.dry_run:
        config = dataclasses.replace(config, dry_run=True)

    real_write_requested = config.report_results and not config.dry_run
    if real_write_requested and not args.confirm:
        print(
            "Refusing: JIRA_REPORT_RESULTS=true and dry-run is disabled, but "
            "--confirm was not given. Pass --confirm to perform a REAL Jira "
            "write, or leave JIRA_REPORT_DRY_RUN=true / pass --dry-run to "
            "preview safely.",
            file=sys.stderr,
        )
        return 2

    try:
        test_case_key = resolve_test_case_key(args.test_case)
    except KeyError as exc:
        print(str(exc), file=sys.stderr)
        return 2

    run_id = (
        args.run_id
        or config.run_id
        or f"manual-{uuid.uuid4().hex[:8]}-{int(time.time())}"
    )

    try:
        execution = TestResultExecution(
            test_case_key=test_case_key,
            scenario=args.scenario,
            outcome=TestOutcome(args.outcome),
            run_id=run_id,
            compose_version=args.compose or config.compose_version,
            git_commit=config.git_commit,
            ci_job_url=config.ci_job_url,
        )
    except ValueError as exc:
        print(f"Invalid execution: {exc}", file=sys.stderr)
        return 2

    client: JiraClient | None = None
    if config.report_results:
        try:
            jira_config = config_from_env()
        except ValueError as exc:
            print(f"Jira credential configuration error: {exc}", file=sys.stderr)
            return 2
        client = JiraClient(jira_config)

    try:
        result = report_test_result(execution, client=client, config=config)
    except ParentValidationError as exc:
        print(f"Parent Test Case failed validation: {exc}", file=sys.stderr)
        parent_summary = getattr(exc, "parent_summary", None)
        if parent_summary is not None:
            print(
                "Observed parent (before failing validation):\n"
                + json.dumps(parent_summary, indent=2),
                file=sys.stderr,
            )
        return 1
    except JiraClientError as exc:
        print(f"Jira request failed: {exc}", file=sys.stderr)
        return 1

    print(
        json.dumps(
            {
                "dry_run": result.dry_run,
                "issue_key": result.issue_key,
                "initial_status": result.initial_status,
                "final_status": result.final_status,
                "transition_id_used": result.transition_id_used,
                "skipped_reason": result.skipped_reason,
                "parent_validation": result.parent_summary,
                "post_creation_verification": result.post_creation_verification,
                "fields": result.fields,
            },
            indent=2,
        )
    )

    if result.dry_run:
        print(
            f"\nDRY RUN -- no Jira write was performed ({result.skipped_reason}).",
            file=sys.stderr,
        )
        return 0

    print(
        f"\nCreated {result.issue_key} (observed initial status: "
        f"{result.initial_status!r}) and applied transition "
        f"{result.transition_id_used!r} -> final status "
        f"{result.final_status!r}.",
        file=sys.stderr,
    )

    # Best-effort only: confirms the new issue is indexed/searchable via JQL,
    # as a proxy for dashboard/saved-filter visibility. We don't have the
    # actual Ramen DR saved filter's JQL, so this can't confirm THAT
    # specific filter -- it only proves generic search-index visibility.
    # Never fails the overall run: the write already succeeded by this point.
    assert client is not None  # report_results implies a client was built
    try:
        jql = f'key = "{result.issue_key}"'
        found = client.search_issues(jql, max_results=1, fields="key,status")
        visible = any(issue.get("key") == result.issue_key for issue in found)
        print(
            f"Search-index visibility check (JQL: {jql}): "
            f"{'FOUND' if visible else 'NOT FOUND'} "
            "(generic search-index visibility only -- NOT the actual Ramen DR "
            "saved filter, whose JQL we don't have).",
            file=sys.stderr,
        )
    except JiraClientError as exc:
        print(
            f"Search-index visibility check failed (non-fatal, write already "
            f"succeeded): {exc}",
            file=sys.stderr,
        )

    return 0


def main(argv: list[str] | None = None) -> int:
    parser = build_arg_parser()
    args = parser.parse_args(argv)
    return run(args)


if __name__ == "__main__":
    raise SystemExit(main())
