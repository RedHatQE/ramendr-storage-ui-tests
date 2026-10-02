"""Unit tests for reporting.jira_results: payload building, ADF, the
report_test_result dry-run/write orchestration, and the shared
report_scenario_outcome() policy.

Jira is always mocked (a fake client is injected); no network is ever used,
and no test in this file allows a real write to happen.
"""

from __future__ import annotations

from datetime import datetime, timezone

import pytest

from reporting.jira_config import reporting_config_from_env
from reporting.jira_models import TestOutcome, TestResultExecution
from reporting.jira_results import (
    build_description_adf,
    build_summary,
    build_test_result_fields,
    report_scenario_outcome,
    report_test_result,
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
        test_function="tests/ui/sanity/test_sanity.py::test_sanity_disaster_recovery_ui",
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
    assert "Scenario: Failover primary to secondary" in joined
    assert (
        "Test function: tests/ui/sanity/test_sanity.py::test_sanity_disaster_recovery_ui"
        in joined
    )
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


def test_adf_description_missing_test_function_renders_as_unknown():
    lines = _adf_lines(build_description_adf(_execution(test_function=None)))
    assert "Test function: unknown" in "\n".join(lines)


def test_adf_description_compose_not_shown_as_a_placeholder_value():
    """Compose Version isn't in the description at all (it's a dedicated
    custom field -- see build_test_result_fields) -- so a missing value
    must never surface a stale sample or placeholder there either."""
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
# report_test_result orchestration
# --------------------------------------------------------------------------


class FakeReportingClient:
    """Fake JiraClient for report_test_result tests. Records every call."""

    def __init__(self, *, created_key="RHELTEST-9001", fail_transition=False):
        self.calls: list[str] = []
        self._created_key = created_key
        self._fail_transition = fail_transition
        self.created_fields: dict | None = None
        self.transitioned: tuple[str, str] | None = None

    def create_issue(self, fields):
        self.calls.append("create_issue")
        self.created_fields = fields
        return self._created_key

    def transition_issue(self, issue_key, transition_id):
        self.calls.append("transition_issue")
        if self._fail_transition:
            raise RuntimeError("simulated transition failure")
        self.transitioned = (issue_key, str(transition_id))


_WRITE_CALLS = {"create_issue", "transition_issue"}


def test_report_test_result_skips_everything_when_reporting_disabled():
    config = reporting_config_from_env({"JIRA_REPORT_RESULTS": "false"})
    client = FakeReportingClient()

    result = report_test_result(_execution(), client=client, config=config)

    assert result.dry_run is True
    assert result.skipped_reason == "reporting disabled (JIRA_REPORT_RESULTS=false)"
    assert result.issue_key is None
    assert client.calls == []  # zero Jira calls -- reporting is fully off
    assert result.fields["parent"] == {"key": "RHELTEST-3600"}


def test_report_test_result_never_requires_a_client_when_reporting_disabled():
    config = reporting_config_from_env({"JIRA_REPORT_RESULTS": "false"})
    result = report_test_result(_execution(), client=None, config=config)
    assert result.dry_run is True


def test_report_test_result_dry_run_makes_zero_jira_calls():
    config = reporting_config_from_env(
        {"JIRA_REPORT_RESULTS": "true", "JIRA_REPORT_DRY_RUN": "true"}
    )
    client = FakeReportingClient()

    result = report_test_result(_execution(), client=client, config=config)

    assert result.dry_run is True
    assert result.skipped_reason == "dry-run (JIRA_REPORT_DRY_RUN=true)"
    assert result.issue_key is None
    assert client.calls == []


def test_report_test_result_dry_run_never_requires_a_client():
    """dry_run makes zero Jira calls, so it needs no client either -- only
    a real write (report_results and not dry_run) does."""
    config = reporting_config_from_env(
        {"JIRA_REPORT_RESULTS": "true", "JIRA_REPORT_DRY_RUN": "true"}
    )
    result = report_test_result(_execution(), client=None, config=config)
    assert result.dry_run is True


def test_report_test_result_requires_client_for_a_real_write():
    config = reporting_config_from_env(
        {"JIRA_REPORT_RESULTS": "true", "JIRA_REPORT_DRY_RUN": "false"}
    )
    with pytest.raises(ValueError):
        report_test_result(_execution(), client=None, config=config)


def test_report_test_result_full_write_flow_creates_then_transitions():
    config = reporting_config_from_env(
        {"JIRA_REPORT_RESULTS": "true", "JIRA_REPORT_DRY_RUN": "false"}
    )
    client = FakeReportingClient()

    result = report_test_result(
        _execution(outcome=TestOutcome.PASS), client=client, config=config
    )

    assert result.dry_run is False
    assert result.issue_key == "RHELTEST-9001"
    assert result.transition_id_used == "3"
    assert client.transitioned == ("RHELTEST-9001", "3")
    assert client.calls == ["create_issue", "transition_issue"]  # create first


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


def test_report_test_result_post_create_failure_includes_the_created_issue_key():
    """The issue is already created (and real) by the time transition_issue
    can fail -- every caller that only shows the exception text must still
    be able to find it, so the key must travel with the error, and the
    original exception must be preserved as the cause (never discarded)."""
    config = reporting_config_from_env(
        {"JIRA_REPORT_RESULTS": "true", "JIRA_REPORT_DRY_RUN": "false"}
    )
    client = FakeReportingClient(fail_transition=True)

    with pytest.raises(RuntimeError) as exc_info:
        report_test_result(
            _execution(outcome=TestOutcome.PASS), client=client, config=config
        )

    assert client.created_fields is not None  # the write genuinely happened
    assert "RHELTEST-9001" in str(exc_info.value)  # the real, created key
    assert exc_info.value.__cause__ is not None  # original exception preserved
    assert "simulated transition failure" in str(exc_info.value.__cause__)


# --------------------------------------------------------------------------
# report_scenario_outcome -- the one shared policy used by
# JiraScenarioReporter (sanity) and pytest_jira_plugin (smoke aggregate)
# --------------------------------------------------------------------------


def test_report_scenario_outcome_reports_pass():
    config = reporting_config_from_env(
        {"JIRA_REPORT_RESULTS": "true", "JIRA_REPORT_DRY_RUN": "false"}
    )
    client = FakeReportingClient()

    result = report_scenario_outcome(
        "failover_primary_to_secondary",
        "Failover primary to secondary",
        TestOutcome.PASS,
        run_id="run-1",
        client=client,
        config=config,
    )

    assert result.issue_key == "RHELTEST-9001"
    assert client.transitioned == ("RHELTEST-9001", "3")


def test_report_scenario_outcome_rejects_unapproved_scenario_but_does_not_raise():
    """An unapproved scenario_key must never be reported -- but (matching
    every other Jira-reporting-failure path) it is logged and swallowed,
    not allowed to crash the caller, unless raise_on_error=True."""
    config = reporting_config_from_env(
        {"JIRA_REPORT_RESULTS": "true", "JIRA_REPORT_DRY_RUN": "false"}
    )
    client = FakeReportingClient()

    result = report_scenario_outcome(
        "not_an_approved_scenario",
        "Some scenario",
        TestOutcome.PASS,
        run_id="run-1",
        client=client,
        config=config,
    )

    assert result is None
    assert client.calls == []


def test_report_scenario_outcome_raise_on_error_propagates_the_jira_failure():
    config = reporting_config_from_env(
        {"JIRA_REPORT_RESULTS": "true", "JIRA_REPORT_DRY_RUN": "false"}
    )
    client = FakeReportingClient(fail_transition=True)

    with pytest.raises(RuntimeError):
        report_scenario_outcome(
            "failover_primary_to_secondary",
            "Failover primary to secondary",
            TestOutcome.PASS,
            run_id="run-1",
            client=client,
            config=config,
            raise_on_error=True,
        )


def test_report_scenario_outcome_swallows_by_default():
    config = reporting_config_from_env(
        {"JIRA_REPORT_RESULTS": "true", "JIRA_REPORT_DRY_RUN": "false"}
    )
    client = FakeReportingClient(fail_transition=True)

    result = report_scenario_outcome(
        "failover_primary_to_secondary",
        "Failover primary to secondary",
        TestOutcome.PASS,
        run_id="run-1",
        client=client,
        config=config,
    )
    assert result is None
