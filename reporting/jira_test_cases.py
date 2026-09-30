"""Approved Ramen DR automation scenario -> Jira Test Case key mapping.

Deliberately minimal: only scenarios explicitly approved after a real Jira
discovery pass (``scripts/jira/discover_ramen_dr_test_cases.py``, read-only
JQL search for ``project = RHELTEST AND labels = "ramen-dr" AND type = "Test
Case"``) are listed here. Do **not** add a Test Case until its key/summary
has actually been retrieved from Jira and matched against real automation --
adding one prematurely would let automation silently attach real Test
Results to a parent that was never validated.

Of the 13 Ramen DR Test Cases confirmed to exist in RHELTEST, 3 are mapped
so far:

- ``failover_primary_to_secondary`` -> RHELTEST-3600 and
  ``relocate_secondary_to_primary`` -> RHELTEST-3610: sanity's two
  independent DR scenario boundaries (one Jira Test Result per scenario per
  invocation; see ``reporting.jira_results.jira_test_case_result``).
- ``deployment_smoke_validation`` -> RHELTEST-3612: the aggregate of every
  applicable-for-the-active-variant ``tests/ui/smoke/test_smoke.py`` check
  (one Jira Test Result for the *whole* smoke suite per invocation -- PASS
  only if every applicable smoke test passed; see
  ``reporting.pytest_jira_plugin``'s ``jira_aggregate_test_case`` marker,
  not the per-test ``jira_test_case`` marker).

RHELTEST-3601 through RHELTEST-3611 (except RHELTEST-3610 above) are **not**
mapped yet -- confirmed via discovery to correspond to scenarios with no
current automation in this repo (e.g. repeated failover/failback cycles,
snapshots, hotplug disks, VMware-imported/migrated Windows, static
networks, dual-NIC Windows, failed-failover cleanup/retry). Do not map
these until real automation exists for them and each mapping is reviewed.
"""

from __future__ import annotations

#: scenario id (as used by --test-case / RamenDR automation, or by the
#: ``jira_test_case`` / ``jira_aggregate_test_case`` pytest markers) ->
#: Jira Test Case key.
RAMENDR_JIRA_TEST_CASES: dict[str, str] = {
    "failover_primary_to_secondary": "RHELTEST-3600",
    "relocate_secondary_to_primary": "RHELTEST-3610",
    "deployment_smoke_validation": "RHELTEST-3612",
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
