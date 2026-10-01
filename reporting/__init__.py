"""Jira Test Result reporting for RamenDR UI/sanity automation.

Jira Cloud REST API v3 access for RamenDR Test Result reporting, covering
both read-only schema discovery (see
``scripts/jira/discover_test_result_schema.py`` and
``docs/jira-test-result-reporting.md``) and gated write support.

``reporting.jira_client.JiraClient`` exposes two write operations,
``create_issue()`` and ``transition_issue()``, and
``reporting.jira_results.report_test_result()`` (used by
``tests/ui/sanity/test_sanity.py``, ``reporting.pytest_jira_plugin``, and
``scripts/jira/create_test_result_smoke.py``) invokes them when
``config.report_results`` is True and ``config.dry_run`` is False.

**pytest callers** (sanity, smoke): both default to the write-enabled state
(``JIRA_REPORT_RESULTS=true``, ``JIRA_REPORT_DRY_RUN=false``) -- an ordinary
test run writes to Jira whenever credentials are present. Set
``JIRA_REPORT_RESULTS=false`` or ``JIRA_REPORT_DRY_RUN=true`` to prevent
writes (e.g. for local development without touching real Jira data).

**The CLI** (``scripts/jira/create_test_result_smoke.py``) is the opposite:
it restores write-safe defaults for itself and additionally requires
``--confirm`` before any real write, regardless of the environment.

See ``docs/jira-test-result-reporting.md`` for the full gating contract.
"""

__version__ = "0.1.0"
