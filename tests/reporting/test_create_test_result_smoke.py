"""Unit tests for scripts/jira/create_test_result_smoke.py.

Jira is always mocked (a fake JiraClient class is injected); no test in
this file allows a real network call or a real Jira write.
"""

from __future__ import annotations

import importlib.util
import json
from pathlib import Path

import pytest

_HELPER = (
    Path(__file__).resolve().parents[2]
    / "scripts"
    / "jira"
    / "create_test_result_smoke.py"
)
_spec = importlib.util.spec_from_file_location("create_test_result_smoke", _HELPER)
assert _spec is not None and _spec.loader is not None
smoke = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(smoke)

_TOKEN = "TOP-SECRET-TOKEN-do-not-leak"


class FakeSmokeClient:
    """Fake JiraClient injected in place of scripts.jira.create_test_result_smoke.JiraClient.

    Realistic enough to exercise the CLI's post-creation verification: the
    created issue's ``get_issue`` reflects whatever ``fields`` were actually
    sent to ``create_issue`` (parent/labels/Compose Version), and its status
    advances once ``transition_issue`` is called -- so a test can assert on
    a *final* status that differs from the initial one, same as real Jira.
    """

    _CREATED_KEY = "RHELTEST-9001"
    _TRANSITION_STATUS_NAMES = {"2": "New", "3": "PASS", "4": "FAIL", "5": "Blocked"}

    def __init__(self, config):
        self.config = config
        self.calls: list[str] = []
        self.created_fields: dict | None = None
        self.transitioned: tuple[str, str] | None = None
        self._status_name = "New"

    def get_issue(self, issue_key, *, expand=None):
        self.calls.append("get_issue")
        if issue_key == self._CREATED_KEY and self.created_fields is not None:
            fields = self.created_fields
            custom_fields = {
                k: v for k, v in fields.items() if k.startswith("customfield_")
            }
            return {
                "fields": {
                    "status": {"name": self._status_name},
                    "parent": fields.get("parent", {}),
                    "labels": fields.get("labels", []),
                    **custom_fields,
                }
            }
        return {
            "fields": {
                "project": {"key": "RHELTEST"},
                "issuetype": {"name": "Test Case"},
                "labels": ["ramen-dr"],
                "status": {"name": "New"},
            }
        }

    def get_transitions(self, issue_key):
        self.calls.append("get_transitions")
        return [
            {"id": "2", "name": "New"},
            {"id": "3", "name": "PASS"},
            {"id": "4", "name": "FAIL"},
            {"id": "5", "name": "Blocked"},
        ]

    def create_issue(self, fields):
        self.calls.append("create_issue")
        self.created_fields = fields
        return self._CREATED_KEY

    def transition_issue(self, issue_key, transition_id):
        self.calls.append("transition_issue")
        self.transitioned = (issue_key, str(transition_id))
        self._status_name = self._TRANSITION_STATUS_NAMES.get(
            str(transition_id), self._status_name
        )

    def search_issues(self, jql, *, max_results=10, fields=None):
        self.calls.append("search_issues")
        if self.created_fields is not None and f'"{self._CREATED_KEY}"' in jql:
            return [{"key": self._CREATED_KEY, "fields": {}}]
        return []


class ExplodingClient:
    """Would raise if ever constructed/used -- proves a code path never touches Jira."""

    def __init__(self, config):
        raise AssertionError("JiraClient must not be constructed on this code path")


_BASE_ARGV = [
    "--test-case",
    "failover_primary_to_secondary",
    "--scenario",
    "Failover primary to secondary",
    "--outcome",
    "PASS",
    "--compose",
    "RHEL-9.8.0",
    "--run-id",
    "demo-run-001",
]


def _clear_jira_env(monkeypatch):
    for name in (
        "JIRA_REPORT_RESULTS",
        "JIRA_REPORT_DRY_RUN",
        "JIRA_REPORT_STRICT",
        "JIRA_BASE_URL",
        "JIRA_EMAIL",
        "JIRA_API_TOKEN",
        "JIRA_PROJECT_KEY",
        "RAMENDR_COMPOSE_VERSION",
        "JIRA_RUN_ID",
        "CI_JOB_URL",
        "GIT_COMMIT",
    ):
        monkeypatch.delenv(name, raising=False)


def test_dry_run_by_default_needs_no_credentials_and_makes_no_jira_calls(
    monkeypatch, capsys
):
    _clear_jira_env(monkeypatch)
    monkeypatch.setattr(smoke, "JiraClient", ExplodingClient)

    exit_code = smoke.main(_BASE_ARGV)

    assert exit_code == 0
    captured = capsys.readouterr()
    payload = json.loads(captured.out)
    assert payload["dry_run"] is True
    assert payload["skipped_reason"] == "reporting disabled (JIRA_REPORT_RESULTS=false)"
    assert payload["fields"]["parent"] == {"key": "RHELTEST-3600"}
    assert "DRY RUN" in captured.err


def test_example_dry_run_payload_for_rheltest_3600(monkeypatch, capsys):
    """This is the exact scenario used for the requested example payload."""
    _clear_jira_env(monkeypatch)
    monkeypatch.setattr(smoke, "JiraClient", ExplodingClient)

    exit_code = smoke.main(_BASE_ARGV)

    assert exit_code == 0
    payload = json.loads(capsys.readouterr().out)
    fields = payload["fields"]
    assert fields["project"] == {"key": "RHELTEST"}
    assert fields["issuetype"] == {"id": "10272"}
    assert fields["parent"] == {"key": "RHELTEST-3600"}
    assert fields["labels"] == ["ramen-dr", "automation"]
    assert fields["customfield_11500"] == "RHEL-9.8.0"
    assert (
        fields["summary"]
        == "Ramen DR | RHELTEST-3600 | Failover primary to secondary | RHEL-9.8.0 | demo-run-001"
    )


def test_reporting_enabled_but_dry_run_true_does_not_require_confirm(
    monkeypatch, capsys
):
    _clear_jira_env(monkeypatch)
    monkeypatch.setenv("JIRA_REPORT_RESULTS", "true")
    monkeypatch.setenv("JIRA_REPORT_DRY_RUN", "true")
    monkeypatch.setenv("JIRA_BASE_URL", "https://redhat.atlassian.net")
    monkeypatch.setenv("JIRA_EMAIL", "qe@example.com")
    monkeypatch.setenv("JIRA_API_TOKEN", _TOKEN)
    monkeypatch.setattr(smoke, "JiraClient", FakeSmokeClient)

    exit_code = smoke.main(_BASE_ARGV)

    assert exit_code == 0
    payload = json.loads(capsys.readouterr().out)
    assert payload["dry_run"] is True
    assert payload["issue_key"] is None
    assert payload["parent_validation"] == {
        "key": None,
        "project_key": "RHELTEST",
        "issuetype_name": "Test Case",
        "labels": ["ramen-dr"],
        "has_ramen_dr_label": True,
    }


def test_dry_run_prints_observed_parent_summary_even_when_validation_fails(
    monkeypatch, capsys
):
    class BadParentClient(FakeSmokeClient):
        def get_issue(self, issue_key, *, expand=None):
            self.calls.append("get_issue")
            return {
                "fields": {
                    "project": {"key": "RHELTEST"},
                    "issuetype": {"name": "Bug"},  # wrong type
                    "labels": ["ramen-dr"],
                }
            }

    _clear_jira_env(monkeypatch)
    monkeypatch.setenv("JIRA_REPORT_RESULTS", "true")
    monkeypatch.setenv("JIRA_REPORT_DRY_RUN", "true")
    monkeypatch.setenv("JIRA_BASE_URL", "https://redhat.atlassian.net")
    monkeypatch.setenv("JIRA_EMAIL", "qe@example.com")
    monkeypatch.setenv("JIRA_API_TOKEN", _TOKEN)
    monkeypatch.setattr(smoke, "JiraClient", BadParentClient)

    exit_code = smoke.main(_BASE_ARGV)

    assert exit_code == 1
    captured = capsys.readouterr()
    assert "failed validation" in captured.err
    assert '"issuetype_name": "Bug"' in captured.err


def test_dry_run_flag_forces_dry_run_even_if_env_says_otherwise(monkeypatch, capsys):
    _clear_jira_env(monkeypatch)
    monkeypatch.setenv("JIRA_REPORT_RESULTS", "true")
    monkeypatch.setenv("JIRA_REPORT_DRY_RUN", "false")
    monkeypatch.setenv("JIRA_BASE_URL", "https://redhat.atlassian.net")
    monkeypatch.setenv("JIRA_EMAIL", "qe@example.com")
    monkeypatch.setenv("JIRA_API_TOKEN", _TOKEN)
    monkeypatch.setattr(smoke, "JiraClient", FakeSmokeClient)

    exit_code = smoke.main(_BASE_ARGV + ["--dry-run"])

    assert exit_code == 0
    payload = json.loads(capsys.readouterr().out)
    assert payload["dry_run"] is True


def test_refuses_real_write_when_confirm_missing(monkeypatch, capsys):
    _clear_jira_env(monkeypatch)
    monkeypatch.setenv("JIRA_REPORT_RESULTS", "true")
    monkeypatch.setenv("JIRA_REPORT_DRY_RUN", "false")
    monkeypatch.setattr(smoke, "JiraClient", ExplodingClient)

    exit_code = smoke.main(_BASE_ARGV)  # no --confirm

    assert exit_code == 2
    captured = capsys.readouterr()
    assert "Refusing" in captured.err
    assert "--confirm" in captured.err


def test_refuses_real_write_when_reporting_disabled_even_with_confirm(
    monkeypatch, capsys
):
    """--confirm alone is never enough -- JIRA_REPORT_RESULTS must also be true."""
    _clear_jira_env(monkeypatch)
    monkeypatch.setattr(smoke, "JiraClient", ExplodingClient)

    exit_code = smoke.main(_BASE_ARGV + ["--confirm"])

    assert exit_code == 0  # falls through to a safe dry-run preview, not a write
    payload = json.loads(capsys.readouterr().out)
    assert payload["dry_run"] is True


def test_real_write_flow_when_all_three_gates_are_satisfied(monkeypatch, capsys):
    _clear_jira_env(monkeypatch)
    monkeypatch.setenv("JIRA_REPORT_RESULTS", "true")
    monkeypatch.setenv("JIRA_REPORT_DRY_RUN", "false")
    monkeypatch.setenv("JIRA_BASE_URL", "https://redhat.atlassian.net")
    monkeypatch.setenv("JIRA_EMAIL", "qe@example.com")
    monkeypatch.setenv("JIRA_API_TOKEN", _TOKEN)

    created_client_holder: dict = {}

    def _factory(config):
        client = FakeSmokeClient(config)
        created_client_holder["client"] = client
        return client

    monkeypatch.setattr(smoke, "JiraClient", _factory)

    exit_code = smoke.main(_BASE_ARGV + ["--confirm"])

    assert exit_code == 0
    captured = capsys.readouterr()
    payload = json.loads(captured.out)
    assert payload["dry_run"] is False
    assert payload["issue_key"] == "RHELTEST-9001"
    assert payload["initial_status"] == "New"
    assert payload["final_status"] == "PASS"  # transition 3 applied and re-observed
    assert payload["transition_id_used"] == "3"  # PASS
    verification = payload["post_creation_verification"]
    assert verification["parent_key"] == "RHELTEST-3600"
    assert verification["parent_matches_expected"] is True
    assert verification["labels_match_expected"] is True
    assert verification["compose_value"] == "RHEL-9.8.0"
    assert verification["compose_absent_as_expected"] is True
    client = created_client_holder["client"]
    assert "create_issue" in client.calls
    assert "transition_issue" in client.calls
    assert "search_issues" in client.calls
    assert "FOUND" in captured.err


@pytest.mark.parametrize(
    ("outcome", "expected_transition_id"),
    [("PASS", "3"), ("FAIL", "4"), ("BLOCKED", "5")],
)
def test_real_write_flow_selects_correct_transition_per_outcome(
    monkeypatch, capsys, outcome, expected_transition_id
):
    _clear_jira_env(monkeypatch)
    monkeypatch.setenv("JIRA_REPORT_RESULTS", "true")
    monkeypatch.setenv("JIRA_REPORT_DRY_RUN", "false")
    monkeypatch.setenv("JIRA_BASE_URL", "https://redhat.atlassian.net")
    monkeypatch.setenv("JIRA_EMAIL", "qe@example.com")
    monkeypatch.setenv("JIRA_API_TOKEN", _TOKEN)
    monkeypatch.setattr(smoke, "JiraClient", FakeSmokeClient)

    argv = [a for a in _BASE_ARGV]
    argv[argv.index("PASS")] = outcome

    exit_code = smoke.main(argv + ["--confirm"])

    assert exit_code == 0
    payload = json.loads(capsys.readouterr().out)
    assert payload["transition_id_used"] == expected_transition_id


def test_real_write_flow_with_no_compose_omits_field_and_verifies_absence(
    monkeypatch, capsys
):
    """The exact shape of the planned production pilot: --compose is omitted."""
    _clear_jira_env(monkeypatch)
    monkeypatch.setenv("JIRA_REPORT_RESULTS", "true")
    monkeypatch.setenv("JIRA_REPORT_DRY_RUN", "false")
    monkeypatch.setenv("JIRA_BASE_URL", "https://redhat.atlassian.net")
    monkeypatch.setenv("JIRA_EMAIL", "qe@example.com")
    monkeypatch.setenv("JIRA_API_TOKEN", _TOKEN)
    monkeypatch.setattr(smoke, "JiraClient", FakeSmokeClient)

    argv = [a for a in _BASE_ARGV if a not in ("--compose", "RHEL-9.8.0")]

    exit_code = smoke.main(argv + ["--confirm"])

    assert exit_code == 0
    payload = json.loads(capsys.readouterr().out)
    assert "customfield_11500" not in payload["fields"]
    assert payload["fields"]["summary"] == (
        "Ramen DR | RHELTEST-3600 | Failover primary to secondary | "
        "not-supplied | demo-run-001"
    )
    assert "Compose Version: not supplied" in json.dumps(
        payload["fields"]["description"]
    )
    verification = payload["post_creation_verification"]
    assert verification["compose_value"] is None
    assert verification["compose_absent_as_expected"] is True


def test_search_visibility_check_failure_does_not_fail_the_run(monkeypatch, capsys):
    """A failed post-write search check is non-fatal: the write already succeeded."""

    class SearchFailsClient(FakeSmokeClient):
        def search_issues(self, jql, *, max_results=10, fields=None):
            self.calls.append("search_issues")
            from reporting.jira_client import JiraClientError

            raise JiraClientError("search temporarily unavailable")

    _clear_jira_env(monkeypatch)
    monkeypatch.setenv("JIRA_REPORT_RESULTS", "true")
    monkeypatch.setenv("JIRA_REPORT_DRY_RUN", "false")
    monkeypatch.setenv("JIRA_BASE_URL", "https://redhat.atlassian.net")
    monkeypatch.setenv("JIRA_EMAIL", "qe@example.com")
    monkeypatch.setenv("JIRA_API_TOKEN", _TOKEN)
    monkeypatch.setattr(smoke, "JiraClient", SearchFailsClient)

    exit_code = smoke.main(_BASE_ARGV + ["--confirm"])

    assert exit_code == 0  # the write itself succeeded; only the extra check failed
    captured = capsys.readouterr()
    assert json.loads(captured.out)["issue_key"] == "RHELTEST-9001"
    assert "Search-index visibility check failed (non-fatal" in captured.err


def test_unapproved_test_case_is_rejected_by_argparse(monkeypatch):
    _clear_jira_env(monkeypatch)
    argv = [a for a in _BASE_ARGV]
    argv[argv.index("failover_primary_to_secondary")] = "some_unapproved_scenario"
    with pytest.raises(SystemExit) as exc_info:
        smoke.main(argv)
    assert exc_info.value.code == 2


def test_never_logs_credentials_on_any_code_path(monkeypatch, capsys):
    _clear_jira_env(monkeypatch)
    monkeypatch.setenv("JIRA_REPORT_RESULTS", "true")
    monkeypatch.setenv("JIRA_REPORT_DRY_RUN", "false")
    monkeypatch.setenv("JIRA_BASE_URL", "https://redhat.atlassian.net")
    monkeypatch.setenv("JIRA_EMAIL", "qe@example.com")
    monkeypatch.setenv("JIRA_API_TOKEN", _TOKEN)
    monkeypatch.setattr(smoke, "JiraClient", FakeSmokeClient)

    smoke.main(_BASE_ARGV + ["--confirm"])

    captured = capsys.readouterr()
    assert _TOKEN not in captured.out
    assert _TOKEN not in captured.err
