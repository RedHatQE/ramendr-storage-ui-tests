"""Jira Test Result reporting for RamenDR UI/sanity automation.

A thin, intentionally minimal integration: a static scenario -> Jira Test
Case key map (``reporting.jira_test_cases``), a thin Jira Cloud REST API v3
client with exactly two write operations -- ``create_issue()`` and
``transition_issue()`` (``reporting.jira_client``) -- and the payload-
building/orchestration that calls them (``reporting.jira_results``).

**Opt-in by default:** ``JIRA_REPORT_RESULTS`` defaults to ``false`` and
``JIRA_REPORT_DRY_RUN`` defaults to ``true`` -- an ordinary ``pytest`` run
(sanity or smoke) makes zero Jira calls and needs zero credentials unless
reporting is explicitly turned on via the environment/CI secret store.

See ``docs/jira-test-result-reporting.md`` for the full gating contract.
"""

__version__ = "0.1.0"
