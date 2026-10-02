"""Shared fixtures for tests/reporting/."""

from __future__ import annotations

import pytest

from reporting.jira_results import _generated_run_id


@pytest.fixture(autouse=True)
def _isolated_session_run_id_cache():
    """Clear reporting.jira_results' process-wide fallback run id cache
    before and after every test in this directory.

    Without this, one test exercising the no-``$JIRA_RUN_ID``-set fallback
    path (``get_session_run_id()``) could leak its generated id into a
    later, unrelated test's assertions -- the cache is deliberately
    process-wide (see its docstring) so it must be cleared at test
    boundaries here.
    """
    _generated_run_id.cache_clear()
    yield
    _generated_run_id.cache_clear()
