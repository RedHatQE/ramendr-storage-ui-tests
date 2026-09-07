"""Jira Test Result payload construction and reporting orchestration (Phase B/C).

Builds the ``fields`` payload for ``POST /issue`` and the Atlassian Document
Format (ADF) description Jira Cloud requires for rich-text fields, validates
a candidate parent Test Case before it's used, and orchestrates the full
create -> observe -> transition flow behind the ``JIRA_REPORT_RESULTS`` /
``JIRA_REPORT_DRY_RUN`` gates. See ``docs/jira-test-result-reporting.md``.

This module never assumes a newly created issue's initial status -- it
always re-fetches the issue and its available transitions before deciding
how to transition it (see :func:`report_test_result`).

Also provides :func:`jira_test_case_result` -- a per-scenario reporting
boundary (context manager, or manual ``start()``/``close_success()``/
``close_failure()`` for scenarios whose start and end aren't a single
lexical block) used to give independent Jira Test Results to independent
scenarios inside one larger pytest test (see
``tests/ui/sanity/test_sanity.py``).
"""

from __future__ import annotations

import logging
import time
import uuid
from dataclasses import dataclass
from datetime import timezone
from typing import Any, Mapping

from reporting.jira_client import JiraClient, JiraClientError
from reporting.jira_config import JiraReportingConfig
from reporting.jira_models import TestOutcome, TestResultExecution
from reporting.jira_test_cases import resolve_test_case_key

logger = logging.getLogger(__name__)

#: Fixed labels every Ramen DR automation Test Result must carry.
RAMEN_DR_LABELS: list[str] = ["ramen-dr", "automation"]

#: Fixed lines/values for the ADF description, per the Phase B/C spec.
_AUTOMATION_LINE = "Automation: pytest + Playwright"
_REPOSITORY_LINE = "Repository: ramendr-storage-ui-tests"
_TEST_FUNCTION = "tests/ui/sanity/test_sanity.py::test_sanity_disaster_recovery_ui"

#: Keep any sanitized failure text short -- never put a full stack trace in Jira.
MAX_FAILURE_SUMMARY_LENGTH = 500

_UNKNOWN = "unknown"

#: Compose Version is optional and we deliberately never fabricate one: no
#: stale sample value, no "TEST-COMPOSE-*"-style placeholder in a real Jira
#: issue. These are the only strings used when no real value is supplied --
#: distinct from _UNKNOWN so they can never be mistaken for an actual (if
#: unknown) build identifier.
_COMPOSE_NOT_SUPPLIED_SUMMARY = "not-supplied"
_COMPOSE_NOT_SUPPLIED_DESCRIPTION = "not supplied"


class ParentValidationError(RuntimeError):
    """Raised when a candidate parent Test Case fails validation.

    Never raised for a missing/unreachable parent (that's a plain
    ``JiraClientError`` from the GET itself) -- only for a parent that was
    fetched successfully but doesn't qualify.
    """


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
    """Build an Atlassian Document Format description, one paragraph per fact.

    Always includes: Automation, Repository, Test Case, Scenario, Test
    function, Compose Version, Git commit, CI run, Run ID, Executed at,
    Outcome. Includes Duration only when known, and Failure only for a
    non-PASS outcome with a non-empty (and always truncated/sanitized)
    ``failure_summary`` -- never a raw stack trace.
    """
    executed_at_utc = execution.executed_at.astimezone(timezone.utc)
    lines = [
        _AUTOMATION_LINE,
        _REPOSITORY_LINE,
        f"Test Case: {execution.test_case_key}",
        f"Scenario: {execution.scenario}",
        f"Test function: {_TEST_FUNCTION}",
        f"Compose Version: {execution.compose_version or _COMPOSE_NOT_SUPPLIED_DESCRIPTION}",
        f"Git commit: {execution.git_commit or _UNKNOWN}",
        f"CI run: {execution.ci_job_url or _UNKNOWN}",
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
# Parent validation
# --------------------------------------------------------------------------


def validate_parent_test_case(
    parent_issue: Mapping[str, Any], *, expected_project_key: str
) -> None:
    """Validate a fetched parent issue before attaching a Test Result to it.

    Checks (per the Phase B/C spec):
    - the parent's project key matches ``expected_project_key`` (RHELTEST)
    - the parent's issue type name is exactly "Test Case"
    - the parent carries the "ramen-dr" label

    Raises :class:`ParentValidationError` naming the specific failed check.
    Expects the shape returned by ``JiraClient.get_issue`` (a dict with a
    top-level ``fields`` key).
    """
    fields = parent_issue.get("fields") if isinstance(parent_issue, Mapping) else None
    if not isinstance(fields, Mapping):
        raise ParentValidationError("parent issue response has no 'fields'")

    project = fields.get("project") or {}
    project_key = project.get("key") if isinstance(project, Mapping) else None
    if project_key != expected_project_key:
        raise ParentValidationError(
            f"parent project is {project_key!r}, expected {expected_project_key!r}"
        )

    issuetype = fields.get("issuetype") or {}
    issuetype_name = issuetype.get("name") if isinstance(issuetype, Mapping) else None
    if issuetype_name != "Test Case":
        raise ParentValidationError(
            f"parent issue type is {issuetype_name!r}, expected 'Test Case'"
        )

    labels = fields.get("labels")
    if not isinstance(labels, list) or "ramen-dr" not in labels:
        raise ParentValidationError(
            f"parent is missing the required 'ramen-dr' label (has: {labels!r})"
        )


def summarize_parent(parent_issue: Mapping[str, Any]) -> dict[str, Any]:
    """Extract a small, safe-to-print summary of a fetched parent issue.

    Used to make the outcome of :func:`validate_parent_test_case` visible in
    CLI output/logs (none of these values are secrets) without printing the
    full raw Jira response.
    """
    fields = parent_issue.get("fields") if isinstance(parent_issue, Mapping) else None
    fields = fields if isinstance(fields, Mapping) else {}
    project = fields.get("project") or {}
    issuetype = fields.get("issuetype") or {}
    labels = fields.get("labels")
    labels = labels if isinstance(labels, list) else []
    return {
        "key": parent_issue.get("key") if isinstance(parent_issue, Mapping) else None,
        "project_key": project.get("key") if isinstance(project, Mapping) else None,
        "issuetype_name": (
            issuetype.get("name") if isinstance(issuetype, Mapping) else None
        ),
        "labels": labels,
        "has_ramen_dr_label": "ramen-dr" in labels,
    }


# --------------------------------------------------------------------------
# Orchestration
# --------------------------------------------------------------------------


@dataclass(frozen=True)
class ReportResult:
    """The outcome of one :func:`report_test_result` call."""

    dry_run: bool
    fields: dict[str, Any]
    issue_key: str | None = None
    initial_status: str | None = None
    final_status: str | None = None
    transition_id_used: str | None = None
    skipped_reason: str | None = None
    parent_summary: dict[str, Any] | None = None
    post_creation_verification: dict[str, Any] | None = None


def _fetch_issue_snapshot(
    client: JiraClient, issue_key: str, compose_field_id: str
) -> dict[str, Any]:
    """GET an issue and extract the small set of facts we verify post-write.

    Always a fresh read from Jira -- never derived from the payload we sent
    -- so this proves what Jira actually stored, not just what we asked for.
    """
    issue = client.get_issue(issue_key)
    fields = issue.get("fields") if isinstance(issue, Mapping) else None
    fields = fields if isinstance(fields, Mapping) else {}

    status = fields.get("status") or {}
    parent = fields.get("parent") or {}
    labels = fields.get("labels")

    return {
        "status_name": status.get("name") if isinstance(status, Mapping) else None,
        "parent_key": parent.get("key") if isinstance(parent, Mapping) else None,
        "labels": labels if isinstance(labels, list) else [],
        "compose_value": fields.get(compose_field_id),
    }


def _require_transition_available(
    transitions: list[dict[str, Any]], transition_id: str
) -> None:
    """Refuse to attempt a transition Jira didn't actually offer.

    Calling ``transition_issue`` with an id that isn't currently available
    would just fail with a 400 -- but checking first avoids an unnecessary
    write attempt and gives a much clearer error naming what *is* available.
    """
    available = {str(t.get("id")) for t in transitions}
    if str(transition_id) not in available:
        raise JiraClientError(
            f"transition id {transition_id!r} is not currently available for "
            f"this issue (available: {sorted(available)}); refusing to attempt it"
        )


def report_test_result(
    execution: TestResultExecution,
    *,
    client: JiraClient | None,
    config: JiraReportingConfig,
) -> ReportResult:
    """Build the payload and, only if enabled and not dry-run, report it to Jira.

    Three gates, checked in order, each stopping strictly before any *write*:

    1. ``config.report_results`` is False (default) -> returns immediately.
       The payload is still built and returned, but **zero** Jira calls are
       made (not even a GET).
    2. ``config.dry_run`` is True (default once reporting is enabled) ->
       validates the parent Test Case with a real (read-only) GET, but
       issues no writes.
    3. Otherwise -> creates the issue, re-fetches it to observe its *actual*
       current status and available transitions (never assumed), confirms
       the desired outcome's transition id is actually offered, transitions
       it, then re-fetches it once more to record the *final* status and to
       verify (from a fresh read, not from the payload we sent) that the
       parent, labels, and Compose Version were actually stored as intended.
    """
    fields = build_test_result_fields(execution, config=config)

    if not config.report_results:
        return ReportResult(
            dry_run=True,
            fields=fields,
            skipped_reason="reporting disabled (JIRA_REPORT_RESULTS=false)",
        )

    if client is None:
        raise ValueError("client is required when JIRA_REPORT_RESULTS is enabled")

    parent = client.get_issue(execution.test_case_key)
    parent_summary = summarize_parent(parent)
    try:
        validate_parent_test_case(parent, expected_project_key=config.project_key)
    except ParentValidationError as exc:
        # Attach the (safe, non-secret) summary so callers can show *what*
        # was actually observed even when validation fails.
        exc.parent_summary = parent_summary  # type: ignore[attr-defined]
        raise

    if config.dry_run:
        return ReportResult(
            dry_run=True,
            fields=fields,
            skipped_reason="dry-run (JIRA_REPORT_DRY_RUN=true)",
            parent_summary=parent_summary,
        )

    issue_key = client.create_issue(fields)

    # Never assume the initial status -- observe it, and the transitions
    # Jira actually offers, before attempting to move it anywhere.
    initial_snapshot = _fetch_issue_snapshot(
        client, issue_key, config.compose_version_field_id
    )
    transitions = client.get_transitions(issue_key)
    transition_id = config.transition_id_for(execution.outcome)
    _require_transition_available(transitions, transition_id)

    client.transition_issue(issue_key, transition_id)

    # Re-fetch once more: record the *actual* final status, and confirm --
    # from a fresh read, not from the payload we sent -- that the parent,
    # labels, and Compose Version were really stored as intended.
    final_snapshot = _fetch_issue_snapshot(
        client, issue_key, config.compose_version_field_id
    )

    return ReportResult(
        dry_run=False,
        fields=fields,
        issue_key=issue_key,
        initial_status=initial_snapshot["status_name"],
        final_status=final_snapshot["status_name"],
        transition_id_used=transition_id,
        parent_summary=parent_summary,
        post_creation_verification={
            "parent_key": final_snapshot["parent_key"],
            "parent_matches_expected": (
                final_snapshot["parent_key"] == execution.test_case_key
            ),
            "labels": final_snapshot["labels"],
            "labels_match_expected": set(final_snapshot["labels"])
            >= set(RAMEN_DR_LABELS),
            "compose_value": final_snapshot["compose_value"],
            "compose_absent_as_expected": (
                execution.compose_version is None
                and final_snapshot["compose_value"] is None
            )
            or (
                execution.compose_version is not None
                and final_snapshot["compose_value"] == execution.compose_version
            ),
        },
    )


# --------------------------------------------------------------------------
# Per-scenario reporting boundary (independent Jira Test Results from one
# larger pytest test -- Phase 1 pytest/sanity wiring).
# --------------------------------------------------------------------------


def _log_report_result(scenario_key: str, run_id: str, result: "ReportResult") -> None:
    """Log a non-secret summary of a completed report_test_result() call.

    Always logged at INFO regardless of dry-run/real, so ``pytest
    --log-cli-level=INFO`` (or any log capture) shows what would have
    happened/did happen for each scenario without needing to inspect a
    file. Never includes credentials -- ``result.fields``/``parent_summary``
    only ever contain Jira issue keys, labels, and text already destined
    for Jira itself.
    """
    logger.info(
        "Jira report for scenario %r (run_id=%s): dry_run=%s issue_key=%s "
        "initial_status=%s final_status=%s transition_id_used=%s "
        "skipped_reason=%s parent_summary=%s",
        scenario_key,
        run_id,
        result.dry_run,
        result.issue_key,
        result.initial_status,
        result.final_status,
        result.transition_id_used,
        result.skipped_reason,
        result.parent_summary,
    )


def derive_run_id(config: JiraReportingConfig) -> str:
    """Return ``config.run_id`` (``$JIRA_RUN_ID``) if set, else a fresh unique id.

    Call this **once** per pytest invocation/test and pass the same value to
    every :func:`jira_test_case_result` call made during that invocation --
    e.g. a failover scenario and a relocate scenario reported from the same
    ``test_sanity_disaster_recovery_ui`` run must share one run id, never
    generate independent ones.
    """
    return config.run_id or f"sanity-{uuid.uuid4().hex[:8]}-{int(time.time())}"


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
    swallows or replaces a real test failure, and a failure while
    **reporting** the FAIL result is only ever logged, never allowed to mask
    the original exception.

    A Jira reporting failure while closing a **PASS** (no competing original
    failure to protect) instead respects ``config.strict``: logged-only by
    default, or re-raised if ``JIRA_REPORT_STRICT=true``.

    When a scenario's start and end aren't a single lexical block (e.g. one
    branch of an adaptive/resume test does dialog validation, a later,
    separately-reached block does completion validation), use ``start()``
    plus explicit ``close_success()`` / ``close_failure(exc)`` calls instead
    of a ``with`` statement -- see the adaptive flow in
    ``tests/ui/sanity/test_sanity.py`` for a worked example. Each instance
    reports at most once: a second ``close_*`` call is a no-op, so a
    ``close_failure`` from an outer safety-net ``except`` block never
    double-reports a scenario whose own ``close_success()`` already ran.
    """

    def __init__(
        self,
        scenario_key: str,
        *,
        scenario: str,
        run_id: str,
        client: JiraClient | None,
        config: JiraReportingConfig,
    ) -> None:
        self.scenario_key = scenario_key
        self.scenario = scenario
        self.run_id = run_id
        self.client = client
        self.config = config
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

    def close_success(self) -> ReportResult | None:
        """Report PASS. A no-op if this boundary was already closed."""
        if self._closed:
            return None
        self._closed = True
        try:
            self.last_result = self._report(TestOutcome.PASS, failure_summary=None)
            _log_report_result(self.scenario_key, self.run_id, self.last_result)
            return self.last_result
        except Exception as jira_exc:
            logger.warning(
                "Jira PASS reporting failed for scenario %r (run_id=%s): %s",
                self.scenario_key,
                self.run_id,
                jira_exc,
            )
            if self.config.strict:
                raise
            return None

    def close_failure(self, exc: BaseException) -> ReportResult | None:
        """Attempt to report FAIL for *exc*. Never raises -- the original
        scenario exception is always what the caller re-raises, never this
        method's return value or any exception from Jira reporting itself.
        A no-op if this boundary was already closed (e.g. by a prior
        ``close_success()``)."""
        if self._closed:
            return None
        self._closed = True
        failure_summary = f"{type(exc).__name__}: {exc}"
        try:
            self.last_result = self._report(
                TestOutcome.FAIL, failure_summary=failure_summary
            )
            _log_report_result(self.scenario_key, self.run_id, self.last_result)
            return self.last_result
        except Exception as jira_exc:
            # The scenario already failed -- a secondary Jira-reporting
            # failure must never mask/replace that original failure, so it
            # is always just logged here, regardless of JIRA_REPORT_STRICT.
            logger.warning(
                "Jira FAIL reporting failed for scenario %r (run_id=%s); "
                "original scenario failure is preserved and still raised: %s",
                self.scenario_key,
                self.run_id,
                jira_exc,
            )
            return None

    def _report(
        self, outcome: TestOutcome, *, failure_summary: str | None
    ) -> ReportResult:
        test_case_key = resolve_test_case_key(self.scenario_key)
        duration_seconds = (
            time.monotonic() - self._started_at
            if self._started_at is not None
            else None
        )
        execution = TestResultExecution(
            test_case_key=test_case_key,
            scenario=self.scenario,
            outcome=outcome,
            run_id=self.run_id,
            compose_version=self.config.compose_version,
            git_commit=self.config.git_commit,
            ci_job_url=self.config.ci_job_url,
            duration_seconds=duration_seconds,
            failure_summary=failure_summary,
        )
        return report_test_result(execution, client=self.client, config=self.config)


def jira_test_case_result(
    scenario_key: str,
    *,
    scenario: str,
    run_id: str,
    client: JiraClient | None,
    config: JiraReportingConfig,
) -> JiraScenarioReporter:
    """Build a per-scenario Jira reporting boundary. See :class:`JiraScenarioReporter`.

    ``scenario_key`` must be an approved key in
    ``reporting.jira_test_cases.RAMENDR_JIRA_TEST_CASES`` -- an unapproved
    key raises ``KeyError`` only once the boundary is actually closed (i.e.
    reporting is attempted), not at construction time, so building one
    eagerly (e.g. before deciding whether it will ever be used) is safe.
    """
    return JiraScenarioReporter(
        scenario_key,
        scenario=scenario,
        run_id=run_id,
        client=client,
        config=config,
    )
