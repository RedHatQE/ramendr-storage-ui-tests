"""Unit tests for opt-in reporting behavior:

- reporting.jira_results.build_jira_client() -- no client/credentials
  needed unless a real write is actually about to happen (report_results
  AND not dry_run); fail-fast (never a silent skip) once it is.
- reporting.jira_results.get_session_run_id() -- one run id shared by every
  caller within one pytest process that didn't set $JIRA_RUN_ID explicitly.

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
    get_session_run_id,
)

_VALID_CREDENTIALS = {
    "JIRA_BASE_URL": "https://example.invalid",
    "JIRA_EMAIL": "test@example.invalid",
    "JIRA_API_TOKEN": "not-a-real-token",
}


# --------------------------------------------------------------------------
# build_jira_client() -- no client needed until a real write is imminent
# --------------------------------------------------------------------------


def test_build_jira_client_returns_none_by_default_no_credentials_needed():
    """The default config (report_results=False, dry_run=True) needs no
    credentials at all -- this must never raise, even with none set."""
    config = reporting_config_from_env({})
    assert build_jira_client(config) is None


def test_build_jira_client_returns_none_when_reporting_enabled_but_still_dry_run():
    """report_results=true alone is not enough to require credentials --
    dry_run still defaults to true, so this is still a zero-Jira-calls
    preview."""
    config = reporting_config_from_env({"JIRA_REPORT_RESULTS": "true"})
    assert build_jira_client(config) is None


def test_build_jira_client_raises_clearly_when_a_real_write_is_requested_but_credentials_missing():
    """Reporting enabled AND dry-run explicitly disabled means a real write
    is imminent -- missing credentials must fail fast with a clear,
    actionable message, never a silent skip."""
    config = reporting_config_from_env(
        {"JIRA_REPORT_RESULTS": "true", "JIRA_REPORT_DRY_RUN": "false"}
    )
    with pytest.raises(JiraCredentialsUnavailableError) as excinfo:
        build_jira_client(config)

    message = str(excinfo.value)
    assert "credentials are unavailable" in message.lower()
    assert "JIRA_BASE_URL" in message or "base_url" in message


def test_build_jira_client_error_never_contains_credential_values():
    config = reporting_config_from_env(
        {"JIRA_REPORT_RESULTS": "true", "JIRA_REPORT_DRY_RUN": "false"}
    )
    with pytest.raises(JiraCredentialsUnavailableError) as excinfo:
        build_jira_client(config)
    assert "not-a-real-token" not in str(excinfo.value)


def test_build_jira_client_succeeds_when_credentials_present(monkeypatch):
    for key, value in _VALID_CREDENTIALS.items():
        monkeypatch.setenv(key, value)
    config = reporting_config_from_env(
        {"JIRA_REPORT_RESULTS": "true", "JIRA_REPORT_DRY_RUN": "false"}
    )
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


def test_get_session_run_id_always_honors_explicit_run_id():
    config = reporting_config_from_env({"JIRA_RUN_ID": "ci-pipeline-run-7"})
    assert get_session_run_id(config) == "ci-pipeline-run-7"
    assert get_session_run_id(config) == "ci-pipeline-run-7"


def test_get_session_run_id_explicit_run_id_never_overridden_by_cached_fallback():
    """A cached fallback (generated for an earlier, unrelated config with no
    $JIRA_RUN_ID) must never leak into a later call that DOES supply one."""
    no_run_id_config = reporting_config_from_env({})
    get_session_run_id(no_run_id_config)  # populate the fallback cache

    explicit_config = reporting_config_from_env({"JIRA_RUN_ID": "explicit-1"})
    assert get_session_run_id(explicit_config) == "explicit-1"
