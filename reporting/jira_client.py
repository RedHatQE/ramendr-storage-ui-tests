"""Minimal Jira Cloud REST API v3 client.

Phase A added the read-only discovery surface (project/issue-type/field
metadata, a sample issue, and its available workflow transitions). Phase
B/C add exactly two write operations, ``create_issue`` and
``transition_issue``, used only by ``reporting/jira_results.py`` -- gated
behind ``JIRA_REPORT_RESULTS`` / ``JIRA_REPORT_DRY_RUN`` and, for the CLI,
``--confirm`` (see ``scripts/jira/create_test_result_smoke.py``).

Writes are **never** retried automatically, unlike GETs: Jira issue
creation and transitions are not safely repeatable, and a network error
during a POST leaves the outcome ambiguous (the request may have reached
Jira and been applied even though no response was seen). See
``JiraAmbiguousWriteError`` below.

Never log or print credentials: this module never includes the API token,
email, or ``Authorization`` header in an exception message or return value.
Error responses from Jira are sanitized to their structured
``errorMessages``/``errors`` fields only, truncated defensively -- never the
raw response body/headers.
"""

from __future__ import annotations

import os
import time
from dataclasses import dataclass
from typing import Any, Mapping

import requests

#: (connect, read) timeout in seconds. Every request is bounded explicitly;
#: never rely on requests' default (no timeout).
DEFAULT_TIMEOUT: tuple[float, float] = (10.0, 30.0)

#: HTTP statuses that are safe to retry for idempotent GET requests.
_RETRY_STATUS_CODES = frozenset({429, 502, 503, 504})
_MAX_RETRIES = 3
_RETRY_BACKOFF_SECONDS = 1.0
#: Hard cap on any retry delay, including a server-supplied ``Retry-After`` --
#: never sleep longer than the read timeout would allow a caller to wait.
_MAX_RETRY_DELAY_SECONDS = DEFAULT_TIMEOUT[1]

_API_PREFIX = "rest/api/3"


class JiraClientError(RuntimeError):
    """Base error for Jira API failures. Messages never contain credentials."""


class JiraAuthenticationError(JiraClientError):
    """Raised when Jira rejects the supplied credentials (HTTP 401)."""


class JiraPermissionError(JiraClientError):
    """Raised when Jira denies access to the requested resource (HTTP 403)."""


class JiraWriteError(JiraClientError):
    """Raised when a write (POST) fails with a clear HTTP error response.

    A response WAS received, so the outcome is known: Jira rejected the
    request (e.g. a validation error) and did not create/transition
    anything. Safe to fix the payload and retry deliberately -- but this
    client never does so automatically.
    """


class JiraAmbiguousWriteError(JiraClientError):
    """Raised when a write (POST) fails before any response was received
    (network error / timeout).

    The outcome is **unknown**: the request may have reached Jira and been
    processed (creating an issue or applying a transition) even though the
    client never saw a response. Callers MUST NOT blindly retry after this
    error -- doing so risks creating a duplicate issue or double-applying a
    transition. Instead, verify against Jira directly (e.g. search for an
    issue with the intended summary/run-id) before deciding whether to
    retry.
    """


@dataclass(frozen=True)
class JiraConfig:
    """Connection settings for :class:`JiraClient`.

    Never printed, logged, or included in exception messages as a whole.
    """

    base_url: str
    email: str
    api_token: str
    timeout: tuple[float, float] = DEFAULT_TIMEOUT

    def __post_init__(self) -> None:
        missing = [
            name
            for name, value in (
                ("base_url", self.base_url),
                ("email", self.email),
                ("api_token", self.api_token),
            )
            if not value
        ]
        if missing:
            raise ValueError(
                "Missing required Jira configuration: " + ", ".join(missing)
            )
        if not self.base_url.startswith("https://"):
            raise ValueError(
                "JIRA_BASE_URL must use HTTPS (got a non-HTTPS URL) -- refusing "
                "to send credentials over an insecure scheme"
            )


def config_from_env(env: Mapping[str, str] | None = None) -> JiraConfig:
    """Build a :class:`JiraConfig` from environment variables.

    Reads ``JIRA_BASE_URL``, ``JIRA_EMAIL``, and ``JIRA_API_TOKEN``. Raises
    ``ValueError`` (via ``JiraConfig.__post_init__``) listing which variables
    are missing -- never the values themselves.
    """
    source = env if env is not None else os.environ
    return JiraConfig(
        base_url=source.get("JIRA_BASE_URL", ""),
        email=source.get("JIRA_EMAIL", ""),
        api_token=source.get("JIRA_API_TOKEN", ""),
    )


class JiraClient:
    """Jira Cloud REST API v3 client.

    Mostly GET (schema discovery, Phase A). Exactly two write operations
    exist -- ``create_issue`` and ``transition_issue`` -- both added in
    Phase B/C and both never retried automatically (see module docstring).
    """

    def __init__(
        self, config: JiraConfig, session: requests.Session | None = None
    ) -> None:
        self._config = config
        self._session = session or requests.Session()
        self._session.auth = (config.email, config.api_token)
        self._session.headers.update({"Accept": "application/json"})

    def get_current_user(self) -> dict[str, Any]:
        """GET /myself. Used to verify authentication before discovery proceeds."""
        return self._get("myself")

    def get_project(self, project_key: str) -> dict[str, Any]:
        """GET /project/{key}. Returns the project's id/key/name."""
        return self._get(f"project/{project_key}")

    def get_create_issue_types(self, project_key: str) -> list[dict[str, Any]]:
        """GET /issue/createmeta/{project}/issuetypes, following pagination.

        Returns the issue types selectable when creating an issue in the
        project (id, name, subtask flag, hierarchy level when present).

        NOTE: unlike most paginated Jira Cloud endpoints, this one wraps its
        page contents in an ``issueTypes`` key, not the generic ``values``
        key -- see the official docs
        (https://developer.atlassian.com/cloud/jira/platform/rest/v3/api-group-issues/#api-rest-api-3-issue-createmeta-projectidorkey-issuetypes-get).
        Using the wrong key silently yields an always-empty list (HTTP 200,
        no error) rather than raising, so this is easy to get wrong.
        """
        return self._paginate(
            f"issue/createmeta/{project_key}/issuetypes", results_key="issueTypes"
        )

    def get_create_fields(
        self, project_key: str, issue_type_id: str
    ) -> dict[str, dict[str, Any]]:
        """GET /issue/createmeta/{project}/issuetypes/{issue_type_id}.

        Follows pagination and returns the create-field metadata keyed by
        ``fieldId`` (field name, required flag, schema, allowed values).

        NOTE: this endpoint wraps its page contents in a ``fields`` key, not
        the generic ``values`` key -- see the official docs
        (https://developer.atlassian.com/cloud/jira/platform/rest/v3/api-group-issues/#api-rest-api-3-issue-createmeta-projectidorkey-issuetypes-issuetypeid-get).
        """
        values = self._paginate(
            f"issue/createmeta/{project_key}/issuetypes/{issue_type_id}",
            results_key="fields",
        )
        return {item["fieldId"]: item for item in values if "fieldId" in item}

    def get_fields(self) -> list[dict[str, Any]]:
        """GET /field. Returns the global field registry (id, name, custom, schema)."""
        result = self._get("field")
        return result if isinstance(result, list) else []

    def get_issue(self, issue_key: str, *, expand: str | None = None) -> dict[str, Any]:
        """GET /issue/{key}, optionally expanding e.g. ``names,schema``."""
        params = {"expand": expand} if expand else None
        return self._get(f"issue/{issue_key}", params=params)

    def get_transitions(self, issue_key: str) -> list[dict[str, Any]]:
        """GET /issue/{key}/transitions. Returns available workflow transitions."""
        result = self._get(f"issue/{issue_key}/transitions") or {}
        return result.get("transitions", [])

    def get_issue_type(self, issue_type_id: str) -> dict[str, Any]:
        """GET /issuetype/{id}.

        Global issue-type metadata (hierarchyLevel, scope, subtask),
        independent of any project's create-screen configuration. Used to
        confirm an issue type exists even when it is absent from create
        metadata (e.g. app-managed or screen-restricted types).
        """
        return self._get(f"issuetype/{issue_type_id}")

    def get_project_issue_types(self, project_id: str) -> list[dict[str, Any]]:
        """GET /issuetype/project?projectId={id}.

        Returns the issue types associated with the project's issue type
        scheme. This reflects project-level association only and is
        independent of whether the current user can create that type
        (create metadata additionally filters by permission/create-screen
        configuration).
        """
        result = self._get("issuetype/project", params={"projectId": project_id})
        return result if isinstance(result, list) else []

    def get_my_permissions(self, project_key: str, permissions: str) -> dict[str, Any]:
        """GET /mypermissions?projectKey=...&permissions=....

        Read-only permission check for the current user (e.g. ``CREATE_ISSUES``)
        on the given project. Useful to rule out a blanket permission problem.
        """
        return self._get(
            "mypermissions",
            params={"projectKey": project_key, "permissions": permissions},
        )

    def search_issues(
        self, jql: str, *, max_results: int = 10, fields: str | None = None
    ) -> list[dict[str, Any]]:
        """GET /search/jql?jql=.... Read-only enhanced JQL search (Jira Cloud).

        Used only for best-effort post-write verification (e.g. confirming a
        newly created issue is indexed/searchable, as a proxy for dashboard/
        saved-filter visibility) -- never to bulk-fetch or filter for a
        write operation.

        Uses the current Jira Cloud "enhanced JQL search" endpoint
        (``/rest/api/3/search/jql``). The legacy ``GET /rest/api/3/search``
        endpoint was removed by Atlassian (HTTP 410 in production) -- its
        replacement has a different response shape: no ``total``/``startAt``,
        cursor-based pagination via ``nextPageToken``/``isLast`` instead.
        This method only fetches a single page (``max_results`` issues,
        capped at Jira's page size): every current caller only needs to
        check for a handful of specific issues by key. A caller needing more
        than one page would require looping on ``nextPageToken`` until
        ``isLast`` is true -- not implemented since nothing needs it yet.
        """
        params: dict[str, Any] = {"jql": jql, "maxResults": max_results}
        if fields:
            params["fields"] = fields
        result = self._get("search/jql", params=params)
        issues = result.get("issues") if isinstance(result, dict) else None
        return issues if isinstance(issues, list) else []

    # ----------------------------------------------------------------
    # Write operations (Phase B/C). Never retried automatically -- see
    # JiraAmbiguousWriteError and the module docstring.
    # ----------------------------------------------------------------

    def create_issue(self, fields: dict[str, Any]) -> str:
        """POST /issue. Creates a Jira issue from ``fields`` and returns its key.

        WRITE operation, never retried automatically. Callers are
        responsible for any idempotency guarantees they need (e.g.
        searching for an existing issue with the same run id before calling
        this) -- this client has no way to know whether a prior ambiguous
        failure already created the issue.
        """
        result = self._post("issue", json_body={"fields": fields})
        key = result.get("key") if isinstance(result, dict) else None
        if not key:
            raise JiraClientError("POST issue succeeded but response had no 'key'")
        return key

    def transition_issue(self, issue_key: str, transition_id: str) -> None:
        """POST /issue/{key}/transitions. Applies a workflow transition.

        WRITE operation, never retried automatically. Callers should check
        the issue's currently *available* transitions (``get_transitions``)
        before calling this, rather than assuming ``transition_id`` applies.
        """
        self._post(
            f"issue/{issue_key}/transitions",
            json_body={"transition": {"id": str(transition_id)}},
        )

    def _paginate(
        self, path: str, *, results_key: str = "values"
    ) -> list[dict[str, Any]]:
        """Collect every page for a Jira ``startAt``/``isLast`` endpoint.

        Most paginated Jira Cloud endpoints wrap their page contents in a
        ``values`` key, but a few (e.g. the createmeta issue-type/field
        endpoints) use a different key (``issueTypes``, ``fields``). Pass
        ``results_key`` explicitly for those -- guessing wrong yields an
        always-empty result (HTTP 200, no error) rather than a failure, so
        it never surfaces as an obvious bug.
        """
        values: list[dict[str, Any]] = []
        start_at = 0
        max_results = 50
        while True:
            page = self._get(
                path, params={"startAt": start_at, "maxResults": max_results}
            )
            page_values = page.get(results_key, []) if isinstance(page, dict) else []
            values.extend(page_values)

            is_last = True
            if isinstance(page, dict):
                is_last = page.get("isLast")
                if is_last is None:
                    total = page.get("total")
                    is_last = total is None or start_at + len(page_values) >= total
                if not page_values:
                    is_last = True
            if is_last:
                break
            start_at += len(page_values) or max_results
        return values

    def _get(self, path: str, *, params: dict[str, Any] | None = None) -> Any:
        """Issue a single GET against the Jira REST API v3 and return parsed JSON."""
        url = f"{self._config.base_url.rstrip('/')}/{_API_PREFIX}/{path.lstrip('/')}"
        attempt = 0
        while True:
            attempt += 1
            try:
                response = self._session.get(
                    url, params=params, timeout=self._config.timeout
                )
            except requests.RequestException as exc:
                raise JiraClientError(f"GET {path} failed: network error") from exc

            if response.status_code == 401:
                raise JiraAuthenticationError(
                    f"GET {path} failed: authentication invalid (HTTP 401)"
                )
            if response.status_code == 403:
                raise JiraPermissionError(
                    f"GET {path} failed: missing permission (HTTP 403)"
                )
            if response.status_code in _RETRY_STATUS_CODES and attempt <= _MAX_RETRIES:
                time.sleep(_retry_delay_seconds(response, attempt))
                continue
            if not response.ok:
                raise JiraClientError(f"GET {path} failed: HTTP {response.status_code}")

            if not response.content:
                return None
            try:
                return response.json()
            except ValueError as exc:
                raise JiraClientError(f"GET {path} returned a non-JSON body") from exc

    def _post(self, path: str, *, json_body: dict[str, Any]) -> Any:
        """Issue a single POST against the Jira REST API v3. NEVER retried.

        Unlike ``_get``, this makes exactly one attempt. Jira writes are not
        idempotent, so retrying a POST that may have already been applied
        (e.g. after a timeout) risks creating a duplicate issue or
        double-applying a transition -- callers get an explicit
        :class:`JiraAmbiguousWriteError` instead so they can decide what's
        safe to do next.
        """
        url = f"{self._config.base_url.rstrip('/')}/{_API_PREFIX}/{path.lstrip('/')}"
        try:
            response = self._session.post(
                url, json=json_body, timeout=self._config.timeout
            )
        except requests.RequestException as exc:
            raise JiraAmbiguousWriteError(
                f"POST {path} failed before a response was received (network "
                "error) -- the write may or may not have been applied; do not "
                "blindly retry"
            ) from exc

        if response.status_code == 401:
            raise JiraAuthenticationError(
                f"POST {path} failed: authentication invalid (HTTP 401)"
            )
        if response.status_code == 403:
            raise JiraPermissionError(
                f"POST {path} failed: missing permission (HTTP 403)"
            )
        if not response.ok:
            raise JiraWriteError(
                f"POST {path} failed: HTTP {response.status_code}: "
                f"{_sanitize_error_body(response)}"
            )

        if not response.content:
            return None
        try:
            return response.json()
        except ValueError:
            return None


#: Hard cap on any sanitized Jira error message we surface -- defends
#: against an unexpectedly large error body ending up in logs/exceptions.
_MAX_ERROR_MESSAGE_LENGTH = 500


def _sanitize_error_body(response: requests.Response) -> str:
    """Extract a short, safe summary from a Jira write-error response.

    Only reads the structured ``errorMessages`` (list[str]) / ``errors``
    (dict[str, str]) fields Jira documents for error responses, truncated
    defensively. Never echoes the raw response text or headers -- Jira
    never reflects credentials in error bodies, but this also protects
    against an oversized or unexpected body ending up in a log/exception.
    """
    try:
        body = response.json()
    except ValueError:
        return "<non-JSON error body>"
    if not isinstance(body, dict):
        return "<unexpected error body shape>"

    parts: list[str] = []
    messages = body.get("errorMessages")
    if isinstance(messages, list):
        parts.extend(str(m) for m in messages)
    errors = body.get("errors")
    if isinstance(errors, dict):
        parts.extend(f"{field}: {msg}" for field, msg in errors.items())

    summary = "; ".join(parts) if parts else "<no structured error details>"
    return summary[:_MAX_ERROR_MESSAGE_LENGTH]


def _retry_delay_seconds(response: requests.Response, attempt: int) -> float:
    """Compute a backoff delay, honoring ``Retry-After`` when Jira sends one.

    A server-supplied ``Retry-After`` is clamped to ``_MAX_RETRY_DELAY_SECONDS``
    -- an overly large or malicious value must never block a retry loop far
    longer than our own read timeout would.
    """
    retry_after = response.headers.get("Retry-After")
    if retry_after:
        try:
            return min(max(float(retry_after), 0.0), _MAX_RETRY_DELAY_SECONDS)
        except ValueError:
            pass
    return _RETRY_BACKOFF_SECONDS * attempt
