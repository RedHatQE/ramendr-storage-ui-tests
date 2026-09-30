"""Unit tests for the Phase 2 "normal default" reporting behavior:

- reporting/dry-run defaults (see also tests/reporting/test_jira_config.py)
- reporting.jira_results.build_jira_client() -- fail-fast on missing
  credentials rather than a silent skip
- reporting.jira_results.get_session_run_id() -- one run id shared by every
  caller within one pytest process that didn't set $JIRA_RUN_ID explicitly

Jira is always mocked/never contacted for real; this module never performs
network I/O.
"""

from __future__ import annotations

import pytest

from reporting.jira_client import JiraClient
from reporting.jira_config import reporting_config_from_env
from reporting.jira_results import (
    JiraCredentialsUnavailableError,
    build_jira_client,
    derive_run_id,
    get_session_run_id,
)

_VALID_CREDENTIALS = {
    "JIRA_BASE_URL": "https://example.invalid",
    "JIRA_EMAIL": "test@example.invalid",
    "JIRA_API_TOKEN": "not-a-real-token",
}


# --------------------------------------------------------------------------
# build_jira_client() -- credentials fail-fast
# --------------------------------------------------------------------------


def test_build_jira_client_returns_none_when_reporting_explicitly_disabled():
    """An explicit local opt-out (JIRA_REPORT_RESULTS=false) needs no
    credentials at all -- this must never raise, even with none set."""
    config = reporting_config_from_env({"JIRA_REPORT_RESULTS": "false"})
    assert build_jira_client(config) is None


def test_build_jira_client_raises_clearly_when_enabled_but_credentials_missing():
    """Reporting enabled (the default) with no credentials must fail fast
    with a clear, actionable message -- never silently skip reporting."""
    config = reporting_config_from_env({})  # report_results defaults to True
    with pytest.raises(JiraCredentialsUnavailableError) as excinfo:
        build_jira_client(config)

    message = str(excinfo.value)
    assert "credentials are unavailable" in message.lower()
    # Actionable: names both legitimate fixes.
    assert "JIRA_BASE_URL" in message or "base_url" in message
    assert "JIRA_REPORT_RESULTS=false" in message


def test_build_jira_client_raises_even_in_dry_run_mode():
    """Dry-run still performs one real, read-only parent-validation GET
    (see report_test_result()), so it still needs real credentials -- it is
    not a fully offline preview once reporting is enabled."""
    config = reporting_config_from_env(
        {"JIRA_REPORT_RESULTS": "true", "JIRA_REPORT_DRY_RUN": "true"}
    )
    with pytest.raises(JiraCredentialsUnavailableError):
        build_jira_client(config)


def test_build_jira_client_error_never_contains_credential_values():
    """Only names of missing env vars may appear -- never a value (moot
    here since none are set, but guards against a future regression where
    a partially-set credential's value leaks into the message)."""
    config = reporting_config_from_env({})
    with pytest.raises(JiraCredentialsUnavailableError) as excinfo:
        build_jira_client(config)
    assert "not-a-real-token" not in str(excinfo.value)


def test_build_jira_client_succeeds_when_credentials_present(monkeypatch):
    # Jira credentials (JIRA_BASE_URL/EMAIL/API_TOKEN) are read directly from
    # the environment by reporting.jira_client.config_from_env() -- unlike
    # JiraReportingConfig, they are never threaded through
    # reporting_config_from_env()'s env dict.
    for key, value in _VALID_CREDENTIALS.items():
        monkeypatch.setenv(key, value)
    config = reporting_config_from_env({})
    client = build_jira_client(config)
    assert isinstance(client, JiraClient)


# --------------------------------------------------------------------------
# get_session_run_id() -- one run id per pytest execution
# --------------------------------------------------------------------------


def test_get_session_run_id_is_stable_across_calls_without_explicit_run_id():
    config = reporting_config_from_env({})
    first = get_session_run_id(config)
    second = get_session_run_id(config)
    assert first == second


def test_get_session_run_id_matches_derive_run_id_format():
    config = reporting_config_from_env({})
    run_id = get_session_run_id(config)
    assert run_id.startswith("sanity-")


def test_get_session_run_id_always_honors_explicit_run_id():
    config = reporting_config_from_env({"JIRA_RUN_ID": "ci-pipeline-run-7"})
    assert get_session_run_id(config) == "ci-pipeline-run-7"
    assert get_session_run_id(config) == "ci-pipeline-run-7"


def test_get_session_run_id_explicit_run_id_never_cached_over_fallback():
    """A cached fallback (generated for an earlier, unrelated config with no
    $JIRA_RUN_ID) must never leak into a later call that DOES supply one."""
    no_run_id_config = reporting_config_from_env({})
    get_session_run_id(no_run_id_config)  # populate the fallback cache

    explicit_config = reporting_config_from_env({"JIRA_RUN_ID": "explicit-1"})
    assert get_session_run_id(explicit_config) == "explicit-1"


def test_derive_run_id_itself_stays_uncached_unlike_get_session_run_id():
    """Regression guard: get_session_run_id's caching must never leak back
    into derive_run_id -- each call to the raw function still generates its
    own fresh id."""
    config = reporting_config_from_env({})
    assert derive_run_id(config) != derive_run_id(config)
