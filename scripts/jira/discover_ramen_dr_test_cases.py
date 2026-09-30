#!/usr/bin/env python3
"""Read-only discovery of every Ramen DR Jira Test Case in RHELTEST.

Performs **zero** Jira writes -- this only issues a single, read-only JQL
search (``JiraClient.search_issues``, a GET) to answer one question before
extending automated Jira reporting to smoke: which Test Cases exist under

    project = RHELTEST AND labels = "ramen-dr" AND type = "Test Case"

and what does each one's summary/description say about the automated
scenario it corresponds to? Two of these are already approved and mapped
(``reporting.jira_test_cases.RAMENDR_JIRA_TEST_CASES``:
``failover_primary_to_secondary`` -> RHELTEST-3600,
``relocate_secondary_to_primary`` -> RHELTEST-3610); this script's job is
only to *retrieve and describe* every matching Test Case (including those
two, for cross-reference) -- it never proposes or writes a mapping itself.
Comparing the output against ``tests/ui/smoke/test_smoke.py`` and proposing
a smoke-to-Jira mapping is a separate, manual review step.

Usage:
    export JIRA_BASE_URL=https://redhat.atlassian.net
    export JIRA_EMAIL=<red-hat-email>
    export JIRA_API_TOKEN=<token>
    python scripts/jira/discover_ramen_dr_test_cases.py

Credentials come only from the environment (``JIRA_EMAIL``/``JIRA_API_TOKEN``)
-- never pass them on the command line; never printed/logged here. Sanitized
output (no credentials) is written under ``.work/jira/`` (already
``.gitignore``d).
"""

from __future__ import annotations

import argparse
import json
import os
import sys
from pathlib import Path
from typing import Any

# Allow running this script directly (``python scripts/jira/...py``) without
# installing the project: add the repo root so ``reporting`` is importable.
_REPO_ROOT = Path(__file__).resolve().parents[2]
if str(_REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(_REPO_ROOT))

from reporting.jira_client import (  # noqa: E402
    JiraAuthenticationError,
    JiraClient,
    JiraClientError,
    JiraConfig,
    JiraPermissionError,
)
from reporting.jira_test_cases import RAMENDR_JIRA_TEST_CASES  # noqa: E402

DEFAULT_OUTPUT_DIR = ".work/jira"
DEFAULT_LABEL = "ramen-dr"
DEFAULT_ISSUE_TYPE = "Test Case"
#: Ample headroom over the 13 Test Cases already known to exist -- a single
#: page (search_issues only fetches one page; see its docstring) is enough
#: for any realistic count here.
DEFAULT_MAX_RESULTS = 100
#: Fields requested from the search -- exactly what's needed to describe
#: each Test Case's automated scenario, nothing more.
_SEARCH_FIELDS = "summary,description,labels,issuetype,status"

#: scenario id -> Jira key, for already-approved mappings (informational
#: cross-reference only -- this script never adds to this mapping itself).
_APPROVED_BY_KEY = {key: scenario for scenario, key in RAMENDR_JIRA_TEST_CASES.items()}


def build_arg_parser() -> argparse.ArgumentParser:
    """Build the CLI argument parser for the discovery script."""
    parser = argparse.ArgumentParser(
        description=(
            "READ-ONLY discovery of Ramen DR Jira Test Cases "
            f'(project = RHELTEST AND labels = "{DEFAULT_LABEL}" AND '
            f'type = "{DEFAULT_ISSUE_TYPE}"). Performs zero Jira writes.'
        ),
    )
    parser.add_argument(
        "--base-url",
        default=os.environ.get("JIRA_BASE_URL", ""),
        help="Jira base URL (default: $JIRA_BASE_URL)",
    )
    parser.add_argument(
        "--project",
        default=os.environ.get("JIRA_PROJECT_KEY", "RHELTEST"),
        help="Jira project key (default: $JIRA_PROJECT_KEY or RHELTEST)",
    )
    parser.add_argument(
        "--label",
        default=DEFAULT_LABEL,
        help=f"Label to filter on (default: {DEFAULT_LABEL!r})",
    )
    parser.add_argument(
        "--issue-type",
        default=DEFAULT_ISSUE_TYPE,
        help=f"Issue type to filter on (default: {DEFAULT_ISSUE_TYPE!r})",
    )
    parser.add_argument(
        "--max-results",
        type=int,
        default=DEFAULT_MAX_RESULTS,
        help=f"Max issues to fetch in one page (default: {DEFAULT_MAX_RESULTS})",
    )
    parser.add_argument(
        "--output-dir",
        default=DEFAULT_OUTPUT_DIR,
        help=f"Directory to write sanitized discovery output (default: {DEFAULT_OUTPUT_DIR})",
    )
    parser.add_argument(
        "--verbose", action="store_true", help="Print extra progress information"
    )
    return parser


def build_config(args: argparse.Namespace) -> JiraConfig:
    """Build a JiraConfig from CLI args (base URL) and env (credentials)."""
    return JiraConfig(
        base_url=args.base_url,
        email=os.environ.get("JIRA_EMAIL", ""),
        api_token=os.environ.get("JIRA_API_TOKEN", ""),
    )


def build_jql(project: str, label: str, issue_type: str) -> str:
    """Build the exact JQL requested: project/label/type equality, ANDed.

    Values are wrapped in double quotes (required for the label and, since
    it may contain a space, the issue type); a stray embedded double quote
    is escaped defensively even though none of our callers ever supply one.
    """

    def _quoted(value: str) -> str:
        return '"' + value.replace('"', '\\"') + '"'

    return (
        f"project = {project} "
        f"AND labels = {_quoted(label)} "
        f"AND type = {_quoted(issue_type)}"
    )


def verify_authentication(client: JiraClient) -> dict[str, Any]:
    """GET /myself and print only displayName/accountId. Never the token."""
    user = client.get_current_user()
    print(
        f"Authenticated as: {user.get('displayName')} "
        f"(accountId={user.get('accountId')})"
    )
    return {
        "displayName": user.get("displayName"),
        "accountId": user.get("accountId"),
    }


#: Node types whose *children* are block-level (each gets its own line) --
#: e.g. a doc's paragraphs, or a list's items. Everything else (paragraph,
#: heading, codeBlock, ...) has inline children (text runs) that must be
#: concatenated with no separator, or "Bold and " / "plain." would render
#: as two lines instead of one sentence.
_BLOCK_CONTAINER_TYPES = {
    None,
    "doc",
    "blockquote",
    "listItem",
    "bulletList",
    "orderedList",
}


def adf_to_text(node: Any) -> str:
    """Best-effort, read-only Atlassian Document Format (ADF) -> plain text.

    Only extracts ``text`` leaf nodes; block-level containers (paragraphs,
    list items, etc.) each get their own line, while inline text runs within
    one paragraph/heading are concatenated with no separator. Enough to make
    a Test Case's description readable for identifying its automated
    scenario -- not a general-purpose ADF renderer (no bullet markers, no
    table structure); returns ``""`` for ``None``/an empty/malformed doc.
    """
    if node is None:
        return ""
    if isinstance(node, str):
        return node
    if not isinstance(node, dict):
        return ""

    node_type = node.get("type")
    if node_type == "text":
        return str(node.get("text", ""))

    content = node.get("content")
    if not isinstance(content, list):
        return ""

    pieces = [adf_to_text(child) for child in content]
    pieces = [p for p in pieces if p]
    separator = "\n" if node_type in _BLOCK_CONTAINER_TYPES else ""
    return separator.join(pieces)


def sanitize_test_case(issue: dict[str, Any]) -> dict[str, Any]:
    """Extract key/summary/labels/issuetype/status/description from one issue.

    ``description_text`` is a best-effort plain-text rendering of the ADF
    description (see :func:`adf_to_text`); ``description_adf`` keeps the raw
    structure in the saved JSON in case the plain-text rendering drops
    something relevant (e.g. a link or table) during manual review.
    """
    fields = issue.get("fields") if isinstance(issue, dict) else None
    fields = fields if isinstance(fields, dict) else {}
    issuetype = fields.get("issuetype") or {}
    status = fields.get("status") or {}
    key = issue.get("key")

    return {
        "key": key,
        "summary": fields.get("summary"),
        "labels": fields.get("labels") or [],
        "issuetype": issuetype.get("name"),
        "status": status.get("name"),
        "description_text": adf_to_text(fields.get("description")),
        "description_adf": fields.get("description"),
        "already_approved_scenario_id": _APPROVED_BY_KEY.get(key),
    }


def format_test_case_table(rows: list[dict[str, Any]]) -> str:
    """Render a readable KEY / STATUS / MAPPED / SUMMARY table."""
    header = f"{'KEY':<14} {'STATUS':<12} {'MAPPED SCENARIO':<32} {'SUMMARY':<50}"
    lines = [header, "-" * len(header)]
    for row in rows:
        summary = (row["summary"] or "")[:50]
        mapped = row["already_approved_scenario_id"] or "(unmapped)"
        lines.append(
            f"{row['key']:<14} {(row['status'] or ''):<12} {mapped:<32} {summary:<50}"
        )
    return "\n".join(lines)


def write_json(path: Path, data: Any) -> None:
    """Write ``data`` as indented JSON, creating parent directories as needed."""
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(
        json.dumps(data, indent=2, sort_keys=False) + "\n", encoding="utf-8"
    )


def build_summary_text(rows: list[dict[str, Any]], *, jql: str) -> str:
    """Render one human-readable block per Test Case, description included."""
    lines = [
        "Ramen DR Jira Test Case discovery",
        "==================================",
        "",
        f"JQL: {jql}",
        f"Total Test Cases found: {len(rows)}",
        "",
    ]
    for row in rows:
        lines.append(f"{row['key']}: {row['summary']}")
        lines.append(f"  status: {row['status']}")
        lines.append(f"  labels: {row['labels']}")
        lines.append(
            "  already approved scenario id: "
            f"{row['already_approved_scenario_id'] or '(none -- unmapped)'}"
        )
        description_text = row["description_text"]
        if description_text:
            lines.append("  description:")
            for line in description_text.splitlines():
                lines.append(f"    {line}")
        else:
            lines.append("  description: (none)")
        lines.append("")
    lines.append(
        "STOP: this is discovery output only. Compare it against "
        "tests/ui/smoke/test_smoke.py by hand (or with an LLM/human review) "
        "before proposing or implementing any smoke-to-Jira mapping -- this "
        "script never guesses or writes one itself."
    )
    return "\n".join(lines)


def run_discovery(args: argparse.Namespace) -> int:
    """Execute the read-only discovery. Returns a process exit code."""
    try:
        config = build_config(args)
    except ValueError as exc:
        print(f"Configuration error: {exc}", file=sys.stderr)
        return 2

    client = JiraClient(config)
    output_dir = Path(args.output_dir)

    try:
        verify_authentication(client)
    except (JiraAuthenticationError, JiraPermissionError) as exc:
        print(str(exc), file=sys.stderr)
        return 1
    except JiraClientError as exc:
        print(f"Failed to contact Jira: {exc}", file=sys.stderr)
        return 1

    jql = build_jql(args.project, args.label, args.issue_type)
    if args.verbose:
        print(f"Searching (read-only): {jql}")

    try:
        raw_issues = client.search_issues(
            jql, max_results=args.max_results, fields=_SEARCH_FIELDS
        )
    except JiraClientError as exc:
        print(f"Jira search failed: {exc}", file=sys.stderr)
        return 1

    rows = [sanitize_test_case(issue) for issue in raw_issues]
    rows.sort(key=lambda r: r["key"] or "")

    write_json(output_dir / "ramen-dr-test-cases.json", rows)
    summary = build_summary_text(rows, jql=jql)
    (output_dir / "ramen-dr-test-cases-summary.txt").write_text(
        summary + "\n", encoding="utf-8"
    )

    print()
    print(format_test_case_table(rows))
    print()
    print(summary)
    print()
    print(f"Discovery output written to: {output_dir}/")

    unmapped = [r for r in rows if not r["already_approved_scenario_id"]]
    print(
        f"{len(rows)} Test Case(s) found, {len(unmapped)} not yet in "
        "reporting.jira_test_cases.RAMENDR_JIRA_TEST_CASES."
    )

    if len(raw_issues) == args.max_results:
        print(
            f"WARNING: exactly --max-results ({args.max_results}) issues were "
            "returned -- there may be more than one page. search_issues() only "
            "fetches a single page; re-run with a higher --max-results if you "
            "suspect truncation.",
            file=sys.stderr,
        )

    return 0


def main(argv: list[str] | None = None) -> int:
    """CLI entrypoint. READ-ONLY: never issues a POST/PUT/DELETE to Jira."""
    parser = build_arg_parser()
    args = parser.parse_args(argv)

    if not args.base_url:
        print("Missing --base-url / $JIRA_BASE_URL", file=sys.stderr)
        return 2

    try:
        return run_discovery(args)
    except JiraClientError as exc:
        print(f"Jira discovery failed: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
