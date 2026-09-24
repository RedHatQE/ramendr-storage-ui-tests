"""Approved Ramen DR automation scenario -> Jira Test Case key mapping.

Deliberately minimal (Phase B/C pilot scope): only the two scenarios
explicitly approved for the initial Jira reporting pilot. Do **not** add the
remaining Test Cases here until each has been reviewed and approved --
adding one prematurely would let automation silently attach real Test
Results to a parent that hasn't been validated yet.
"""

from __future__ import annotations

#: scenario id (as used by --test-case / RamenDR automation) -> Jira Test Case key.
RAMENDR_JIRA_TEST_CASES: dict[str, str] = {
    "failover_primary_to_secondary": "RHELTEST-3600",
    "relocate_secondary_to_primary": "RHELTEST-3610",
}


def resolve_test_case_key(scenario_id: str) -> str:
    """Look up the approved Jira Test Case key for a scenario id.

    Raises ``KeyError`` naming the scenario id (never any Jira credential)
    if the scenario has not been explicitly approved yet.
    """
    try:
        return RAMENDR_JIRA_TEST_CASES[scenario_id]
    except KeyError as exc:
        approved = ", ".join(sorted(RAMENDR_JIRA_TEST_CASES))
        raise KeyError(
            f"{scenario_id!r} is not an approved Ramen DR Jira Test Case mapping. "
            f"Approved scenario ids: {approved}"
        ) from exc
