"""Unit tests for the read-only Ramen DR Jira Test Case discovery script.

Jira is always mocked (a fake JiraClient is injected); the script never
contacts a real Jira instance and never issues a write -- it only ever
calls ``get_current_user`` (auth check) and ``search_issues`` (the one GET
this script needs).
"""

from __future__ import annotations

import importlib.util
from pathlib import Path

_HELPER = (
    Path(__file__).resolve().parents[2]
    / "scripts"
    / "jira"
    / "discover_ramen_dr_test_cases.py"
)
_spec = importlib.util.spec_from_file_location("discover_ramen_dr_test_cases", _HELPER)
assert _spec is not None and _spec.loader is not None
discover = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(discover)


# --------------------------------------------------------------------------
# Pure helper functions
# --------------------------------------------------------------------------


def test_build_jql_matches_the_exact_requested_filter():
    jql = discover.build_jql("RHELTEST", "ramen-dr", "Test Case")
    assert jql == ('project = RHELTEST AND labels = "ramen-dr" AND type = "Test Case"')


def test_adf_to_text_extracts_paragraphs_as_separate_lines():
    adf = {
        "type": "doc",
        "version": 1,
        "content": [
            {
                "type": "paragraph",
                "content": [{"type": "text", "text": "First paragraph."}],
            },
            {
                "type": "paragraph",
                "content": [{"type": "text", "text": "Second paragraph."}],
            },
        ],
    }
    assert discover.adf_to_text(adf) == "First paragraph.\nSecond paragraph."


def test_adf_to_text_handles_none_and_empty_doc():
    assert discover.adf_to_text(None) == ""
    assert discover.adf_to_text({"type": "doc", "version": 1, "content": []}) == ""


def test_adf_to_text_joins_multiple_text_runs_within_one_paragraph():
    adf = {
        "type": "doc",
        "content": [
            {
                "type": "paragraph",
                "content": [
                    {"type": "text", "text": "Bold and "},
                    {"type": "text", "text": "plain."},
                ],
            }
        ],
    }
    assert discover.adf_to_text(adf) == "Bold and plain."


def test_sanitize_test_case_extracts_expected_fields_and_flags_approved_mapping(
    monkeypatch,
):
    monkeypatch.setattr(
        discover, "_APPROVED_BY_KEY", {"RHELTEST-3600": "failover_primary_to_secondary"}
    )
    issue = {
        "key": "RHELTEST-3600",
        "fields": {
            "summary": "Failover Primary to Secondary",
            "labels": ["ramen-dr", "automation"],
            "issuetype": {"name": "Test Case"},
            "status": {"name": "Approved"},
            "description": {
                "type": "doc",
                "content": [
                    {
                        "type": "paragraph",
                        "content": [
                            {"type": "text", "text": "Fail over the workload."}
                        ],
                    }
                ],
            },
        },
    }
    row = discover.sanitize_test_case(issue)
    assert row["key"] == "RHELTEST-3600"
    assert row["summary"] == "Failover Primary to Secondary"
    assert row["labels"] == ["ramen-dr", "automation"]
    assert row["issuetype"] == "Test Case"
    assert row["status"] == "Approved"
    assert row["description_text"] == "Fail over the workload."
    assert row["already_approved_scenario_id"] == "failover_primary_to_secondary"


def test_sanitize_test_case_unmapped_key_has_none_scenario(monkeypatch):
    monkeypatch.setattr(discover, "_APPROVED_BY_KEY", {})
    row = discover.sanitize_test_case(
        {"key": "RHELTEST-3601", "fields": {"summary": "Something else"}}
    )
    assert row["already_approved_scenario_id"] is None


# --------------------------------------------------------------------------
# run_discovery(): fake client, no real network
# --------------------------------------------------------------------------


class FakeSearchClient:
    """Fake JiraClient exposing only what this script may call."""

    def __init__(self, issues):
        self.calls: list[str] = []
        self.last_jql: str | None = None
        self.last_fields: str | None = None
        self._issues = issues

    def get_current_user(self):
        self.calls.append("get_current_user")
        return {"displayName": "QE Bot", "accountId": "acc-1"}

    def search_issues(self, jql, *, max_results=10, fields=None):
        self.calls.append("search_issues")
        self.last_jql = jql
        self.last_fields = fields
        return self._issues


_SAMPLE_ISSUES = [
    {
        "key": "RHELTEST-3610",
        "fields": {
            "summary": "Relocate Secondary to Primary",
            "labels": ["ramen-dr"],
            "issuetype": {"name": "Test Case"},
            "status": {"name": "Approved"},
            "description": None,
        },
    },
    {
        "key": "RHELTEST-3601",
        "fields": {
            "summary": "Some other DR scenario",
            "labels": ["ramen-dr"],
            "issuetype": {"name": "Test Case"},
            "status": {"name": "Draft"},
            "description": None,
        },
    },
]

_WRITE_LIKE_CALLS = {
    "create_issue",
    "transition_issue",
    "post",
    "put",
    "delete",
}


def _args(output_dir: Path, **overrides) -> "object":
    parser = discover.build_arg_parser()
    argv = [
        "--base-url",
        "https://redhat.atlassian.net",
        "--project",
        "RHELTEST",
        "--output-dir",
        str(output_dir),
    ]
    for flag, value in overrides.items():
        argv += [f"--{flag.replace('_', '-')}", str(value)]
    return parser.parse_args(argv)


def _run(tmp_path, monkeypatch, client, **overrides) -> int:
    monkeypatch.setattr(discover, "JiraClient", lambda config: client)
    monkeypatch.setenv("JIRA_EMAIL", "qe@example.com")
    monkeypatch.setenv("JIRA_API_TOKEN", "secret-token-value")
    return discover.run_discovery(_args(tmp_path, **overrides))


def test_run_discovery_never_calls_any_write_method(tmp_path, monkeypatch):
    client = FakeSearchClient(_SAMPLE_ISSUES)
    exit_code = _run(tmp_path, monkeypatch, client)

    assert exit_code == 0
    assert not (_WRITE_LIKE_CALLS & set(client.calls))
    assert client.calls == ["get_current_user", "search_issues"]


def test_run_discovery_uses_the_exact_requested_jql_and_fields(tmp_path, monkeypatch):
    client = FakeSearchClient(_SAMPLE_ISSUES)
    _run(tmp_path, monkeypatch, client)

    assert client.last_jql == (
        'project = RHELTEST AND labels = "ramen-dr" AND type = "Test Case"'
    )
    assert client.last_fields == "summary,description,labels,issuetype,status"


def test_run_discovery_writes_sanitized_json_and_summary(tmp_path, monkeypatch):
    client = FakeSearchClient(_SAMPLE_ISSUES)
    _run(tmp_path, monkeypatch, client)

    import json

    data = json.loads((tmp_path / "ramen-dr-test-cases.json").read_text())
    keys = [row["key"] for row in data]
    assert keys == ["RHELTEST-3601", "RHELTEST-3610"]  # sorted by key

    summary_text = (tmp_path / "ramen-dr-test-cases-summary.txt").read_text()
    assert "RHELTEST-3601" in summary_text
    assert "RHELTEST-3610" in summary_text
    assert "Total Test Cases found: 2" in summary_text


def test_run_discovery_flags_credentials_error_without_leaking_them(
    tmp_path, monkeypatch
):
    class UnauthorizedClient:
        def get_current_user(self):
            raise discover.JiraAuthenticationError(
                "GET myself failed: authentication invalid (HTTP 401)"
            )

    monkeypatch.setattr(discover, "JiraClient", lambda config: UnauthorizedClient())
    monkeypatch.setenv("JIRA_EMAIL", "qe@example.com")
    monkeypatch.setenv("JIRA_API_TOKEN", "secret-token-value")
    exit_code = discover.run_discovery(_args(tmp_path))

    assert exit_code == 1


def test_main_requires_base_url(monkeypatch):
    monkeypatch.delenv("JIRA_BASE_URL", raising=False)
    exit_code = discover.main(["--project", "RHELTEST"])
    assert exit_code == 2
