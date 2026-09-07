"""Unit tests for the read-only Jira client. Jira is always mocked; no network."""

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

_TOKEN = "TOP-SECRET-TOKEN-do-not-leak"
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
    """Records every GET/POST call and returns queued canned responses in order."""

    def __init__(self, responses=None, post_responses=None):
        self.responses = list(responses or [])
        self.post_responses = list(post_responses or [])
        self.calls: list[dict] = []
        self.post_calls: list[dict] = []
        self.headers: dict = {}
        self.auth = None

    def get(self, url, params=None, timeout=None):
        self.calls.append({"url": url, "params": params, "timeout": timeout})
        return self.responses.pop(0)

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


def _client(responses=None, post_responses=None) -> tuple[JiraClient, FakeSession]:
    session = FakeSession(responses=responses, post_responses=post_responses)
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


def test_client_sets_basic_auth_from_config():
    _, session = _client([FakeResponse(200, {"accountId": "1"})])
    assert session.auth == (_EMAIL, _TOKEN)


# --------------------------------------------------------------------------
# Authentication
# --------------------------------------------------------------------------


def test_get_current_user_success():
    client, session = _client(
        [FakeResponse(200, {"displayName": "QE Bot", "accountId": "abc123"})]
    )
    user = client.get_current_user()
    assert user == {"displayName": "QE Bot", "accountId": "abc123"}
    assert session.calls[0]["url"].endswith("/rest/api/3/myself")
    assert session.calls[0]["timeout"] == (10.0, 30.0)


def test_get_current_user_401_raises_authentication_error():
    client, _ = _client([FakeResponse(401)])
    with pytest.raises(JiraAuthenticationError):
        client.get_current_user()


def test_get_current_user_403_raises_permission_error():
    client, _ = _client([FakeResponse(403)])
    with pytest.raises(JiraPermissionError):
        client.get_current_user()


def test_credentials_never_appear_in_exception_message():
    client, _ = _client([FakeResponse(401)])
    with pytest.raises(JiraAuthenticationError) as exc_info:
        client.get_current_user()
    message = str(exc_info.value)
    assert _TOKEN not in message
    assert _EMAIL not in message


# --------------------------------------------------------------------------
# Pagination
# --------------------------------------------------------------------------


def test_get_create_issue_types_follows_pagination():
    """The real Jira Cloud response for this endpoint wraps its page contents
    in an ``issueTypes`` key, NOT the generic ``values`` key used by most
    other paginated endpoints (confirmed against the official docs). Using
    the wrong key silently yields an always-empty list rather than an error,
    so this exact shape matters.
    """
    client, session = _client(
        [
            FakeResponse(
                200,
                {
                    "startAt": 0,
                    "maxResults": 1,
                    "total": 2,
                    "isLast": False,
                    "issueTypes": [{"id": "1", "name": "Test Case"}],
                },
            ),
            FakeResponse(
                200,
                {
                    "startAt": 1,
                    "maxResults": 1,
                    "total": 2,
                    "isLast": True,
                    "issueTypes": [{"id": "2", "name": "Test Result"}],
                },
            ),
        ]
    )
    issue_types = client.get_create_issue_types("RHELTEST")
    assert [t["name"] for t in issue_types] == ["Test Case", "Test Result"]
    assert len(session.calls) == 2
    assert session.calls[0]["params"]["startAt"] == 0
    assert session.calls[1]["params"]["startAt"] == 1


def test_get_create_issue_types_stops_on_empty_issuetypes_page():
    client, session = _client(
        [
            FakeResponse(
                200,
                {"startAt": 0, "total": 5, "isLast": None, "issueTypes": []},
            )
        ]
    )
    issue_types = client.get_create_issue_types("RHELTEST")
    assert issue_types == []
    assert len(session.calls) == 1


def test_get_create_issue_types_ignores_a_values_key_if_present():
    """Regression test for the real bug found against production RHELTEST:
    a page shaped with a ``values`` key (the generic-but-wrong assumption)
    must NOT be picked up as issue types -- only ``issueTypes`` counts.
    """
    client, _ = _client(
        [
            FakeResponse(
                200,
                {
                    "startAt": 0,
                    "total": 0,
                    "isLast": True,
                    "values": [{"id": "1", "name": "Should not be returned"}],
                },
            )
        ]
    )
    assert client.get_create_issue_types("RHELTEST") == []


def test_get_create_fields_keys_result_by_field_id():
    """The real Jira Cloud response for this endpoint wraps its page contents
    in a ``fields`` key, NOT the generic ``values`` key (confirmed against
    the official docs)."""
    client, _ = _client(
        [
            FakeResponse(
                200,
                {
                    "startAt": 0,
                    "total": 2,
                    "isLast": True,
                    "fields": [
                        {
                            "fieldId": "summary",
                            "name": "Summary",
                            "required": True,
                            "schema": {"type": "string"},
                        },
                        {
                            "fieldId": "customfield_12345",
                            "name": "Compose Version",
                            "required": False,
                            "schema": {"type": "string", "custom": "textfield"},
                        },
                    ],
                },
            )
        ]
    )
    fields = client.get_create_fields("RHELTEST", "10500")
    assert set(fields) == {"summary", "customfield_12345"}
    assert fields["customfield_12345"]["name"] == "Compose Version"


# --------------------------------------------------------------------------
# Other read endpoints
# --------------------------------------------------------------------------


def test_get_fields_returns_list():
    client, _ = _client([FakeResponse(200, [{"id": "summary", "name": "Summary"}])])
    fields = client.get_fields()
    assert fields == [{"id": "summary", "name": "Summary"}]


def test_get_fields_defensive_when_not_a_list():
    client, _ = _client([FakeResponse(200, {"unexpected": "shape"})])
    assert client.get_fields() == []


def test_get_issue_passes_expand_param():
    client, session = _client([FakeResponse(200, {"key": "RHELTEST-3600"})])
    issue = client.get_issue("RHELTEST-3600", expand="names,schema")
    assert issue["key"] == "RHELTEST-3600"
    assert session.calls[0]["params"] == {"expand": "names,schema"}


def test_get_issue_type_returns_global_metadata():
    client, session = _client(
        [
            FakeResponse(
                200,
                {
                    "id": "10500",
                    "name": "Test Result",
                    "subtask": False,
                    "hierarchyLevel": 0,
                    "scope": {"type": "PROJECT", "project": {"id": "11493"}},
                },
            )
        ]
    )
    issue_type = client.get_issue_type("10500")
    assert issue_type["name"] == "Test Result"
    assert session.calls[0]["url"].endswith("/rest/api/3/issuetype/10500")


def test_get_project_issue_types_returns_list():
    client, session = _client(
        [FakeResponse(200, [{"id": "10500", "name": "Test Result"}])]
    )
    issue_types = client.get_project_issue_types("11493")
    assert issue_types == [{"id": "10500", "name": "Test Result"}]
    assert session.calls[0]["params"] == {"projectId": "11493"}


def test_get_project_issue_types_defensive_when_not_a_list():
    client, _ = _client([FakeResponse(200, {"unexpected": "shape"})])
    assert client.get_project_issue_types("11493") == []


def test_get_my_permissions_passes_project_and_permissions_params():
    client, session = _client(
        [
            FakeResponse(
                200, {"permissions": {"CREATE_ISSUES": {"havePermission": True}}}
            )
        ]
    )
    result = client.get_my_permissions("RHELTEST", "CREATE_ISSUES")
    assert result["permissions"]["CREATE_ISSUES"]["havePermission"] is True
    assert session.calls[0]["params"] == {
        "projectKey": "RHELTEST",
        "permissions": "CREATE_ISSUES",
    }


def test_get_transitions_extracts_transitions_list():
    client, _ = _client(
        [
            FakeResponse(
                200,
                {
                    "transitions": [
                        {
                            "id": "31",
                            "name": "Pass",
                            "to": {"id": "10001", "name": "PASS"},
                        }
                    ]
                },
            )
        ]
    )
    transitions = client.get_transitions("RHELTEST-3600")
    assert transitions == [
        {"id": "31", "name": "Pass", "to": {"id": "10001", "name": "PASS"}}
    ]


def test_search_issues_uses_enhanced_jql_search_endpoint():
    """The legacy GET /rest/api/3/search endpoint was removed by Atlassian
    (HTTP 410 in production) -- must use /rest/api/3/search/jql instead."""
    client, session = _client(
        [
            FakeResponse(
                200,
                {
                    "issues": [
                        {
                            "id": "10123",
                            "key": "RHELTEST-9001",
                            "fields": {"status": {"name": "PASS"}},
                        }
                    ],
                    "isLast": True,
                },
            )
        ]
    )
    issues = client.search_issues(
        'key = "RHELTEST-9001"', max_results=1, fields="key,status"
    )
    assert issues == [
        {
            "id": "10123",
            "key": "RHELTEST-9001",
            "fields": {"status": {"name": "PASS"}},
        }
    ]
    assert session.calls[0]["params"] == {
        "jql": 'key = "RHELTEST-9001"',
        "maxResults": 1,
        "fields": "key,status",
    }
    assert session.calls[0]["url"].endswith("/rest/api/3/search/jql")
    assert not session.calls[0]["url"].endswith("/rest/api/3/search")


def test_search_issues_omits_fields_param_when_not_given():
    client, session = _client([FakeResponse(200, {"issues": [], "isLast": True})])
    client.search_issues("key = RHELTEST-9001")
    assert "fields" not in session.calls[0]["params"]


def test_search_issues_returns_empty_list_when_no_issues_found():
    """The enhanced endpoint's response has no `total`/`startAt` at all --
    absence must be handled without relying on either."""
    client, _ = _client([FakeResponse(200, {"issues": [], "isLast": True})])
    assert client.search_issues('key = "RHELTEST-DOES-NOT-EXIST"') == []


def test_search_issues_handles_a_non_last_page_response_shape():
    """Real (non-last) pages carry `nextPageToken` and no `isLast: true` --
    parsing must not depend on either being present."""
    client, _ = _client(
        [
            FakeResponse(
                200,
                {
                    "issues": [{"key": "RHELTEST-1"}, {"key": "RHELTEST-2"}],
                    "nextPageToken": "CAEaJVJIRUxURVNULTIw",
                },
            )
        ]
    )
    issues = client.search_issues("project = RHELTEST", max_results=2)
    assert [i["key"] for i in issues] == ["RHELTEST-1", "RHELTEST-2"]


def test_search_issues_defensive_when_response_missing_issues_key():
    client, _ = _client([FakeResponse(200, {"unexpected": "shape"})])
    assert client.search_issues("key = RHELTEST-9001") == []


def test_search_issues_is_read_only_and_retries_like_other_gets():
    """search_issues is a GET, so it goes through the normal retry path."""
    client, session = _client(
        [
            FakeResponse(429, headers={"Retry-After": "0"}),
            FakeResponse(200, {"issues": [{"key": "RHELTEST-9001"}], "isLast": True}),
        ]
    )
    issues = client.search_issues("key = RHELTEST-9001")
    assert issues == [{"key": "RHELTEST-9001"}]
    assert len(session.calls) == 2  # retried once after the 429


def test_search_issues_finds_the_pilot_issue_by_key():
    """Regression test for the exact production pilot lookup that hit the
    legacy endpoint's HTTP 410: `key = "RHELTEST-3614"` against the new
    enhanced JQL search endpoint's real response shape."""
    client, session = _client(
        [
            FakeResponse(
                200,
                {
                    "issues": [
                        {
                            "id": "10456",
                            "key": "RHELTEST-3614",
                            "fields": {"status": {"name": "PASS"}},
                        }
                    ],
                    "isLast": True,
                },
            )
        ]
    )
    issues = client.search_issues(
        'key = "RHELTEST-3614"', max_results=1, fields="key,status"
    )
    assert any(issue.get("key") == "RHELTEST-3614" for issue in issues)
    assert session.calls[0]["url"].endswith("/rest/api/3/search/jql")


# --------------------------------------------------------------------------
# Retry / error handling
# --------------------------------------------------------------------------


def test_retries_on_429_then_succeeds():
    client, session = _client(
        [
            FakeResponse(429, headers={"Retry-After": "0"}),
            FakeResponse(200, {"accountId": "1", "displayName": "QE Bot"}),
        ]
    )
    user = client.get_current_user()
    assert user["accountId"] == "1"
    assert len(session.calls) == 2


def test_gives_up_after_max_retries_on_persistent_503():
    responses = [FakeResponse(503, headers={"Retry-After": "0"}) for _ in range(5)]
    client, session = _client(responses)
    with pytest.raises(JiraClientError):
        client.get_current_user()
    # 1 initial attempt + 3 retries = 4 calls, then it raises rather than retry forever.
    assert len(session.calls) == 4


def test_network_error_raises_jira_client_error(monkeypatch):
    class RaisingSession(FakeSession):
        def get(self, *args, **kwargs):
            raise requests.ConnectionError("boom")

    client = JiraClient(_config(), session=RaisingSession([]))
    with pytest.raises(JiraClientError):
        client.get_current_user()


def test_non_json_body_raises_jira_client_error():
    class BadJsonResponse(FakeResponse):
        def json(self):
            raise ValueError("not json")

    client, _ = _client([BadJsonResponse(200, content=b"not json")])
    with pytest.raises(JiraClientError):
        client.get_current_user()


def test_unexpected_status_code_raises_jira_client_error():
    client, _ = _client([FakeResponse(500)])
    with pytest.raises(JiraClientError):
        client.get_current_user()


# --------------------------------------------------------------------------
# Write operations (Phase B/C): create_issue / transition_issue
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
    client, _ = _client(
        post_responses=[FakeResponse(400, {"errorMessages": [f"body echoes {_TOKEN}"]})]
    )
    # This asserts our sanitizer doesn't add anything beyond what Jira sent --
    # it does NOT claim Jira itself would ever echo a token (it never does).
    # The real credential-safety guarantee is that _TOKEN/_EMAIL are never
    # part of the request/response path our own code constructs.
    with pytest.raises(JiraWriteError):
        client.create_issue({"project": {"key": "RHELTEST"}})
    # Session auth tuple (the actual credential) must still never be embedded
    # in the exception via our own formatting.
    client2, _ = _client(post_responses=[FakeResponse(400, {})])
    with pytest.raises(JiraWriteError) as exc_info:
        client2.create_issue({"project": {"key": "RHELTEST"}})
    assert _TOKEN not in str(exc_info.value)
    assert _EMAIL not in str(exc_info.value)


def test_write_error_message_is_truncated_and_ignores_raw_body_shape():
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
    """GET retries on 429/5xx; POST must NOT -- writes aren't safely repeatable."""
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
