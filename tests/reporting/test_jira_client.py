"""Unit tests for the thin Jira client (create_issue / transition_issue).
Jira is always mocked; no network."""

from __future__ import annotations

import pytest
import requests

from reporting.jira_client import (
    JiraAmbiguousWriteError,
    JiraAuthenticationError,
    JiraClient,
    JiraClientError,
    JiraConfig,
    JiraPermissionError,
    JiraWriteError,
    config_from_env,
)

_TOKEN = "TOP-SECRET-TOKEN-do-not-leak"  # noqa: S105 -- test fixture, not a real credential
_EMAIL = "qe-automation@example.com"


class FakeResponse:
    """Minimal stand-in for requests.Response used across client tests."""

    def __init__(self, status_code, json_data=None, headers=None, content=b"{}"):
        self.status_code = status_code
        self._json_data = json_data
        self.headers = headers or {}
        self.content = content
        self.ok = 200 <= status_code < 300

    def json(self):
        if self._json_data is None:
            raise ValueError("no JSON body")
        return self._json_data


class FakeSession:
    """Records every POST call and returns queued canned responses in order."""

    def __init__(self, post_responses=None):
        self.post_responses = list(post_responses or [])
        self.post_calls: list[dict] = []
        self.headers: dict = {}
        self.auth = None

    def post(self, url, json=None, timeout=None):
        self.post_calls.append({"url": url, "json": json, "timeout": timeout})
        response = self.post_responses.pop(0)
        if isinstance(response, Exception):
            raise response
        return response


def _config(**overrides) -> JiraConfig:
    defaults = dict(
        base_url="https://redhat.atlassian.net", email=_EMAIL, api_token=_TOKEN
    )
    defaults.update(overrides)
    return JiraConfig(**defaults)


def _client(post_responses=None) -> tuple[JiraClient, FakeSession]:
    session = FakeSession(post_responses=post_responses)
    return JiraClient(_config(), session=session), session


# --------------------------------------------------------------------------
# Configuration
# --------------------------------------------------------------------------


def test_config_from_env_reads_expected_variables():
    config = config_from_env(
        {
            "JIRA_BASE_URL": "https://redhat.atlassian.net",
            "JIRA_EMAIL": _EMAIL,
            "JIRA_API_TOKEN": _TOKEN,
        }
    )
    assert config.base_url == "https://redhat.atlassian.net"
    assert config.email == _EMAIL
    assert config.api_token == _TOKEN


@pytest.mark.parametrize(
    "env",
    [
        {},
        {"JIRA_BASE_URL": "https://redhat.atlassian.net"},
        {"JIRA_BASE_URL": "https://redhat.atlassian.net", "JIRA_EMAIL": _EMAIL},
    ],
)
def test_config_from_env_missing_variables_raises(env):
    with pytest.raises(ValueError):
        config_from_env(env)


@pytest.mark.parametrize(
    "bad_base_url",
    [
        "http://redhat.atlassian.net",
        "ftp://redhat.atlassian.net",
        "redhat.atlassian.net",
    ],
)
def test_config_rejects_non_https_base_url(bad_base_url):
    with pytest.raises(ValueError, match="HTTPS"):
        JiraConfig(base_url=bad_base_url, email=_EMAIL, api_token=_TOKEN)


def test_config_accepts_https_base_url():
    config = _config(base_url="https://redhat.atlassian.net")
    assert config.base_url == "https://redhat.atlassian.net"


def test_client_sets_basic_auth_from_config():
    _, session = _client(post_responses=[FakeResponse(204, content=b"")])
    assert session.auth == (_EMAIL, _TOKEN)


# --------------------------------------------------------------------------
# create_issue / transition_issue -- the happy path
# --------------------------------------------------------------------------


def test_create_issue_returns_key_and_posts_expected_body():
    client, session = _client(
        post_responses=[FakeResponse(201, {"id": "1001", "key": "RHELTEST-9001"})]
    )
    fields = {"project": {"key": "RHELTEST"}, "summary": "x"}
    key = client.create_issue(fields)

    assert key == "RHELTEST-9001"
    assert len(session.post_calls) == 1
    call = session.post_calls[0]
    assert call["url"].endswith("/rest/api/3/issue")
    assert call["json"] == {"fields": fields}
    assert call["timeout"] == (10.0, 30.0)


def test_create_issue_raises_when_response_has_no_key():
    client, _ = _client(post_responses=[FakeResponse(201, {"id": "1001"})])
    with pytest.raises(JiraClientError):
        client.create_issue({"project": {"key": "RHELTEST"}})


def test_transition_issue_posts_expected_body():
    client, session = _client(post_responses=[FakeResponse(204, content=b"")])
    client.transition_issue("RHELTEST-9001", "3")

    assert len(session.post_calls) == 1
    call = session.post_calls[0]
    assert call["url"].endswith("/rest/api/3/issue/RHELTEST-9001/transitions")
    assert call["json"] == {"transition": {"id": "3"}}
    assert call["timeout"] == (10.0, 30.0)


def test_transition_issue_coerces_transition_id_to_string():
    client, session = _client(post_responses=[FakeResponse(204, content=b"")])
    client.transition_issue("RHELTEST-9001", 3)
    assert session.post_calls[0]["json"] == {"transition": {"id": "3"}}


# --------------------------------------------------------------------------
# Error handling -- writes are never retried, errors never leak credentials
# --------------------------------------------------------------------------


def test_create_issue_401_raises_authentication_error():
    client, _ = _client(post_responses=[FakeResponse(401)])
    with pytest.raises(JiraAuthenticationError):
        client.create_issue({"project": {"key": "RHELTEST"}})


def test_create_issue_403_raises_permission_error():
    client, _ = _client(post_responses=[FakeResponse(403)])
    with pytest.raises(JiraPermissionError):
        client.create_issue({"project": {"key": "RHELTEST"}})


def test_create_issue_400_raises_write_error_with_sanitized_message():
    client, _ = _client(
        post_responses=[
            FakeResponse(
                400,
                {
                    "errorMessages": [],
                    "errors": {"parent": "Parent issue does not exist"},
                },
            )
        ]
    )
    with pytest.raises(JiraWriteError) as exc_info:
        client.create_issue({"project": {"key": "RHELTEST"}})
    message = str(exc_info.value)
    assert "Parent issue does not exist" in message
    assert "parent:" in message


def test_write_error_message_never_contains_credentials():
    client, _ = _client(post_responses=[FakeResponse(400, {})])
    with pytest.raises(JiraWriteError) as exc_info:
        client.create_issue({"project": {"key": "RHELTEST"}})
    assert _TOKEN not in str(exc_info.value)
    assert _EMAIL not in str(exc_info.value)


def test_write_error_message_is_truncated():
    huge_message = "x" * 10_000
    client, _ = _client(
        post_responses=[FakeResponse(400, {"errorMessages": [huge_message]})]
    )
    with pytest.raises(JiraWriteError) as exc_info:
        client.create_issue({"project": {"key": "RHELTEST"}})
    assert len(str(exc_info.value)) < 1000


def test_write_error_handles_non_json_body_gracefully():
    class NonJsonErrorResponse(FakeResponse):
        def json(self):
            raise ValueError("not json")

    client, _ = _client(post_responses=[NonJsonErrorResponse(500, content=b"oops")])
    with pytest.raises(JiraClientError):
        client.create_issue({"project": {"key": "RHELTEST"}})


def test_create_issue_network_error_raises_ambiguous_write_error_not_client_error():
    client, session = _client(post_responses=[requests.ConnectionError("boom")])
    with pytest.raises(JiraAmbiguousWriteError):
        client.create_issue({"project": {"key": "RHELTEST"}})
    # Exactly one attempt: writes are never retried, ambiguous or not.
    assert len(session.post_calls) == 1


def test_transition_issue_network_error_raises_ambiguous_write_error():
    client, _ = _client(post_responses=[requests.Timeout("timed out")])
    with pytest.raises(JiraAmbiguousWriteError):
        client.transition_issue("RHELTEST-9001", "3")


@pytest.mark.parametrize("status_code", [429, 500, 502, 503, 504])
def test_post_is_never_retried_even_on_retryable_looking_status_codes(status_code):
    """Writes aren't safely repeatable, so unlike a GET, a single POST
    never retries regardless of status code."""
    client, session = _client(post_responses=[FakeResponse(status_code)])
    with pytest.raises(JiraClientError):
        client.create_issue({"project": {"key": "RHELTEST"}})
    assert len(session.post_calls) == 1


def test_create_issue_never_logs_credentials_on_any_failure_path(capsys):
    client, _ = _client(post_responses=[FakeResponse(400, {"errorMessages": ["bad"]})])
    with pytest.raises(JiraClientError):
        client.create_issue({"project": {"key": "RHELTEST"}})
    captured = capsys.readouterr()
    assert _TOKEN not in captured.out
    assert _TOKEN not in captured.err
