"""Environment-driven configuration for Jira Test Result reporting.

**Phase 2 (normal-default) behavior:** every supported RamenDR automation
execution reports its result to Jira, PASS or FAIL, without anyone having to
export reporting flags -- ``JIRA_REPORT_RESULTS`` and ``JIRA_REPORT_DRY_RUN``
both now default to the *real-write* setting (``true`` / ``false``
respectively). This is a deliberate reversal of the Phase B/C pilot's
opt-in-only defaults (see git history / ``docs/jira-test-result-reporting.md``
"Migration: pilot opt-in -> normal default" for the rationale): the pilot is
over, and RamenDR's Jira dashboard requires every real execution -- including
failures -- to be visible.

Both flags remain fully overridable via the environment for development/
debugging: set ``JIRA_REPORT_RESULTS=false`` to make a local run perform
*zero* Jira calls (no credentials needed), or ``JIRA_REPORT_DRY_RUN=true`` to
keep reporting "on" (still validates the parent Test Case with a real
read-only GET) while deliberately skipping every write. See
``reporting.jira_results.build_jira_client()`` for what happens when
reporting is enabled but credentials are missing: a clear, fail-fast error,
never a silent skip.

None of the values here are credentials -- this config is safe to log/print
(unlike ``reporting.jira_client.JiraConfig``, which must never be printed as
a whole).
"""

from __future__ import annotations

import os
from dataclasses import dataclass
from typing import Mapping

from reporting.jira_models import TestOutcome

#: RHELTEST production values discovered in Phase A. Used as defaults so the
#: tool works out of the box against the reviewed schema; every value is
#: still overridable via the matching environment variable.
DEFAULT_PROJECT_KEY = "RHELTEST"
DEFAULT_TEST_RESULT_ISSUE_TYPE_ID = "10272"
DEFAULT_COMPOSE_VERSION_FIELD_ID = "customfield_11500"
DEFAULT_PASS_TRANSITION_ID = "3"
DEFAULT_FAIL_TRANSITION_ID = "4"
DEFAULT_BLOCKED_TRANSITION_ID = "5"


#: Recognized truthy/falsy spellings for boolean env vars (case-insensitive).
_TRUE_VALUES = frozenset({"1", "true", "yes", "on"})
_FALSE_VALUES = frozenset({"0", "false", "no", "off"})


def _bool_env(source: Mapping[str, str], name: str, default: bool) -> bool:
    """Parse a boolean env var, defaulting when unset/empty.

    Unset or empty returns ``default``. An explicit truthy/falsy spelling
    (see ``_TRUE_VALUES``/``_FALSE_VALUES``) returns the matching bool. Any
    other value raises ``ValueError`` rather than silently treating a typo
    (e.g. ``JIRA_REPORT_DRY_RUN=ture``) as falsy -- for a safety flag like
    ``JIRA_REPORT_DRY_RUN`` (default ``True``), silently coercing a typo to
    ``False`` would disable a write-safety gate without any indication.
    """
    raw = source.get(name)
    if raw is None or raw == "":
        return default
    normalized = raw.strip().lower()
    if normalized in _TRUE_VALUES:
        return True
    if normalized in _FALSE_VALUES:
        return False
    raise ValueError(
        f"Invalid boolean value for {name}={raw!r}; expected one of "
        f"{sorted(_TRUE_VALUES | _FALSE_VALUES)}"
    )


@dataclass(frozen=True)
class JiraReportingConfig:
    """Non-credential Jira reporting configuration. Safe to log/print."""

    report_results: bool
    dry_run: bool
    strict: bool

    project_key: str
    test_result_issue_type_id: str
    compose_version_field_id: str

    pass_transition_id: str
    fail_transition_id: str
    blocked_transition_id: str

    compose_version: str | None
    run_id: str | None
    ci_job_url: str | None
    git_commit: str | None

    def transition_id_for(self, outcome: TestOutcome) -> str:
        """Return the configured workflow transition id for an outcome."""
        mapping = {
            TestOutcome.PASS: self.pass_transition_id,
            TestOutcome.FAIL: self.fail_transition_id,
            TestOutcome.BLOCKED: self.blocked_transition_id,
        }
        try:
            return mapping[outcome]
        except KeyError as exc:  # pragma: no cover - outcome is a closed enum
            raise ValueError(
                f"No transition id configured for outcome {outcome!r}"
            ) from exc


def reporting_config_from_env(
    env: Mapping[str, str] | None = None,
) -> JiraReportingConfig:
    """Build a :class:`JiraReportingConfig` from environment variables.

    Defaults are the *normal* (real-reporting) behavior: ``report_results``
    defaults to ``True`` and ``dry_run`` defaults to ``False``, so an
    ordinary ``pytest ...`` invocation -- with Jira credentials supplied by
    the environment/CI secret store -- reports every result automatically.
    Set ``JIRA_REPORT_RESULTS=false`` or ``JIRA_REPORT_DRY_RUN=true``
    explicitly to opt out for local development/debugging.
    """
    source = env if env is not None else os.environ
    return JiraReportingConfig(
        report_results=_bool_env(source, "JIRA_REPORT_RESULTS", True),
        dry_run=_bool_env(source, "JIRA_REPORT_DRY_RUN", False),
        strict=_bool_env(source, "JIRA_REPORT_STRICT", False),
        project_key=source.get("JIRA_PROJECT_KEY") or DEFAULT_PROJECT_KEY,
        test_result_issue_type_id=(
            source.get("JIRA_TEST_RESULT_ISSUE_TYPE_ID")
            or DEFAULT_TEST_RESULT_ISSUE_TYPE_ID
        ),
        compose_version_field_id=(
            source.get("JIRA_COMPOSE_VERSION_FIELD_ID")
            or DEFAULT_COMPOSE_VERSION_FIELD_ID
        ),
        pass_transition_id=(
            source.get("JIRA_PASS_TRANSITION_ID") or DEFAULT_PASS_TRANSITION_ID
        ),
        fail_transition_id=(
            source.get("JIRA_FAIL_TRANSITION_ID") or DEFAULT_FAIL_TRANSITION_ID
        ),
        blocked_transition_id=(
            source.get("JIRA_BLOCKED_TRANSITION_ID") or DEFAULT_BLOCKED_TRANSITION_ID
        ),
        compose_version=source.get("RAMENDR_COMPOSE_VERSION") or None,
        run_id=source.get("JIRA_RUN_ID") or None,
        ci_job_url=source.get("CI_JOB_URL") or None,
        git_commit=source.get("GIT_COMMIT") or None,
    )
