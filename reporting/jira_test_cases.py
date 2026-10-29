"""Approved Ramen DR automation scenario -> Jira Test Case key mapping.

Deliberately minimal: only scenarios explicitly approved after confirming
the real Jira Test Case's key/summary (``project = VIRTDR AND labels =
"ramen-dr" AND type = "Test Case"``) match real automation are listed here.
Do **not** add a Test Case until that's been confirmed -- adding one
prematurely would let automation silently attach real Test Results to a
parent that was never validated.

Only 3 VIRTDR Test Cases are currently approved for automation:

- ``failover_primary_to_secondary`` -> VIRTDR-392 and
  ``relocate_secondary_to_primary`` -> VIRTDR-389: sanity's two
  independent DR scenario boundaries (one Jira Test Result per scenario per
  invocation; see ``reporting.jira_results.jira_test_case_result``).
- ``deployment_smoke_validation`` -> VIRTDR-391: the aggregate of every
  applicable-for-the-active-variant ``tests/ui/smoke/test_smoke.py`` check
  (one Jira Test Result for the *whole* smoke suite per invocation -- PASS
  only if every applicable smoke test passed; see
  ``reporting.pytest_jira_plugin``'s ``jira_aggregate_test_case`` marker).

All other VIRTDR Test Cases are intentionally **not** mapped until matching
automation exists in this repository and each mapping is reviewed.
"""

from __future__ import annotations

#: scenario id (as used by RamenDR automation, or by the
#: ``jira_aggregate_test_case`` pytest marker) -> Jira Test Case key.
RAMENDR_JIRA_TEST_CASES: dict[str, str] = {
    "failover_primary_to_secondary": "VIRTDR-392",
    "relocate_secondary_to_primary": "VIRTDR-389",
    "deployment_smoke_validation": "VIRTDR-391",
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
