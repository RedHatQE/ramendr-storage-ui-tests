"""Unit tests for reporting.jira_results: payload building, ADF, parent
validation, and the report_test_result dry-run/write orchestration.

Jira is always mocked (a fake client is injected); no network is ever used,
and no test in this file allows a real write to happen.
"""

from __future__ import annotations

from datetime import datetime, timezone

import pytest

from reporting.jira_client import JiraClientError
from reporting.jira_config import reporting_config_from_env
from reporting.jira_models import TestOutcome, TestResultExecution
from reporting.jira_results import (
    ParentValidationError,
    build_description_adf,
    build_summary,
    build_test_result_fields,
    report_test_result,
    summarize_parent,
    validate_parent_test_case,
)

_EXECUTED_AT = datetime(2026, 9, 7, 12, 0, 0, tzinfo=timezone.utc)


def _execution(**overrides) -> TestResultExecution:
    defaults = dict(
        test_case_key="RHELTEST-3600",
        scenario="Failover primary to secondary",
        outcome=TestOutcome.PASS,
        run_id="run-42",
        executed_at=_EXECUTED_AT,
        compose_version="RHEL-9.8.0",
        git_commit="abc1234",
        ci_job_url="https://ci.example.com/job/1",
    )
    defaults.update(overrides)
    return TestResultExecution(**defaults)


# --------------------------------------------------------------------------
# Summary
# --------------------------------------------------------------------------


def test_build_summary_matches_spec_format():
    summary = build_summary(
        "RHELTEST-3600", "Failover primary to secondary", "RHEL-9.8.0", "run-42"
    )
    assert (
        summary
        == "Ramen DR | RHELTEST-3600 | Failover primary to secondary | RHEL-9.8.0 | run-42"
    )


def test_build_summary_omits_compose_and_never_fabricates_a_value():
    """No stale sample value, no TEST-COMPOSE-*-style placeholder -- just a
    clear, unmistakable 'not-supplied' token."""
    summary = build_summary("RHELTEST-3600", "Failover", None, "run-42")
    assert summary == "Ramen DR | RHELTEST-3600 | Failover | not-supplied | run-42"
    assert "RHEL-9.8.0" not in summary
    assert "TEST-COMPOSE" not in summary


def test_build_summary_falls_back_to_not_supplied_for_empty_string_compose():
    summary = build_summary("RHELTEST-3600", "Failover", "", "run-42")
    assert summary == "Ramen DR | RHELTEST-3600 | Failover | not-supplied | run-42"


# --------------------------------------------------------------------------
# ADF description
# --------------------------------------------------------------------------


def test_adf_description_has_correct_document_shape():
    adf = build_description_adf(_execution())
    assert adf["type"] == "doc"
    assert adf["version"] == 1
    assert isinstance(adf["content"], list)
    for paragraph in adf["content"]:
        assert paragraph["type"] == "paragraph"
        assert paragraph["content"][0]["type"] == "text"


def _adf_lines(adf: dict) -> list[str]:
    return [p["content"][0]["text"] for p in adf["content"]]


def test_adf_description_contains_all_required_facts_for_pass():
    lines = _adf_lines(build_description_adf(_execution(outcome=TestOutcome.PASS)))
    joined = "\n".join(lines)
    assert "Automation: pytest + Playwright" in joined
    assert "Repository: ramendr-storage-ui-tests" in joined
    assert "Test Case: RHELTEST-3600" in joined
    assert "Scenario: Failover primary to secondary" in joined
    assert (
        "Test function: tests/ui/sanity/test_sanity.py::test_sanity_disaster_recovery_ui"
        in joined
    )
    assert "Compose Version: RHEL-9.8.0" in joined
    assert "Git commit: abc1234" in joined
    assert "CI run: https://ci.example.com/job/1" in joined
    assert "Run ID: run-42" in joined
    assert "Executed at: 2026-09-07T12:00:00Z" in joined
    assert "Outcome: PASS" in joined
    assert "Failure:" not in joined  # PASS must never carry a Failure line


def test_adf_description_includes_duration_only_when_known():
    without = _adf_lines(build_description_adf(_execution(duration_seconds=None)))
    assert not any(line.startswith("Duration:") for line in without)

    with_duration = _adf_lines(
        build_description_adf(_execution(duration_seconds=12.345))
    )
    assert any(line == "Duration: 12.3s" for line in with_duration)


def test_adf_description_includes_failure_line_for_fail_outcome():
    lines = _adf_lines(
        build_description_adf(
            _execution(
                outcome=TestOutcome.FAIL, failure_summary="assertion failed: x != y"
            )
        )
    )
    assert any(line == "Failure: assertion failed: x != y" for line in lines)


def test_adf_description_includes_failure_line_for_blocked_outcome():
    lines = _adf_lines(
        build_description_adf(
            _execution(
                outcome=TestOutcome.BLOCKED, failure_summary="dependency unavailable"
            )
        )
    )
    assert any(line == "Failure: dependency unavailable" for line in lines)


def test_adf_description_omits_failure_line_when_no_failure_summary_given():
    lines = _adf_lines(
        build_description_adf(
            _execution(outcome=TestOutcome.FAIL, failure_summary=None)
        )
    )
    assert not any(line.startswith("Failure:") for line in lines)


def test_adf_description_never_embeds_a_full_stack_trace():
    """Failure text must be collapsed to one line and hard-capped -- never a
    multi-line stack trace verbatim."""
    stack_trace = (
        "Traceback (most recent call last):\n"
        + "\n".join(f'  File "module_{i}.py", line {i}, in fn_{i}' for i in range(200))
        + "\nAssertionError: boom"
    )
    lines = _adf_lines(
        build_description_adf(
            _execution(outcome=TestOutcome.FAIL, failure_summary=stack_trace)
        )
    )
    failure_lines = [line for line in lines if line.startswith("Failure:")]
    assert len(failure_lines) == 1
    failure_line = failure_lines[0]
    assert "\n" not in failure_line
    assert len(failure_line) <= 500 + len("Failure: ")
    assert failure_line.endswith("...")


def test_adf_description_missing_optional_facts_render_as_unknown():
    lines = _adf_lines(
        build_description_adf(
            _execution(compose_version=None, git_commit=None, ci_job_url=None)
        )
    )
    joined = "\n".join(lines)
    # Compose Version gets its own distinct wording -- it's never fabricated
    # and must never be confused with a real (if merely unknown) value.
    assert "Compose Version: not supplied" in joined
    assert "Compose Version: unknown" not in joined
    assert "Git commit: unknown" in joined
    assert "CI run: unknown" in joined


def test_adf_description_compose_not_supplied_never_shows_a_placeholder_value():
    lines = _adf_lines(build_description_adf(_execution(compose_version=None)))
    joined = "\n".join(lines)
    assert "RHEL-9.8.0" not in joined
    assert "TEST-COMPOSE" not in joined


# --------------------------------------------------------------------------
# Field payload
# --------------------------------------------------------------------------


def test_build_test_result_fields_includes_all_mandatory_fields():
    config = reporting_config_from_env({})
    fields = build_test_result_fields(_execution(), config=config)

    assert fields["project"] == {"key": "RHELTEST"}
    assert fields["issuetype"] == {"id": "10272"}
    assert fields["parent"] == {"key": "RHELTEST-3600"}
    assert fields["labels"] == ["ramen-dr", "automation"]
    assert fields["summary"].startswith("Ramen DR | RHELTEST-3600 |")
    assert fields["description"]["type"] == "doc"
    assert fields["customfield_11500"] == "RHEL-9.8.0"


def test_build_test_result_fields_omits_compose_version_field_when_unknown():
    config = reporting_config_from_env({})
    fields = build_test_result_fields(_execution(compose_version=None), config=config)
    assert "customfield_11500" not in fields


def test_build_test_result_fields_labels_is_a_fresh_list_each_call():
    """Mutating one payload's labels must never affect another payload."""
    config = reporting_config_from_env({})
    fields_a = build_test_result_fields(_execution(), config=config)
    fields_a["labels"].append("mutated")
    fields_b = build_test_result_fields(_execution(), config=config)
    assert fields_b["labels"] == ["ramen-dr", "automation"]


def test_build_test_result_fields_respects_custom_config_ids():
    config = reporting_config_from_env(
        {
            "JIRA_PROJECT_KEY": "OTHERPROJ",
            "JIRA_TEST_RESULT_ISSUE_TYPE_ID": "99999",
            "JIRA_COMPOSE_VERSION_FIELD_ID": "customfield_99999",
        }
    )
    fields = build_test_result_fields(_execution(), config=config)
    assert fields["project"] == {"key": "OTHERPROJ"}
    assert fields["issuetype"] == {"id": "99999"}
    assert fields["customfield_99999"] == "RHEL-9.8.0"


# --------------------------------------------------------------------------
# Parent validation
# --------------------------------------------------------------------------


def _valid_parent() -> dict:
    return {
        "key": "RHELTEST-3586",
        "fields": {
            "project": {"key": "RHELTEST"},
            "issuetype": {"name": "Test Case"},
            "labels": ["ramen-dr", "some-other-label"],
        },
    }


def test_validate_parent_test_case_accepts_a_valid_parent():
    validate_parent_test_case(_valid_parent(), expected_project_key="RHELTEST")


def test_validate_parent_test_case_rejects_wrong_project():
    parent = _valid_parent()
    parent["fields"]["project"]["key"] = "OTHERPROJ"
    with pytest.raises(ParentValidationError) as exc_info:
        validate_parent_test_case(parent, expected_project_key="RHELTEST")
    assert "OTHERPROJ" in str(exc_info.value)


def test_validate_parent_test_case_rejects_wrong_issue_type():
    parent = _valid_parent()
    parent["fields"]["issuetype"]["name"] = "Bug"
    with pytest.raises(ParentValidationError) as exc_info:
        validate_parent_test_case(parent, expected_project_key="RHELTEST")
    assert "Bug" in str(exc_info.value)


def test_validate_parent_test_case_rejects_missing_ramen_dr_label():
    parent = _valid_parent()
    parent["fields"]["labels"] = ["some-other-label"]
    with pytest.raises(ParentValidationError) as exc_info:
        validate_parent_test_case(parent, expected_project_key="RHELTEST")
    assert "ramen-dr" in str(exc_info.value)


def test_validate_parent_test_case_rejects_missing_fields_key():
    with pytest.raises(ParentValidationError):
        validate_parent_test_case(
            {"key": "RHELTEST-3586"}, expected_project_key="RHELTEST"
        )


def test_summarize_parent_extracts_expected_keys():
    summary = summarize_parent(_valid_parent())
    assert summary == {
        "key": "RHELTEST-3586",
        "project_key": "RHELTEST",
        "issuetype_name": "Test Case",
        "labels": ["ramen-dr", "some-other-label"],
        "has_ramen_dr_label": True,
    }


def test_summarize_parent_reports_missing_label():
    parent = _valid_parent()
    parent["fields"]["labels"] = ["unrelated"]
    summary = summarize_parent(parent)
    assert summary["has_ramen_dr_label"] is False


def test_summarize_parent_is_defensive_about_malformed_input():
    assert summarize_parent({}) == {
        "key": None,
        "project_key": None,
        "issuetype_name": None,
        "labels": [],
        "has_ramen_dr_label": False,
    }


# --------------------------------------------------------------------------
# report_test_result orchestration
# --------------------------------------------------------------------------


class FakeReportingClient:
    """Fake JiraClient for report_test_result tests. Records every call.

    The created issue's ``get_issue`` reflects whatever ``fields`` were
    actually passed to ``create_issue`` (parent/labels/Compose Version), and
    its status advances once ``transition_issue`` is called -- so tests can
    assert on a genuine before/after status change and on post-creation
    verification derived from a *fresh read*, same as real Jira.
    """

    _TRANSITION_STATUS_NAMES = {"2": "New", "3": "PASS", "4": "FAIL", "5": "Blocked"}

    def __init__(
        self,
        *,
        parent=None,
        transitions=None,
        created_key="RHELTEST-9001",
        status_name="New",
    ):
        self.calls: list[str] = []
        self._parent = parent if parent is not None else _valid_parent()
        self._transitions = (
            transitions
            if transitions is not None
            else [
                {"id": "2", "name": "New", "to": {"name": "New"}},
                {"id": "3", "name": "PASS", "to": {"name": "PASS"}},
                {"id": "4", "name": "FAIL", "to": {"name": "FAIL"}},
                {"id": "5", "name": "Blocked", "to": {"name": "Blocked"}},
            ]
        )
        self._created_key = created_key
        self._status_name = status_name
        self.created_fields: dict | None = None
        self.transitioned: tuple[str, str] | None = None

    def get_issue(self, issue_key, *, expand=None):
        self.calls.append("get_issue")
        if issue_key == self._created_key:
            fields = self.created_fields or {}
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
        return self._parent

    def get_transitions(self, issue_key):
        self.calls.append("get_transitions")
        return self._transitions

    def create_issue(self, fields):
        self.calls.append("create_issue")
        self.created_fields = fields
        return self._created_key

    def transition_issue(self, issue_key, transition_id):
        self.calls.append("transition_issue")
        self.transitioned = (issue_key, transition_id)
        self._status_name = self._TRANSITION_STATUS_NAMES.get(
            str(transition_id), self._status_name
        )


_WRITE_CALLS = {"create_issue", "transition_issue"}


def test_report_test_result_skips_everything_when_reporting_disabled():
    config = reporting_config_from_env({"JIRA_REPORT_RESULTS": "false"})
    client = FakeReportingClient()

    result = report_test_result(_execution(), client=client, config=config)

    assert result.dry_run is True
    assert result.skipped_reason == "reporting disabled (JIRA_REPORT_RESULTS=false)"
    assert result.issue_key is None
    assert client.calls == []  # not even a GET -- reporting is fully off
    assert result.fields["parent"] == {"key": "RHELTEST-3600"}


def test_report_test_result_never_requires_a_client_when_reporting_disabled():
    config = reporting_config_from_env({"JIRA_REPORT_RESULTS": "false"})
    result = report_test_result(_execution(), client=None, config=config)
    assert result.dry_run is True


def test_report_test_result_dry_run_validates_parent_but_makes_no_writes():
    config = reporting_config_from_env(
        {"JIRA_REPORT_RESULTS": "true", "JIRA_REPORT_DRY_RUN": "true"}
    )
    client = FakeReportingClient()

    result = report_test_result(_execution(), client=client, config=config)

    assert result.dry_run is True
    assert result.skipped_reason == "dry-run (JIRA_REPORT_DRY_RUN=true)"
    assert result.issue_key is None
    assert "get_issue" in client.calls  # parent WAS validated (read-only)
    assert not (_WRITE_CALLS & set(client.calls))  # but no write happened
    assert result.parent_summary == {
        "key": "RHELTEST-3586",
        "project_key": "RHELTEST",
        "issuetype_name": "Test Case",
        "labels": ["ramen-dr", "some-other-label"],
        "has_ramen_dr_label": True,
    }


def test_report_test_result_dry_run_still_raises_on_invalid_parent():
    config = reporting_config_from_env(
        {"JIRA_REPORT_RESULTS": "true", "JIRA_REPORT_DRY_RUN": "true"}
    )
    bad_parent = _valid_parent()
    bad_parent["fields"]["issuetype"]["name"] = "Bug"
    client = FakeReportingClient(parent=bad_parent)

    with pytest.raises(ParentValidationError) as exc_info:
        report_test_result(_execution(), client=client, config=config)
    assert not (_WRITE_CALLS & set(client.calls))
    # The observed (safe, non-secret) parent summary is attached even on failure.
    assert exc_info.value.parent_summary["issuetype_name"] == "Bug"


def test_report_test_result_requires_client_when_reporting_enabled():
    config = reporting_config_from_env({"JIRA_REPORT_RESULTS": "true"})
    with pytest.raises(ValueError):
        report_test_result(_execution(), client=None, config=config)


def test_report_test_result_full_write_flow_observes_status_before_transitioning():
    config = reporting_config_from_env(
        {"JIRA_REPORT_RESULTS": "true", "JIRA_REPORT_DRY_RUN": "false"}
    )
    client = FakeReportingClient(status_name="New")

    result = report_test_result(
        _execution(outcome=TestOutcome.PASS), client=client, config=config
    )

    assert result.dry_run is False
    assert result.issue_key == "RHELTEST-9001"
    assert result.initial_status == "New"  # observed, not assumed
    assert result.final_status == "PASS"  # re-observed after the transition
    assert result.transition_id_used == "3"
    assert client.transitioned == ("RHELTEST-9001", "3")
    assert result.parent_summary["has_ramen_dr_label"] is True
    # Order matters: create, then observe (get_issue + get_transitions), then
    # transition, then re-observe (a second get_issue) for the final status.
    assert client.calls.index("create_issue") < client.calls.index("get_transitions")
    assert client.calls.index("get_transitions") < client.calls.index(
        "transition_issue"
    )
    # 3 get_issue calls total: parent validation, post-create snapshot, and
    # the final re-fetch after transitioning.
    assert client.calls.count("get_issue") == 3
    last_get_issue_index = len(client.calls) - 1 - client.calls[::-1].index("get_issue")
    assert client.calls.index("transition_issue") < last_get_issue_index


def test_report_test_result_post_creation_verification_confirms_parent_and_labels():
    config = reporting_config_from_env(
        {"JIRA_REPORT_RESULTS": "true", "JIRA_REPORT_DRY_RUN": "false"}
    )
    client = FakeReportingClient()

    result = report_test_result(
        _execution(compose_version="RHEL-9.8.0"), client=client, config=config
    )

    assert result.post_creation_verification == {
        "parent_key": "RHELTEST-3600",
        "parent_matches_expected": True,
        "labels": ["ramen-dr", "automation"],
        "labels_match_expected": True,
        "compose_value": "RHEL-9.8.0",
        "compose_absent_as_expected": True,
    }


def test_report_test_result_post_creation_verification_confirms_compose_absent():
    """The pilot scenario: no compose supplied -- verification must confirm
    it is genuinely absent from a fresh read, not merely absent from what
    we sent."""
    config = reporting_config_from_env(
        {"JIRA_REPORT_RESULTS": "true", "JIRA_REPORT_DRY_RUN": "false"}
    )
    client = FakeReportingClient()

    result = report_test_result(
        _execution(compose_version=None), client=client, config=config
    )

    assert "customfield_11500" not in result.fields
    verification = result.post_creation_verification
    assert verification["compose_value"] is None
    assert verification["compose_absent_as_expected"] is True
    assert verification["parent_matches_expected"] is True
    assert verification["labels_match_expected"] is True


@pytest.mark.parametrize(
    ("outcome", "expected_transition_id"),
    [
        (TestOutcome.PASS, "3"),
        (TestOutcome.FAIL, "4"),
        (TestOutcome.BLOCKED, "5"),
    ],
)
def test_report_test_result_selects_correct_transition_per_outcome(
    outcome, expected_transition_id
):
    config = reporting_config_from_env(
        {"JIRA_REPORT_RESULTS": "true", "JIRA_REPORT_DRY_RUN": "false"}
    )
    client = FakeReportingClient()

    result = report_test_result(
        _execution(outcome=outcome), client=client, config=config
    )

    assert result.transition_id_used == expected_transition_id
    assert client.transitioned == ("RHELTEST-9001", expected_transition_id)


def test_report_test_result_refuses_transition_not_currently_available():
    """If the desired transition id isn't actually offered by the freshly
    created issue, refuse rather than blindly attempting it."""
    config = reporting_config_from_env(
        {"JIRA_REPORT_RESULTS": "true", "JIRA_REPORT_DRY_RUN": "false"}
    )
    client = FakeReportingClient(transitions=[{"id": "2", "name": "New"}])

    with pytest.raises(JiraClientError):
        report_test_result(
            _execution(outcome=TestOutcome.PASS), client=client, config=config
        )
    assert client.transitioned is None  # never attempted


def test_report_test_result_write_flow_validates_parent_first():
    config = reporting_config_from_env(
        {"JIRA_REPORT_RESULTS": "true", "JIRA_REPORT_DRY_RUN": "false"}
    )
    bad_parent = _valid_parent()
    bad_parent["fields"]["project"]["key"] = "OTHERPROJ"
    client = FakeReportingClient(parent=bad_parent)

    with pytest.raises(ParentValidationError):
        report_test_result(_execution(), client=client, config=config)
    assert not (_WRITE_CALLS & set(client.calls))
