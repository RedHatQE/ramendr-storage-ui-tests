"""Minimal Jira Cloud REST API v3 client: create + transition issues.

Deliberately thin: we already know (from a one-time, now-removed discovery
pass against the production `RHELTEST` project) the project key, the "Test
Result" issue type id, and the PASS/FAIL/BLOCKED transition ids -- see
``reporting/jira_config.py``'s defaults and ``reporting/jira_test_cases.py``'s
static scenario -> Jira Test Case key map. This client has exactly the two
write operations that static knowledge lets us call with confidence:
``create_issue`` and ``transition_issue``. It does not re-fetch/re-validate
anything from Jira before or after -- see ``docs/jira-test-result-reporting.md``.

Writes are **never** retried automatically: Jira issue creation and
transitions are not safely repeatable, and a network error during a POST
leaves the outcome ambiguous (the request may have reached Jira and been
applied even though no response was seen). See ``JiraAmbiguousWriteError``.

Never log or print credentials: this module never includes the API token,
email, or ``Authorization`` header in an exception message or return value.
Error responses from Jira are sanitized to their structured
``errorMessages``/``errors`` fields only, truncated defensively -- never the
raw response body/headers.
"""

from __future__ import annotations

import os
from dataclasses import dataclass
from typing import Any, Mapping

import requests

#: (connect, read) timeout in seconds. Every request is bounded explicitly;
#: never rely on requests' default (no timeout).
DEFAULT_TIMEOUT: tuple[float, float] = (10.0, 30.0)

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
    transition. Instead, verify against Jira directly before retrying.
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
    """Jira Cloud REST API v3 client: ``create_issue`` + ``transition_issue``
    only. Neither is ever retried automatically (see module docstring)."""

    def __init__(
        self, config: JiraConfig, session: requests.Session | None = None
    ) -> None:
        self._config = config
        self._session = session or requests.Session()
        self._session.auth = (config.email, config.api_token)
        self._session.headers.update({"Accept": "application/json"})

    def create_issue(self, fields: dict[str, Any]) -> str:
        """POST /issue. Creates a Jira issue from ``fields`` and returns its key.

        WRITE operation, never retried automatically. Callers are
        responsible for any idempotency guarantees they need -- this client
        has no way to know whether a prior ambiguous failure already
        created the issue.
        """
        result = self._post("issue", json_body={"fields": fields})
        key = result.get("key") if isinstance(result, dict) else None
        if not key:
            raise JiraClientError("POST issue succeeded but response had no 'key'")
        return key

    def transition_issue(self, issue_key: str, transition_id: str) -> None:
        """POST /issue/{key}/transitions. Applies a workflow transition.

        WRITE operation, never retried automatically. ``transition_id``
        must be one of the ids already configured in
        ``reporting.jira_config`` for this workflow (PASS/FAIL/BLOCKED) --
        this client does not check availability first.
        """
        self._post(
            f"issue/{issue_key}/transitions",
            json_body={"transition": {"id": str(transition_id)}},
        )

    def _post(self, path: str, *, json_body: dict[str, Any]) -> Any:
        """Issue a single POST against the Jira REST API v3. NEVER retried.

        Jira writes are not idempotent, so retrying a POST that may have
        already been applied (e.g. after a timeout) risks creating a
        duplicate issue or double-applying a transition -- callers get an
        explicit :class:`JiraAmbiguousWriteError` instead so they can decide
        what's safe to do next.
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
