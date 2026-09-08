"""Jira Test Result reporting for RamenDR UI/sanity automation.

Jira Cloud REST API v3 access for RamenDR Test Result reporting, covering
both read-only schema discovery (see
``scripts/jira/discover_test_result_schema.py`` and
``docs/jira-test-result-reporting.md``) and gated write support.

``reporting.jira_client.JiraClient`` exposes two write operations,
``create_issue()`` and ``transition_issue()``, and
``reporting.jira_results.report_test_result()`` (used by
``tests/ui/sanity/test_sanity.py`` and
``scripts/jira/create_test_result_smoke.py``) may invoke them -- but only
when every safety gate is enabled: ``JIRA_REPORT_RESULTS=true`` and
``JIRA_REPORT_DRY_RUN=false`` (plus ``--confirm`` for the CLI). With any
gate left at its default, this package makes zero Jira writes -- see
``docs/jira-test-result-reporting.md`` for the full gating contract.
"""

__version__ = "0.1.0"
