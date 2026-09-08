"""Unit tests for reporting.jira_config."""

from __future__ import annotations

import pytest

from reporting.jira_config import reporting_config_from_env
from reporting.jira_models import TestOutcome


def test_defaults_are_maximally_safe_when_env_is_empty():
    config = reporting_config_from_env({})
    assert config.report_results is False
    assert config.dry_run is True
    assert config.strict is False


def test_defaults_match_phase_a_discovered_production_schema():
    config = reporting_config_from_env({})
    assert config.project_key == "RHELTEST"
    assert config.test_result_issue_type_id == "10272"
    assert config.compose_version_field_id == "customfield_11500"
    assert config.pass_transition_id == "3"
    assert config.fail_transition_id == "4"
    assert config.blocked_transition_id == "5"


def test_env_overrides_every_flag_and_id():
    config = reporting_config_from_env(
        {
            "JIRA_REPORT_RESULTS": "true",
            "JIRA_REPORT_DRY_RUN": "false",
            "JIRA_REPORT_STRICT": "true",
            "JIRA_PROJECT_KEY": "OTHERPROJ",
            "JIRA_TEST_RESULT_ISSUE_TYPE_ID": "99999",
            "JIRA_COMPOSE_VERSION_FIELD_ID": "customfield_99999",
            "JIRA_PASS_TRANSITION_ID": "31",
            "JIRA_FAIL_TRANSITION_ID": "41",
            "JIRA_BLOCKED_TRANSITION_ID": "51",
            "RAMENDR_COMPOSE_VERSION": "RHEL-9.9.0",
            "JIRA_RUN_ID": "run-123",
            "CI_JOB_URL": "https://ci.example.com/job/1",
            "GIT_COMMIT": "abc1234",
        }
    )
    assert config.report_results is True
    assert config.dry_run is False
    assert config.strict is True
    assert config.project_key == "OTHERPROJ"
    assert config.test_result_issue_type_id == "99999"
    assert config.compose_version_field_id == "customfield_99999"
    assert config.pass_transition_id == "31"
    assert config.fail_transition_id == "41"
    assert config.blocked_transition_id == "51"
    assert config.compose_version == "RHEL-9.9.0"
    assert config.run_id == "run-123"
    assert config.ci_job_url == "https://ci.example.com/job/1"
    assert config.git_commit == "abc1234"


def test_bool_env_accepts_common_truthy_spellings():
    for value in ("1", "true", "True", "TRUE", "yes", "on"):
        config = reporting_config_from_env({"JIRA_REPORT_RESULTS": value})
        assert config.report_results is True, f"{value!r} should be truthy"


def test_bool_env_accepts_common_falsy_spellings():
    for value in ("0", "false", "False", "FALSE", "no", "off"):
        config = reporting_config_from_env({"JIRA_REPORT_RESULTS": value})
        assert config.report_results is False, f"{value!r} should be falsy"


def test_bool_env_raises_on_unrecognized_value_instead_of_silently_falsy():
    """An unrecognized value (typo or garbage) must never be silently coerced
    to False -- for a safety flag like JIRA_REPORT_DRY_RUN (default True),
    that would silently disable a write-safety gate. It must raise instead,
    preserving the safe default rather than guessing."""
    for value in ("garbage", "ture"):
        with pytest.raises(ValueError, match=value):
            reporting_config_from_env({"JIRA_REPORT_RESULTS": value})
        with pytest.raises(ValueError, match=value):
            reporting_config_from_env({"JIRA_REPORT_DRY_RUN": value})


def test_transition_id_for_maps_each_outcome():
    config = reporting_config_from_env(
        {
            "JIRA_PASS_TRANSITION_ID": "3",
            "JIRA_FAIL_TRANSITION_ID": "4",
            "JIRA_BLOCKED_TRANSITION_ID": "5",
        }
    )
    assert config.transition_id_for(TestOutcome.PASS) == "3"
    assert config.transition_id_for(TestOutcome.FAIL) == "4"
    assert config.transition_id_for(TestOutcome.BLOCKED) == "5"


def test_transition_id_for_reflects_custom_overrides():
    config = reporting_config_from_env(
        {
            "JIRA_PASS_TRANSITION_ID": "31",
            "JIRA_FAIL_TRANSITION_ID": "41",
            "JIRA_BLOCKED_TRANSITION_ID": "51",
        }
    )
    assert config.transition_id_for(TestOutcome.PASS) == "31"
    assert config.transition_id_for(TestOutcome.FAIL) == "41"
    assert config.transition_id_for(TestOutcome.BLOCKED) == "51"
