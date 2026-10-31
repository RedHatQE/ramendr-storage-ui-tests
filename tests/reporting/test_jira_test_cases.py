"""Unit tests for reporting.jira_test_cases."""

from __future__ import annotations

import pytest

from reporting.jira_test_cases import RAMENDR_JIRA_TEST_CASES, resolve_test_case_key


def test_only_three_approved_mappings_exist():
    """Guard against accidentally adding one of the other, un-reviewed Test
    Cases early -- only these 3 VIRTDR Test Cases are approved."""
    assert RAMENDR_JIRA_TEST_CASES == {
        "failover_primary_to_secondary": "VIRTDR-392",
        "relocate_secondary_to_primary": "VIRTDR-389",
        "deployment_smoke_validation": "VIRTDR-391",
    }


def test_resolve_test_case_key_success():
    assert resolve_test_case_key("failover_primary_to_secondary") == "VIRTDR-392"
    assert resolve_test_case_key("relocate_secondary_to_primary") == "VIRTDR-389"
    assert resolve_test_case_key("deployment_smoke_validation") == "VIRTDR-391"


def test_resolve_test_case_key_raises_for_unapproved_scenario():
    with pytest.raises(KeyError) as exc_info:
        resolve_test_case_key("some_unapproved_scenario")
    message = str(exc_info.value)
    assert "some_unapproved_scenario" in message
    assert "not an approved" in message
