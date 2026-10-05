"""Unit tests for reporting.jira_test_cases."""

from __future__ import annotations

import pytest

from reporting.jira_test_cases import RAMENDR_JIRA_TEST_CASES, resolve_test_case_key


def test_only_three_approved_mappings_exist():
    """Guard against accidentally adding one of the other, un-reviewed Test
    Cases (RHELTEST-3601..3611 except 3610) early -- discovery confirmed 13
    Ramen DR Test Cases exist in RHELTEST total; only these 3 are approved."""
    assert RAMENDR_JIRA_TEST_CASES == {
        "failover_primary_to_secondary": "RHELTEST-3600",
        "relocate_secondary_to_primary": "RHELTEST-3610",
        "deployment_smoke_validation": "RHELTEST-3612",
    }


def test_resolve_test_case_key_success():
    assert resolve_test_case_key("failover_primary_to_secondary") == "RHELTEST-3600"
    assert resolve_test_case_key("relocate_secondary_to_primary") == "RHELTEST-3610"
    assert resolve_test_case_key("deployment_smoke_validation") == "RHELTEST-3612"


def test_resolve_test_case_key_raises_for_unapproved_scenario():
    with pytest.raises(KeyError) as exc_info:
        resolve_test_case_key("some_unapproved_scenario")
    message = str(exc_info.value)
    assert "some_unapproved_scenario" in message
    assert "not an approved" in message
