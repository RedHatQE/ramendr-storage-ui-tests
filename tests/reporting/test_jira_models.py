"""Unit tests for reporting.jira_models."""

from __future__ import annotations

from datetime import datetime, timezone

import pytest

from reporting.jira_models import TestOutcome, TestResultExecution


def test_test_outcome_values():
    assert TestOutcome.PASS.value == "PASS"
    assert TestOutcome.FAIL.value == "FAIL"
    assert TestOutcome.BLOCKED.value == "BLOCKED"


def test_test_outcome_is_str_enum_usable_as_plain_string():
    assert TestOutcome.PASS == "PASS"
    assert f"{TestOutcome.FAIL}" in ("FAIL", "TestOutcome.FAIL")


def test_execution_requires_test_case_key():
    with pytest.raises(ValueError):
        TestResultExecution(
            test_case_key="",
            scenario="Failover",
            outcome=TestOutcome.PASS,
            run_id="run-1",
        )


def test_execution_requires_scenario():
    with pytest.raises(ValueError):
        TestResultExecution(
            test_case_key="RHELTEST-3600",
            scenario="",
            outcome=TestOutcome.PASS,
            run_id="run-1",
        )


def test_execution_requires_run_id():
    with pytest.raises(ValueError):
        TestResultExecution(
            test_case_key="RHELTEST-3600",
            scenario="Failover",
            outcome=TestOutcome.PASS,
            run_id="",
        )


def test_execution_rejects_non_test_outcome():
    with pytest.raises(ValueError):
        TestResultExecution(
            test_case_key="RHELTEST-3600",
            scenario="Failover",
            outcome="PASS",  # not a TestOutcome instance
            run_id="run-1",
        )


def test_execution_defaults_executed_at_to_now_utc():
    before = datetime.now(timezone.utc)
    execution = TestResultExecution(
        test_case_key="RHELTEST-3600",
        scenario="Failover",
        outcome=TestOutcome.PASS,
        run_id="run-1",
    )
    after = datetime.now(timezone.utc)
    assert before <= execution.executed_at <= after


def test_execution_optional_fields_default_to_none():
    execution = TestResultExecution(
        test_case_key="RHELTEST-3600",
        scenario="Failover",
        outcome=TestOutcome.PASS,
        run_id="run-1",
    )
    assert execution.compose_version is None
    assert execution.git_commit is None
    assert execution.ci_job_url is None
    assert execution.duration_seconds is None
    assert execution.failure_summary is None


def test_execution_is_frozen():
    execution = TestResultExecution(
        test_case_key="RHELTEST-3600",
        scenario="Failover",
        outcome=TestOutcome.PASS,
        run_id="run-1",
    )
    with pytest.raises(Exception):  # dataclasses.FrozenInstanceError
        execution.run_id = "changed"  # type: ignore[misc]
