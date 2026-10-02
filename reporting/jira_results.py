"""Jira Test Result payload construction and reporting orchestration.

Builds the ``fields`` payload for ``POST /issue`` and the Atlassian Document
Format (ADF) description Jira Cloud requires for rich-text fields, then
creates the issue and transitions it to PASS/FAIL/BLOCKED -- behind the
``JIRA_REPORT_RESULTS`` / ``JIRA_REPORT_DRY_RUN`` gates (see
``reporting.jira_config``). See ``docs/jira-test-result-reporting.md``.

Deliberately does not re-fetch or re-validate anything from Jira before or
after writing: the project/issue-type/transition ids and the scenario ->
Jira Test Case key map are already known static values (see
``reporting.jira_config`` and ``reporting.jira_test_cases``), discovered
once against production Jira. A handful of scenarios does not need a
parent-validation GET before every create, or a re-fetch-and-diff after
every transition.

:func:`report_scenario_outcome` is the one shared "build -> report -> log
-> swallow-or-raise" policy used by both ``tests/ui/sanity/test_sanity.py``
(via :class:`JiraScenarioReporter` / :func:`jira_test_case_result`) and
``reporting.pytest_jira_plugin`` (the smoke aggregate, reported once at
session end) -- see its docstring.
"""

from __future__ import annotations

import functools
import logging
import time
import uuid
from dataclasses import dataclass
from datetime import timezone
from typing import Any

from reporting.jira_client import JiraClient, config_from_env
from reporting.jira_config import JiraReportingConfig
from reporting.jira_models import TestOutcome, TestResultExecution
from reporting.jira_test_cases import resolve_test_case_key

logger = logging.getLogger(__name__)

#: Fixed labels every Ramen DR automation Test Result must carry.
RAMEN_DR_LABELS: list[str] = ["ramen-dr", "automation"]

#: Keep any sanitized failure text short -- never put a full stack trace in Jira.
MAX_FAILURE_SUMMARY_LENGTH = 500

_UNKNOWN = "unknown"

#: Compose Version is optional and we deliberately never fabricate one: no
#: stale sample value, no "TEST-COMPOSE-*"-style placeholder in a real Jira
#: issue.
_COMPOSE_NOT_SUPPLIED_SUMMARY = "not-supplied"


class JiraCredentialsUnavailableError(RuntimeError):
    """Raised when Jira reporting is enabled (and not a dry run) but
    credentials are unavailable.

    An explicit opt-in (``JIRA_REPORT_RESULTS=true`` and
    ``JIRA_REPORT_DRY_RUN=false``) that then can't find
    ``JIRA_BASE_URL``/``JIRA_EMAIL``/``JIRA_API_TOKEN`` is a configuration
    mistake worth surfacing clearly and immediately, rather than silently
    skipping reporting -- never includes the credential values themselves
    (only which environment variables are missing, via the wrapped
    ``ValueError``).
    """


def build_jira_client(config: JiraReportingConfig) -> JiraClient | None:
    """Build the :class:`JiraClient` this run needs, or ``None`` if no real
    write will happen.

    No client (and no credentials) is needed unless both
    ``config.report_results`` is True AND ``config.dry_run`` is False --
    i.e. a real write is actually about to be attempted. Missing/empty
    ``JIRA_BASE_URL`` / ``JIRA_EMAIL`` / ``JIRA_API_TOKEN`` in that case
    raises :class:`JiraCredentialsUnavailableError` with a clear,
    actionable message -- a fail-fast check, never a silent skip.
    """
    if not config.report_results or config.dry_run:
        return None
    try:
        jira_config = config_from_env()
    except ValueError as exc:
        raise JiraCredentialsUnavailableError(
            "Jira reporting is enabled (JIRA_REPORT_RESULTS=true, "
            "JIRA_REPORT_DRY_RUN=false) but Jira credentials are unavailable: "
            f"{exc}. Supply JIRA_BASE_URL / JIRA_EMAIL / JIRA_API_TOKEN (e.g. "
            "from your CI secret store), or leave JIRA_REPORT_RESULTS=false "
            "(the default) / JIRA_REPORT_DRY_RUN=true for local development."
        ) from exc
    return JiraClient(jira_config)


# --------------------------------------------------------------------------
# Summary / description
# --------------------------------------------------------------------------


def build_summary(
    test_case_key: str, scenario: str, compose_version: str | None, run_id: str
) -> str:
    """Build the Jira summary: ``Ramen DR | <TEST_CASE_KEY> | <scenario> | <compose> | <run-id>``.

    When ``compose_version`` is ``None``/empty, uses the literal
    ``"not-supplied"`` token -- never a stale sample value or a
    ``TEST-COMPOSE-*``-style placeholder that could be mistaken for a real
    build identifier in a real Jira issue.
    """
    compose = compose_version or _COMPOSE_NOT_SUPPLIED_SUMMARY
    return f"Ramen DR | {test_case_key} | {scenario} | {compose} | {run_id}"


def _sanitize_failure_summary(text: str) -> str:
    """Collapse to a single line and hard-cap length -- never a full stack trace."""
    one_line = " ".join(text.split())
    if len(one_line) > MAX_FAILURE_SUMMARY_LENGTH:
        one_line = one_line[: MAX_FAILURE_SUMMARY_LENGTH - 3] + "..."
    return one_line


def _adf_paragraph(text: str) -> dict[str, Any]:
    return {"type": "paragraph", "content": [{"type": "text", "text": text}]}


def build_description_adf(execution: TestResultExecution) -> dict[str, Any]:
    """Build a minimal Atlassian Document Format description, one paragraph
    per fact: Scenario, Test function, Run ID, Executed at, Outcome.
    Includes Duration only when known, and Failure only for a non-PASS
    outcome with a non-empty (truncated/sanitized) ``failure_summary`` --
    never a raw stack trace.
    """
    executed_at_utc = execution.executed_at.astimezone(timezone.utc)
    lines = [
        f"Scenario: {execution.scenario}",
        f"Test function: {execution.test_function or _UNKNOWN}",
        f"Run ID: {execution.run_id}",
        f"Executed at: {executed_at_utc.strftime('%Y-%m-%dT%H:%M:%SZ')}",
    ]
    if execution.duration_seconds is not None:
        lines.append(f"Duration: {execution.duration_seconds:.1f}s")
    lines.append(f"Outcome: {execution.outcome.value}")
    if execution.outcome != TestOutcome.PASS and execution.failure_summary:
        lines.append(f"Failure: {_sanitize_failure_summary(execution.failure_summary)}")

    return {
        "type": "doc",
        "version": 1,
        "content": [_adf_paragraph(line) for line in lines],
    }


# --------------------------------------------------------------------------
# Field payload
# --------------------------------------------------------------------------


def build_test_result_fields(
    execution: TestResultExecution, *, config: JiraReportingConfig
) -> dict[str, Any]:
    """Build the ``fields`` dict for ``POST /issue`` for one Test Result.

    Every Ramen automation Test Result includes: project, issuetype,
    parent, labels, Compose Version (when available), summary, and an ADF
    description.
    """
    fields: dict[str, Any] = {
        "project": {"key": config.project_key},
        "issuetype": {"id": config.test_result_issue_type_id},
        "parent": {"key": execution.test_case_key},
        "labels": list(RAMEN_DR_LABELS),
        "summary": build_summary(
            execution.test_case_key,
            execution.scenario,
            execution.compose_version,
            execution.run_id,
        ),
        "description": build_description_adf(execution),
    }
    if execution.compose_version:
        fields[config.compose_version_field_id] = execution.compose_version
    return fields


# --------------------------------------------------------------------------
# Orchestration
# --------------------------------------------------------------------------


@dataclass(frozen=True)
class ReportResult:
    """The outcome of one :func:`report_test_result` call."""

    dry_run: bool
    fields: dict[str, Any]
    issue_key: str | None = None
    transition_id_used: str | None = None
    skipped_reason: str | None = None


def report_test_result(
    execution: TestResultExecution,
    *,
    client: JiraClient | None,
    config: JiraReportingConfig,
) -> ReportResult:
    """Build the payload and, only if enabled and not dry-run, create +
    transition the issue in Jira.

    Two gates, checked in order, each stopping strictly before any *write*
    (and, since neither needs Jira at all, before any Jira *call*):

    1. ``config.report_results`` is False (the default) -> returns
       immediately with the built payload; zero Jira calls.
    2. ``config.dry_run`` is True (the default) -> same: zero Jira calls,
       just the built payload.

    Otherwise, creates the issue and transitions it to the outcome's
    configured transition id (see ``JiraReportingConfig.transition_id_for``).
    """
    fields = build_test_result_fields(execution, config=config)

    if not config.report_results:
        return ReportResult(
            dry_run=True,
            fields=fields,
            skipped_reason="reporting disabled (JIRA_REPORT_RESULTS=false)",
        )
    if config.dry_run:
        return ReportResult(
            dry_run=True,
            fields=fields,
            skipped_reason="dry-run (JIRA_REPORT_DRY_RUN=true)",
        )
    if client is None:
        raise ValueError(
            "client is required when JIRA_REPORT_RESULTS is enabled and "
            "JIRA_REPORT_DRY_RUN is disabled"
        )

    issue_key = client.create_issue(fields)
    transition_id = config.transition_id_for(execution.outcome)
    try:
        client.transition_issue(issue_key, transition_id)
    except Exception as exc:
        # The issue was already created -- every caller that only shows the
        # exception text must still be able to find the real issue in
        # Jira, so the key travels with the error. The original exception
        # is preserved as __cause__.
        raise type(exc)(
            f"issue {issue_key} was created but transition_issue failed: {exc}"
        ) from exc

    return ReportResult(
        dry_run=False,
        fields=fields,
        issue_key=issue_key,
        transition_id_used=transition_id,
    )


def _log_report_result(scenario_key: str, run_id: str, result: ReportResult) -> None:
    """Log a non-secret summary of a completed report_test_result() call.

    Always logged at INFO regardless of dry-run/real, so ``pytest
    --log-cli-level=INFO`` (or any log capture) shows what would have
    happened/did happen for each scenario without needing to inspect a
    file. Never includes credentials.
    """
    logger.info(
        "Jira report for scenario %r (run_id=%s): dry_run=%s issue_key=%s "
        "transition_id_used=%s skipped_reason=%s",
        scenario_key,
        run_id,
        result.dry_run,
        result.issue_key,
        result.transition_id_used,
        result.skipped_reason,
    )


@functools.lru_cache(maxsize=1)
def _generated_run_id() -> str:
    """A fresh fallback run id, generated once per process and cached.

    Every reporting entrypoint sharing one pytest *invocation* (sanity's
    failover/relocate boundaries, the smoke aggregate) must resolve to the
    same run id even when nobody set ``$JIRA_RUN_ID`` -- this cache is what
    makes that hold without threading a shared fixture through everything.
    Test-only: call ``_generated_run_id.cache_clear()`` between tests that
    exercise this fallback path (see ``tests/reporting/conftest.py``).
    """
    return f"run-{uuid.uuid4().hex[:8]}-{int(time.time())}"


def get_session_run_id(config: JiraReportingConfig) -> str:
    """Return ``config.run_id`` (``$JIRA_RUN_ID``) if set, else a process-
    wide cached fallback id -- see :func:`_generated_run_id`."""
    return config.run_id or _generated_run_id()


def report_scenario_outcome(
    scenario_key: str,
    scenario: str,
    outcome: TestOutcome,
    *,
    run_id: str,
    client: JiraClient | None,
    config: JiraReportingConfig,
    failure_summary: str | None = None,
    duration_seconds: float | None = None,
    test_function: str | None = None,
    raise_on_error: bool = False,
) -> ReportResult | None:
    """Build, report, and log one scenario's outcome.

    The single shared "report this scenario outcome" policy used by both
    :class:`JiraScenarioReporter` (sanity's failover/relocate boundaries)
    and ``reporting.pytest_jira_plugin`` (the smoke aggregate, reported
    once at session end) -- previously reimplemented independently in
    both places (plus a third, unused, per-test marker path), risking
    drift between them.

    A Jira reporting failure is logged and swallowed (returns ``None``)
    unless ``raise_on_error`` is True. Callers protecting a real test
    failure or an already-committed PASS (sanity's ``close_failure()``,
    the smoke aggregate) must always pass ``False`` -- a secondary Jira
    failure must never replace or mask a real outcome. Only sanity's
    ``close_success()`` passes ``config.strict`` through here.
    """
    try:
        test_case_key = resolve_test_case_key(scenario_key)
        execution = TestResultExecution(
            test_case_key=test_case_key,
            scenario=scenario,
            outcome=outcome,
            run_id=run_id,
            compose_version=config.compose_version,
            duration_seconds=duration_seconds,
            failure_summary=failure_summary,
            test_function=test_function,
        )
        result = report_test_result(execution, client=client, config=config)
        _log_report_result(scenario_key, run_id, result)
        return result
    except Exception as exc:
        logger.warning(
            "Jira reporting failed for scenario %r (outcome=%s, run_id=%s): %s",
            scenario_key,
            outcome.value,
            run_id,
            exc,
        )
        if raise_on_error:
            raise
        return None


class JiraScenarioReporter:
    """One independent Jira Test Result reporting boundary for one scenario.

    Primary usage is as a context manager around a single contiguous block::

        with jira_test_case_result(
            "failover_primary_to_secondary",
            scenario="Failover primary to secondary",
            run_id=run_id, client=client, config=config,
        ):
            ... do the whole scenario ...

    Entering (``start()``, or ``__enter__``) records the start time. Exiting
    normally reports PASS. Exiting with an exception attempts to report FAIL
    (using the exception's type/message as the failure summary) and *always*
    re-raises the original exception unmodified -- Jira reporting never
    swallows or replaces a real test failure.

    When a scenario's start and end aren't a single lexical block (e.g. one
    branch of an adaptive/resume test does dialog validation, a later,
    separately-reached block does completion validation), use ``start()``
    plus explicit ``close_success()`` / ``close_failure(exc)`` calls instead
    of a ``with`` statement -- see the adaptive flow in
    ``tests/ui/sanity/test_sanity.py``. Each instance reports at most once:
    a second ``close_*`` call is a no-op.
    """

    def __init__(
        self,
        scenario_key: str,
        *,
        scenario: str,
        run_id: str,
        client: JiraClient | None,
        config: JiraReportingConfig,
        test_function: str | None = None,
    ) -> None:
        self.scenario_key = scenario_key
        self.scenario = scenario
        self.run_id = run_id
        self.client = client
        self.config = config
        self.test_function = test_function
        self.last_result: ReportResult | None = None
        self._started_at: float | None = None
        self._closed = False

    def start(self) -> "JiraScenarioReporter":
        """Record the scenario's start time. Idempotent-ish: call once per boundary."""
        self._started_at = time.monotonic()
        self._closed = False
        return self

    def __enter__(self) -> "JiraScenarioReporter":
        return self.start()

    def __exit__(self, exc_type, exc, tb) -> bool:
        if exc_type is None:
            self.close_success()
        else:
            assert isinstance(exc, BaseException)
            self.close_failure(exc)
        return False  # never suppress -- the original exception always propagates

    def _duration(self) -> float | None:
        return (
            time.monotonic() - self._started_at
            if self._started_at is not None
            else None
        )

    def close_success(self) -> ReportResult | None:
        """Report PASS. A no-op if this boundary was already closed. A Jira
        failure here respects ``config.strict`` (logged-only by default, or
        re-raised if ``JIRA_REPORT_STRICT=true``) -- there is no competing
        original failure to protect."""
        if self._closed:
            return None
        self._closed = True
        self.last_result = report_scenario_outcome(
            self.scenario_key,
            self.scenario,
            TestOutcome.PASS,
            run_id=self.run_id,
            client=self.client,
            config=self.config,
            duration_seconds=self._duration(),
            test_function=self.test_function,
            raise_on_error=self.config.strict,
        )
        return self.last_result

    def close_failure(self, exc: BaseException) -> ReportResult | None:
        """Attempt to report FAIL for *exc*. Never raises -- the original
        scenario exception is always what the caller re-raises, never this
        method's return value or any exception from Jira reporting itself.
        A no-op if this boundary was already closed (e.g. by a prior
        ``close_success()``)."""
        if self._closed:
            return None
        self._closed = True
        self.last_result = report_scenario_outcome(
            self.scenario_key,
            self.scenario,
            TestOutcome.FAIL,
            run_id=self.run_id,
            client=self.client,
            config=self.config,
            failure_summary=f"{type(exc).__name__}: {exc}",
            duration_seconds=self._duration(),
            test_function=self.test_function,
            raise_on_error=False,
        )
        return self.last_result


def jira_test_case_result(
    scenario_key: str,
    *,
    scenario: str,
    run_id: str,
    client: JiraClient | None,
    config: JiraReportingConfig,
    test_function: str | None = None,
) -> JiraScenarioReporter:
    """Build a per-scenario Jira reporting boundary. See :class:`JiraScenarioReporter`.

    ``scenario_key`` must be an approved key in
    ``reporting.jira_test_cases.RAMENDR_JIRA_TEST_CASES`` -- an unapproved
    key is refused (logged, not raised -- see :func:`report_scenario_outcome`)
    only once the boundary is actually closed, not at construction time.

    ``test_function`` is shown verbatim in the Jira description's "Test
    function" line (falls back to "unknown" when omitted).
    """
    return JiraScenarioReporter(
        scenario_key,
        scenario=scenario,
        run_id=run_id,
        client=client,
        config=config,
        test_function=test_function,
    )
