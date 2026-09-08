#!/usr/bin/env python3
"""Read-only production Jira ``Test Result`` schema discovery for RHELTEST.

This script performs **zero** Jira writes. It only issues GET requests
(via :class:`reporting.jira_client.JiraClient`, which has no write methods)
to determine the real production configuration needed before any Jira
write code is implemented:

- RHELTEST project id
- ``Test Result`` issue type id and subtask/hierarchy behavior
- required create fields, and the Parent / Compose Version / Labels /
  Fix versions / Description / Test Steps field shapes
- (optionally, with ``--sample-test-result``) how a real Test Result
  stores those fields, and its available workflow transitions

See docs/jira-test-result-reporting.md and
Ramen_DR_Jira_Test_Result_Integration_Plan.md (Phase A) for context.

Usage:
    python scripts/jira/discover_test_result_schema.py
    python scripts/jira/discover_test_result_schema.py \\
        --sample-test-result RHELTEST-XXXX

Credentials/URL default from JIRA_BASE_URL, JIRA_PROJECT_KEY, JIRA_EMAIL,
JIRA_API_TOKEN. Never pass secrets on the command line; never printed here.
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

DEFAULT_OUTPUT_DIR = ".work/jira"
TEST_RESULT_ISSUE_TYPE_NAME = "Test Result"

#: Display-name substrings (case-insensitive) we specifically care about.
FIELDS_OF_INTEREST = (
    "Parent",
    "Compose Version",
    "Labels",
    "Fix versions",
    "Fix version",
    "Description",
    "Test Steps",
)


def build_arg_parser() -> argparse.ArgumentParser:
    """Build the CLI argument parser for the discovery script."""
    parser = argparse.ArgumentParser(
        description=(
            "READ-ONLY discovery of the production Jira Test Result schema. "
            "Performs zero Jira writes."
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
        "--sample-test-result",
        default=None,
        metavar="RHELTEST-XXXX",
        help="Inspect one existing Test Result's stored field shapes and transitions",
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
    """Build a JiraConfig from CLI args (base URL/project) and env (credentials)."""
    return JiraConfig(
        base_url=args.base_url,
        email=os.environ.get("JIRA_EMAIL", ""),
        api_token=os.environ.get("JIRA_API_TOKEN", ""),
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


def sanitize_project(project: dict[str, Any]) -> dict[str, Any]:
    """Extract only the fields we need from GET /project/{key}."""
    return {
        "project_id": project.get("id"),
        "project_key": project.get("key"),
        "project_name": project.get("name"),
    }


def sanitize_issue_type(item: dict[str, Any]) -> dict[str, Any]:
    """Extract id/name/subtask/hierarchy from one createmeta issue type entry."""
    return {
        "id": item.get("id"),
        "name": item.get("name"),
        "subtask": item.get("subtask"),
        "hierarchyLevel": item.get("hierarchyLevel"),
        "iconUrl": item.get("iconUrl"),
    }


def find_issue_type_by_name(
    issue_types: list[dict[str, Any]],
    type_name: str = TEST_RESULT_ISSUE_TYPE_NAME,
) -> dict[str, Any] | None:
    """Find the first issue type entry whose name matches ``type_name`` exactly."""
    for item in issue_types:
        if item.get("name") == type_name:
            return item
    return None


def find_test_result_issue_type(
    issue_types: list[dict[str, Any]],
    type_name: str = TEST_RESULT_ISSUE_TYPE_NAME,
) -> dict[str, Any] | None:
    """Find the createmeta issue type entry whose name matches ``type_name``.

    Absence here only means the type is not offered by the create-issue
    metadata endpoint for the current user/project -- it does **not** prove
    the issue type doesn't exist. See ``diagnose_test_result_availability``.
    """
    return find_issue_type_by_name(issue_types, type_name)


def sanitize_global_issue_type(item: dict[str, Any]) -> dict[str, Any]:
    """Extract id/name/subtask/hierarchy/scope from a GET /issuetype/{id} response.

    ``scope`` tells us whether the type is global or scoped to one project,
    independent of create-screen/permission filtering.
    """
    scope = item.get("scope") or {}
    return {
        "id": item.get("id"),
        "name": item.get("name"),
        "subtask": item.get("subtask"),
        "hierarchyLevel": item.get("hierarchyLevel"),
        "scope_type": scope.get("type"),
        "scope_project_id": (scope.get("project") or {}).get("id"),
    }


def sanitize_project_issue_type(item: dict[str, Any]) -> dict[str, Any]:
    """Extract id/name/subtask/hierarchy from a GET /issuetype/project entry."""
    return {
        "id": item.get("id"),
        "name": item.get("name"),
        "subtask": item.get("subtask"),
        "hierarchyLevel": item.get("hierarchyLevel"),
    }


def sanitize_allowed_values(field_meta: dict[str, Any]) -> list[dict[str, Any]]:
    """Reduce a create-field's ``allowedValues`` to id/value/name only (drop noise)."""
    reduced = []
    for value in field_meta.get("allowedValues", []) or []:
        if not isinstance(value, dict):
            continue
        reduced.append(
            {key: value[key] for key in ("id", "value", "name") if key in value}
        )
    return reduced


def build_field_rows(create_fields: dict[str, dict[str, Any]]) -> list[dict[str, Any]]:
    """Turn create-field metadata into flat, sanitized rows for printing/saving."""
    rows = []
    for field_id, meta in create_fields.items():
        schema = meta.get("schema", {}) or {}
        rows.append(
            {
                "field_id": field_id,
                "name": meta.get("name"),
                "required": meta.get("required"),
                "schema_type": schema.get("type"),
                "schema_items": schema.get("items"),
                "schema_custom": schema.get("custom"),
                "operations": meta.get("operations", []),
                "has_default_value": "defaultValue" in meta,
                "allowed_values": sanitize_allowed_values(meta),
            }
        )
    rows.sort(key=lambda r: (r["name"] or "", r["field_id"]))
    return rows


def find_field_rows_by_name(
    rows: list[dict[str, Any]], name_substring: str
) -> list[dict[str, Any]]:
    """Case-insensitive substring match on field display name."""
    needle = name_substring.lower()
    return [r for r in rows if needle in (r["name"] or "").lower()]


def format_field_table(rows: list[dict[str, Any]]) -> str:
    """Render a readable FIELD NAME / FIELD ID / REQUIRED / TYPE table."""
    header = f"{'FIELD NAME':<28} {'FIELD ID':<24} {'REQUIRED':<10} {'TYPE':<20}"
    lines = [header, "-" * len(header)]
    for row in rows:
        lines.append(
            f"{(row['name'] or ''):<28} {row['field_id']:<24} "
            f"{str(row['required']):<10} {(row['schema_type'] or ''):<20}"
        )
    return "\n".join(lines)


def sanitize_sample_issue(issue: dict[str, Any]) -> dict[str, Any]:
    """Extract only the fields needed to compare create-shape vs stored-shape."""
    fields = issue.get("fields", {}) or {}
    names = issue.get("names", {}) or {}

    def _field(key: str) -> Any:
        return fields.get(key)

    sanitized: dict[str, Any] = {
        "key": issue.get("key"),
        "issuetype": _field("issuetype"),
        "status": _field("status"),
        "parent": _field("parent"),
        "labels": _field("labels"),
        "fixVersions": _field("fixVersions"),
        "reporter": _minimal_user(_field("reporter")),
        "assignee": _minimal_user(_field("assignee")),
        "description_present": _field("description") is not None,
    }

    # Cross-reference any custom field whose display name matches our fields
    # of interest (e.g. "Compose Version", "Test Steps") without dumping the
    # full, potentially large/unrelated field set.
    custom_fields_of_interest = {}
    for field_id, field_name in names.items():
        if not field_id.startswith("customfield_"):
            continue
        if any(
            interest.lower() in field_name.lower() for interest in FIELDS_OF_INTEREST
        ):
            custom_fields_of_interest[field_id] = {
                "name": field_name,
                "value": fields.get(field_id),
            }
    sanitized["custom_fields_of_interest"] = custom_fields_of_interest
    return sanitized


def _minimal_user(user: dict[str, Any] | None) -> dict[str, Any] | None:
    """Reduce a Jira user object to non-sensitive identifiers."""
    if not user:
        return None
    return {
        "accountId": user.get("accountId"),
        "displayName": user.get("displayName"),
    }


def sanitize_transitions(transitions: list[dict[str, Any]]) -> list[dict[str, Any]]:
    """Extract transition id/name/target status id/name for PASS/FAIL/BLOCKED lookup."""
    sanitized = []
    for transition in transitions:
        to_status = transition.get("to", {}) or {}
        sanitized.append(
            {
                "transition_id": transition.get("id"),
                "transition_name": transition.get("name"),
                "to_status_id": to_status.get("id"),
                "to_status_name": to_status.get("name"),
            }
        )
    return sanitized


def diagnose_test_result_availability(
    *,
    create_metadata_has_test_result: bool,
    create_issue_types_listing_empty: bool = False,
    createmeta_issue_type_id: str | None = None,
    sample_issue_type_id: str | None,
    sample_issue_type_name: str | None,
    sample_issue_type_subtask: bool | None,
    associated_with_project_issue_type_scheme: bool | None,
    create_fields_probe_field_count: int | None = None,
    create_fields_probe_error: str | None,
    create_issues_permission: bool | None = None,
) -> dict[str, Any]:
    """Distinguish "exists" / "viewable" / "createable" for the Test Result type.

    Absence from ``GET /issue/createmeta/{project}/issuetypes`` only means the
    current user cannot create that type via the generic create screen for
    this project -- it does not prove the issue type doesn't exist. This
    combines several independent, read-only signals to produce a best-effort
    (not certain) diagnosis, with the supporting evidence spelled out in
    ``reasoning`` so a human can confirm before Phase B.

    ``create_fields_probe_field_count`` must be the number of fields actually
    returned by a direct ``GET /issue/createmeta/{project}/issuetypes/{id}``
    probe, not just "no exception was raised" -- Jira Cloud commonly returns
    HTTP 200 with zero fields (not a 4xx) when a type is not createable for
    the current user/project, so an empty-but-200 probe is *not* evidence of
    a bug in our own listing code.

    ``sample_issue_type_id`` must be reserved exclusively for evidence from an
    actually-fetched sample issue (``GET /issue/{key}``) -- never backfilled
    from createmeta. Pass the createmeta-derived id separately via
    ``createmeta_issue_type_id`` instead; presence in create metadata is its
    own, independent proof of existence (see ``exists_in_project`` below) and
    must not be misreported as "a sample GET succeeded".
    """
    sample_fetched = sample_issue_type_id is not None
    exists_via_createmeta = create_metadata_has_test_result and (
        createmeta_issue_type_id is not None
    )
    exists_in_project = sample_fetched or exists_via_createmeta
    reasoning: list[str] = []
    probe_returned_fields = bool(create_fields_probe_field_count)

    if not exists_in_project:
        reasoning.append(
            "No sample Test Result was fetched (no --sample-test-result given, or "
            "the fetch failed) and the issue type is absent from create metadata -- "
            "cannot confirm existence independently. Re-run with "
            "--sample-test-result RHELTEST-XXXX."
        )
        return {
            "exists_in_project": False,
            "viewable_by_current_user": False,
            "createable_via_create_metadata": create_metadata_has_test_result,
            "associated_with_project_issue_type_scheme": (
                associated_with_project_issue_type_scheme
            ),
            "create_fields_probe_field_count": create_fields_probe_field_count,
            "create_fields_probe_error": create_fields_probe_error,
            "create_issues_permission": create_issues_permission,
            "likely_cause": "inconclusive",
            "reasoning": reasoning,
        }

    if sample_fetched:
        reasoning.append(
            f"GET /issue/{{key}} for the sample succeeded and returned issue type "
            f"{sample_issue_type_name!r} (id={sample_issue_type_id}) -> the issue type "
            "exists in the project and is viewable by the current user."
        )
    else:
        reasoning.append(
            "No sample was fetched, but the issue type "
            f"(id={createmeta_issue_type_id}) is present in "
            "GET /issue/createmeta/{project}/issuetypes for the current user -- "
            "create metadata only lists types that already exist, so its "
            "presence there is independent proof of existence even without a "
            "sample."
        )

    likely_cause = "inconclusive"

    if create_metadata_has_test_result:
        likely_cause = "none"
        reasoning.append(
            "The issue type IS present in create metadata for the current user -- "
            "no blocker; it is createable via the standard create screen."
        )
    elif probe_returned_fields:
        likely_cause = "discovery_code_assumption"
        reasoning.append(
            "A direct GET /issue/createmeta/{project}/issuetypes/{id} probe using "
            f"the sample's issue type id returned {create_fields_probe_field_count} "
            "real field(s), even though the type was absent from the issuetypes "
            "*listing* endpoint. This points to a listing/pagination gap in our own "
            "discovery code, not a real Jira restriction -- the type is actually "
            "createable via the API."
        )
    elif create_issues_permission is False:
        likely_cause = "permission"
        reasoning.append(
            "GET /mypermissions reports CREATE_ISSUES=false for the current user "
            "on this project -- a blanket permission problem, not something "
            "specific to the Test Result issue type."
        )
    elif create_issue_types_listing_empty:
        likely_cause = "permission"
        reasoning.append(
            "GET /issue/createmeta/{project}/issuetypes returned an EMPTY list for "
            "*every* issue type (not just Test Result) -- this is the documented "
            "Jira Cloud behavior when the current user lacks Create-issue "
            "permission on the project, rather than something specific to Test "
            "Result's screen/hierarchy configuration."
        )
    elif associated_with_project_issue_type_scheme is True:
        reasoning.append(
            "GET /issuetype/project confirms the issue type IS associated with "
            "this project's issue type scheme."
        )
        if sample_issue_type_subtask:
            likely_cause = "hierarchy_or_parent_requirement"
            reasoning.append(
                "The sample issue type has subtask=true. Jira's project-level "
                "createmeta commonly excludes subtask-level types unless creation "
                "is requested in the context of a parent issue."
            )
        else:
            likely_cause = "create_screen_configuration"
            reasoning.append(
                "It is associated with the project and is not a subtask type, but "
                "still absent from createmeta and the direct probe returned no "
                "fields. The most common cause is a missing 'Create' screen mapping "
                "in the project's Issue Type Screen Scheme for this type, or a "
                "marketplace test-management app that intentionally hides its own "
                "issue types (e.g. 'Test Result'/'Test Execution') from the generic "
                "Jira create screen, requiring creation through the app's own "
                "UI/API instead."
            )
        if create_fields_probe_error and (
            "403" in create_fields_probe_error
            or "permission" in create_fields_probe_error.lower()
        ):
            likely_cause = "permission"
            reasoning.append(
                f"Direct probe failed with a permission-flavored error: "
                f"{create_fields_probe_error}"
            )
    elif associated_with_project_issue_type_scheme is False:
        likely_cause = "create_screen_configuration"
        reasoning.append(
            "GET /issuetype/project does NOT list this issue type for the project, "
            "yet a real instance exists. This can happen when the issue was created "
            "by an app/integration that bypasses the standard project issue-type "
            "scheme (common for test-management apps), or the scheme changed after "
            "the sample issue was created."
        )
    else:
        reasoning.append(
            "GET /issuetype/project could not be evaluated (call failed or was "
            "skipped) -- cause is inconclusive from the API alone."
        )

    return {
        "exists_in_project": exists_in_project,
        "viewable_by_current_user": True,
        "createable_via_create_metadata": create_metadata_has_test_result,
        "associated_with_project_issue_type_scheme": (
            associated_with_project_issue_type_scheme
        ),
        "create_fields_probe_field_count": create_fields_probe_field_count,
        "create_fields_probe_error": create_fields_probe_error,
        "create_issues_permission": create_issues_permission,
        "likely_cause": likely_cause,
        "reasoning": reasoning,
    }


def write_json(path: Path, data: Any) -> None:
    """Write ``data`` as indented JSON, creating parent directories as needed."""
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(
        json.dumps(data, indent=2, sort_keys=False) + "\n", encoding="utf-8"
    )


def build_summary_text(
    *,
    project: dict[str, Any],
    test_result_type: dict[str, Any] | None,
    field_rows: list[dict[str, Any]],
    fields_of_interest: dict[str, list[dict[str, Any]]],
    transitions: list[dict[str, Any]] | None,
    diagnosis: dict[str, Any] | None = None,
) -> str:
    """Render the Phase A success-criteria table (see plan section 20)."""

    def _val(value: Any) -> str:
        if value is None or value == "":
            return "?"
        return str(value)

    required_fields = [r["name"] for r in field_rows if r["required"]]
    compose_rows = fields_of_interest.get("Compose Version", [])
    parent_rows = fields_of_interest.get("Parent", [])
    labels_rows = fields_of_interest.get("Labels", [])
    fix_versions_rows = fields_of_interest.get(
        "Fix versions", []
    ) or fields_of_interest.get("Fix version", [])

    lines = [
        "Phase A discovery summary",
        "=========================",
        "",
        f"RHELTEST project ID                  = {_val(project.get('project_id'))}",
        f"RHELTEST project key                 = {_val(project.get('project_key'))}",
        "",
    ]
    if test_result_type:
        lines += [
            f"Test Result issue type ID            = {_val(test_result_type.get('id'))}",
            f"Test Result subtask/child            = {_val(test_result_type.get('subtask'))}",
            f"Test Result hierarchyLevel           = {_val(test_result_type.get('hierarchyLevel'))}",
        ]
    else:
        lines.append("Test Result issue type ID            = NOT FOUND")
    lines += [
        "",
        f"Required create fields                = {_val(', '.join(required_fields) if required_fields else None)}",
        "",
    ]
    if parent_rows:
        for row in parent_rows:
            lines.append(f"Parent field                          = {row['field_id']}")
            lines.append(
                f"Parent required                       = {_val(row['required'])}"
            )
            lines.append(
                f"Parent schema type                    = {_val(row['schema_type'])}"
            )
    else:
        lines.append("Parent field                          = NOT IN CREATE METADATA")
    lines.append("")
    if compose_rows:
        for row in compose_rows:
            lines.append(f"Compose Version field ID              = {row['field_id']}")
            lines.append(
                f"Compose Version required              = {_val(row['required'])}"
            )
            lines.append(
                f"Compose Version schema type           = {_val(row['schema_type'])}"
            )
            lines.append(
                f"Compose Version schema custom         = {_val(row['schema_custom'])}"
            )
            lines.append(
                f"Compose Version allowed values        = {_val(row['allowed_values'] or None)}"
            )
    else:
        lines.append("Compose Version field ID              = NOT FOUND")
    lines.append("")
    if labels_rows:
        lines.append(
            f"Labels field                          = {labels_rows[0]['field_id']}"
        )
    if fix_versions_rows:
        lines.append(
            f"Fix versions field                    = {fix_versions_rows[0]['field_id']}"
        )
    lines.append("")
    if transitions is not None:
        lines.append("Available workflow transitions:")
        for t in transitions:
            transition_id = t["transition_id"] or ""
            transition_name = t["transition_name"] or ""
            to_status_name = t["to_status_name"] or ""
            lines.append(
                f"  {transition_id:<6} {transition_name:<20} -> {to_status_name}"
            )
        lines.append("")
        lines.append(
            "Transition -> PASS                    = ? (confirm against transition_name/to_status_name above)"
        )
        lines.append(
            "Transition -> FAIL                    = ? (confirm against transition_name/to_status_name above)"
        )
        lines.append(
            "Transition -> BLOCKED                  = ? (confirm against transition_name/to_status_name above)"
        )
    else:
        lines.append(
            "Workflow transitions                  = NOT DISCOVERED "
            "(re-run with --sample-test-result RHELTEST-XXXX)"
        )
    lines.append("")
    if diagnosis is not None:
        lines.append("Test Result availability diagnosis")
        lines.append("-----------------------------------")
        lines.append(
            f"Exists in project                     = {_val(diagnosis.get('exists_in_project'))}"
        )
        lines.append(
            f"Viewable by current user              = {_val(diagnosis.get('viewable_by_current_user'))}"
        )
        lines.append(
            f"Createable via create metadata        = {_val(diagnosis.get('createable_via_create_metadata'))}"
        )
        lines.append(
            "Associated with project issue-type scheme = "
            f"{_val(diagnosis.get('associated_with_project_issue_type_scheme'))}"
        )
        lines.append(
            "Direct createmeta probe field count    = "
            f"{_val(diagnosis.get('create_fields_probe_field_count'))}"
        )
        if diagnosis.get("create_fields_probe_error"):
            lines.append(
                f"Direct createmeta probe error          = {diagnosis['create_fields_probe_error']}"
            )
        lines.append(
            f"CREATE_ISSUES permission (mypermissions) = {_val(diagnosis.get('create_issues_permission'))}"
        )
        lines.append(
            f"Likely cause                          = {_val(diagnosis.get('likely_cause'))}"
        )
        lines.append("Reasoning:")
        for reason in diagnosis.get("reasoning", []):
            lines.append(f"  - {reason}")
        lines.append("")
    lines.append(
        "STOP: review this summary and the saved JSON before implementing any Jira writes."
    )
    return "\n".join(lines)


def run_discovery(args: argparse.Namespace) -> int:
    """Execute Phase A discovery. Returns a process exit code."""
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

    if args.verbose:
        print(f"Resolving project {args.project!r}...")
    project = client.get_project(args.project)
    project_info = sanitize_project(project)
    write_json(output_dir / "project.json", project_info)
    print(f"Project: {project_info}")

    if args.verbose:
        print("Fetching create issue types...")
    issue_types_raw = client.get_create_issue_types(args.project)
    issue_types = [sanitize_issue_type(item) for item in issue_types_raw]
    write_json(output_dir / "issue-types.json", issue_types)

    createmeta_hit = find_test_result_issue_type(issue_types_raw)
    create_metadata_has_test_result = createmeta_hit is not None
    test_result_type = sanitize_issue_type(createmeta_hit) if createmeta_hit else None
    if test_result_type:
        print(
            f"Found '{TEST_RESULT_ISSUE_TYPE_NAME}' issue type in create metadata: {test_result_type}"
        )
    else:
        print(
            f"'{TEST_RESULT_ISSUE_TYPE_NAME}' issue type is NOT in create metadata for "
            f"project {args.project}. This does not prove it doesn't exist -- "
            "continuing with independent diagnostics (see below).",
            file=sys.stderr,
        )

    # Independent of create metadata: is the type associated with the
    # project's issue type scheme at all? (GET /issuetype/project)
    project_issue_types: list[dict[str, Any]] = []
    project_issue_types_error: str | None = None
    try:
        if args.verbose:
            print("Fetching project issue-type scheme (GET /issuetype/project)...")
        raw_project_issue_types = client.get_project_issue_types(
            project_info["project_id"]
        )
        project_issue_types = [
            sanitize_project_issue_type(i) for i in raw_project_issue_types
        ]
        write_json(output_dir / "project-issue-types.json", project_issue_types)
    except JiraClientError as exc:
        project_issue_types_error = str(exc)
        print(f"Warning: GET /issuetype/project failed: {exc}", file=sys.stderr)

    scheme_hit = find_issue_type_by_name(project_issue_types)

    # Resolve a usable issue-type id for "Test Result": prefer create
    # metadata, then the sample issue (fetched below), then the project
    # issue-type scheme listing by name.
    resolved_id = test_result_type["id"] if test_result_type else None
    resolved_name = test_result_type["name"] if test_result_type else None
    resolved_subtask = test_result_type["subtask"] if test_result_type else None

    sample_issue_type_id: str | None = None
    sample_issue_type_name: str | None = None
    sample_issue_type_subtask: bool | None = None
    transitions: list[dict[str, Any]] | None = None

    if args.sample_test_result:
        if args.verbose:
            print(f"Inspecting sample Test Result {args.sample_test_result}...")
        try:
            sample_issue = client.get_issue(
                args.sample_test_result, expand="names,schema"
            )
        except JiraClientError as exc:
            sample_issue = None
            print(
                f"Failed to fetch sample Test Result {args.sample_test_result}: {exc}",
                file=sys.stderr,
            )

        if sample_issue is not None:
            sanitized_sample = sanitize_sample_issue(sample_issue)
            write_json(output_dir / "sample-test-result.json", sanitized_sample)
            print(f"Sample Test Result: {sanitized_sample}")

            issuetype_field = sanitized_sample.get("issuetype") or {}
            sample_issue_type_id = issuetype_field.get("id")
            sample_issue_type_name = issuetype_field.get("name")
            sample_issue_type_subtask = issuetype_field.get("subtask")

            try:
                raw_transitions = client.get_transitions(args.sample_test_result)
                transitions = sanitize_transitions(raw_transitions)
                write_json(output_dir / "test-result-transitions.json", transitions)
                print("Transitions:")
                for t in transitions:
                    print(f"  {t}")
            except JiraClientError as exc:
                print(f"Warning: could not fetch transitions: {exc}", file=sys.stderr)

    if resolved_id is None:
        resolved_id = sample_issue_type_id
        resolved_name = sample_issue_type_name
        resolved_subtask = sample_issue_type_subtask
    if resolved_id is None and scheme_hit is not None:
        resolved_id = scheme_hit.get("id")
        resolved_name = scheme_hit.get("name")
        resolved_subtask = scheme_hit.get("subtask")

    # Global issue-type metadata (hierarchy/scope), independent of the
    # project's create-screen configuration.
    if resolved_id:
        try:
            if args.verbose:
                print(f"Fetching global issue-type metadata for id={resolved_id}...")
            raw_global_meta = client.get_issue_type(resolved_id)
            global_issue_type_meta = sanitize_global_issue_type(raw_global_meta)
            write_json(
                output_dir / "test-result-issuetype.json", global_issue_type_meta
            )
        except JiraClientError as exc:
            print(
                f"Warning: GET /issuetype/{resolved_id} failed: {exc}", file=sys.stderr
            )

    # Create fields: use the normal create-metadata result if it had the
    # type; otherwise, still-read-only, probe directly with the resolved id
    # to see whether the type-listing endpoint is simply omitting a type
    # that IS actually createable via the API.
    field_rows: list[dict[str, Any]] = []
    fields_of_interest: dict[str, list[dict[str, Any]]] = {}
    create_fields_probe_field_count: int | None = None
    create_fields_probe_error: str | None = None

    if create_metadata_has_test_result:
        if args.verbose:
            print("Fetching create field metadata...")
        create_fields = client.get_create_fields(args.project, test_result_type["id"])
        write_json(output_dir / "test-result-create-fields.json", create_fields)
        field_rows = build_field_rows(create_fields)
        create_fields_probe_field_count = len(field_rows)
    elif resolved_id:
        print(
            f"Probing GET /issue/createmeta/{args.project}/issuetypes/{resolved_id} "
            "directly (read-only) since it was absent from the issuetypes listing..."
        )
        try:
            probe_fields = client.get_create_fields(args.project, resolved_id)
            write_json(output_dir / "test-result-create-fields.json", probe_fields)
            field_rows = build_field_rows(probe_fields)
            create_fields_probe_field_count = len(field_rows)
            if field_rows:
                print(f"Direct probe SUCCEEDED: {len(field_rows)} field(s) returned.")
            else:
                print(
                    "Direct probe returned HTTP 200 but ZERO fields -- this is NOT "
                    "proof of createability; Jira Cloud returns an empty (not 4xx) "
                    "result here when the type isn't createable for this user/project."
                )
        except JiraClientError as exc:
            create_fields_probe_field_count = None
            create_fields_probe_error = str(exc)
            write_json(output_dir / "test-result-create-fields.json", {})
            print(f"Direct probe FAILED: {exc}")
    else:
        write_json(output_dir / "test-result-create-fields.json", {})

    # Blanket permission check, independent of any specific issue type.
    create_issues_permission: bool | None = None
    try:
        if args.verbose:
            print("Checking CREATE_ISSUES permission (GET /mypermissions)...")
        perms = client.get_my_permissions(args.project, "CREATE_ISSUES")
        create_issues_permission = (
            perms.get("permissions", {}).get("CREATE_ISSUES", {}).get("havePermission")
        )
        write_json(
            output_dir / "my-permissions.json",
            {"CREATE_ISSUES": create_issues_permission},
        )
        print(f"CREATE_ISSUES permission on {args.project}: {create_issues_permission}")
    except JiraClientError as exc:
        print(f"Warning: GET /mypermissions failed: {exc}", file=sys.stderr)

    if field_rows:
        print()
        print(format_field_table(field_rows))
        print()
        for interest in FIELDS_OF_INTEREST:
            matches = find_field_rows_by_name(field_rows, interest)
            if matches:
                fields_of_interest[interest] = matches
                print(
                    f"[{interest}] matched field(s): {[m['field_id'] for m in matches]}"
                )

    if args.verbose:
        print("Fetching global field registry...")
    try:
        all_fields = client.get_fields()
        write_json(output_dir / "jira-fields.json", all_fields)
    except JiraClientError as exc:
        print(f"Warning: GET /field failed: {exc}", file=sys.stderr)

    associated_with_scheme: bool | None = None
    if project_issue_types_error is None and resolved_id:
        associated_with_scheme = any(
            i.get("id") == resolved_id for i in project_issue_types
        )

    diagnosis = diagnose_test_result_availability(
        create_metadata_has_test_result=create_metadata_has_test_result,
        create_issue_types_listing_empty=len(issue_types_raw) == 0,
        createmeta_issue_type_id=(
            resolved_id if create_metadata_has_test_result else None
        ),
        sample_issue_type_id=sample_issue_type_id,
        sample_issue_type_name=sample_issue_type_name or resolved_name,
        sample_issue_type_subtask=(
            sample_issue_type_subtask if sample_issue_type_id else resolved_subtask
        ),
        associated_with_project_issue_type_scheme=associated_with_scheme,
        create_fields_probe_field_count=create_fields_probe_field_count,
        create_fields_probe_error=create_fields_probe_error,
        create_issues_permission=create_issues_permission,
    )
    write_json(output_dir / "test-result-diagnosis.json", diagnosis)
    print()
    print("Diagnosis:")
    print(json.dumps(diagnosis, indent=2))

    resolved_type_for_summary = (
        test_result_type
        if test_result_type
        else (
            {
                "id": resolved_id,
                "name": resolved_name,
                "subtask": resolved_subtask,
                "hierarchyLevel": None,
            }
            if resolved_id
            else None
        )
    )
    summary = build_summary_text(
        project=project_info,
        test_result_type=resolved_type_for_summary,
        field_rows=field_rows,
        fields_of_interest=fields_of_interest,
        transitions=transitions,
        diagnosis=diagnosis,
    )
    (output_dir / "discovery-summary.txt").write_text(summary + "\n", encoding="utf-8")
    print()
    print(summary)
    print()
    print(f"Discovery output written to: {output_dir}/")

    if resolved_id is None:
        print(
            f"BLOCKER: could not resolve '{TEST_RESULT_ISSUE_TYPE_NAME}' via create "
            "metadata, sample issue, or project issue-type scheme. Re-run with "
            "--sample-test-result RHELTEST-XXXX pointing at a real Test Result.",
            file=sys.stderr,
        )
        return 1
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
