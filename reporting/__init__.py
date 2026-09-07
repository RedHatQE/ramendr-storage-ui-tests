"""Jira Test Result reporting for RamenDR UI/sanity automation.

Phase A scope only: read-only Jira Cloud REST API v3 access used for
production schema discovery (see ``scripts/jira/discover_test_result_schema.py``
and ``docs/jira-test-result-reporting.md``). Nothing in this package performs
Jira writes (issue creation or workflow transitions) yet.
"""

__version__ = "0.1.0"
