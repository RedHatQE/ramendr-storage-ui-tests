"""Pytest integration: aggregate Jira Test Result reporting for smoke.

This is the *only* module in ``reporting/`` that imports ``pytest`` --
``reporting/jira_*.py`` stay pytest-agnostic. Everything here is glue: it
reads outcomes pytest already computed and calls the same
``reporting.jira_results.report_scenario_outcome()`` used by
``tests/ui/sanity/test_sanity.py``'s ``JiraScenarioReporter``.

**``jira_aggregate_test_case`` -- one Jira Test Result for a whole group**::

    @pytest.mark.jira_aggregate_test_case(
        "some_approved_scenario_id", scenario="Human-readable scenario label"
    )
    def test_one_check_in_the_group(...):
        ...

    @pytest.mark.jira_aggregate_test_case(
        "some_approved_scenario_id", scenario="Human-readable scenario label"
    )
    def test_another_check_in_the_group(...):
        ...

Used when several pytest tests together represent *one* Jira Test Case
(e.g. every applicable ``tests/ui/smoke/test_smoke.py`` check together
represent ``deployment_smoke_validation`` / RHELTEST-3612) -- reporting one
Test Result per constituent test would be noisy and would not answer "did
this Test Case pass" without reading every row. Instead, every test sharing
one ``scenario_id`` is accumulated (in ``pytest_runtest_makereport``) and
reported **exactly once**, at ``pytest_sessionfinish``:

- Skipped tests (e.g. a variant-specific ``skipif``) are never counted --
  neither as a pass nor a failure. If *every* test carrying a given
  ``scenario_id`` is skipped this invocation (nothing applicable to the
  active ``PATTERN_VARIANT`` actually ran), nothing is reported at all.
- A fixture/setup-phase failure for a constituent test is likewise never
  counted -- an environment/pre-deployment/provisioning problem that means
  the test's own body never started is not a *test* failure, and must not
  create a Jira Test Result. If that leaves zero counted tests for a
  scenario, nothing is reported.
- If every counted test passed, the aggregate reports **PASS** exactly
  once. If one or more failed, the aggregate reports **FAIL** exactly
  once, with every failing node id and a concise failure message included
  in the Jira description -- never one FAIL per failing test.
- A **teardown**-phase failure is only ever considered when it follows that
  same test's own *passing* ``"call"`` phase -- i.e. the test body itself
  already executed and succeeded, and cleanup belonging to that executed
  scenario then failed. That flips the test from contributing to PASS to
  contributing to FAIL (with a ``"(teardown) ..."``-prefixed message).
  Teardown outcomes are otherwise ignored: after a skip, after a setup
  failure (the body never started), or after a ``"call"``-phase failure
  (already counted; not duplicated).

``scenario_id`` must already be an approved key in
``reporting.jira_test_cases.RAMENDR_JIRA_TEST_CASES``.

Enable this plugin from the repo's root ``conftest.py`` via
``pytest_plugins = ["reporting.pytest_jira_plugin"]`` (pytest only honors
``pytest_plugins`` declared in the *root* conftest).
"""

from __future__ import annotations

import logging
from dataclasses import dataclass, field
from typing import Any

import pytest

from reporting.jira_config import JiraReportingConfig, reporting_config_from_env
from reporting.jira_models import TestOutcome
from reporting.jira_results import (
    JiraCredentialsUnavailableError,
    build_jira_client,
    get_session_run_id,
    report_scenario_outcome,
)

logger = logging.getLogger(__name__)

_AGGREGATE_MARKER_NAME = "jira_aggregate_test_case"

#: ``pytest.Config.stash`` keys -- see https://docs.pytest.org/en/stable/reference/reference.html#stash
_CLIENT_STASH_KEY = pytest.StashKey[Any]()
_CONFIG_STASH_KEY = pytest.StashKey[JiraReportingConfig]()
_AGGREGATE_STASH_KEY = pytest.StashKey[dict]()


@dataclass
class _AggregateScenarioState:
    """Accumulated outcome for one ``jira_aggregate_test_case`` scenario id.

    Populated incrementally by ``pytest_runtest_makereport`` as each
    constituent test's ``"call"`` (and, conditionally, ``"teardown"``) phase
    completes; consumed exactly once by ``pytest_sessionfinish``.
    """

    scenario: str
    considered: int = 0
    total_duration_seconds: float = 0.0
    failures: list[tuple[str, str]] = field(default_factory=list)
    #: node ids whose "call" phase passed -- used to decide whether a later
    #: teardown failure for that same node id reflects a real failure of an
    #: executed scenario (vs. cleanup of a test that was skipped or never
    #: started, or a teardown failure piled on top of an already-failed call).
    passed_nodeids: set[str] = field(default_factory=set)
    #: The module path (nodeid before "::") of the first counted test --
    #: shown as this aggregate's "Test function" in Jira, since it covers
    #: many individual test functions, not just one. Set once, from
    #: whichever test is considered first.
    module_path: str | None = None


def pytest_configure(config: pytest.Config) -> None:
    """Register the marker so ``--strict-markers`` accepts it."""
    config.addinivalue_line(
        "markers",
        f"{_AGGREGATE_MARKER_NAME}(scenario_id, *, scenario): accumulate this "
        "test's PASS/FAIL into a single Jira Test Result shared by every "
        "other test carrying the same scenario_id, reported once at session "
        "end (PASS only if every applicable test in the group passed).",
    )


def pytest_collection_modifyitems(
    config: pytest.Config, items: list[pytest.Item]
) -> None:
    """Fail fast, once, at collection time -- not buried in the first marked
    test's report -- if any collected item needs Jira reporting but
    credentials are unavailable.

    Only builds the client/config once per session (cached on
    ``config.stash``); every other hook in this module reuses that cache.
    """
    needs_jira = any(_aggregate_marker_for(item) is not None for item in items)
    if not needs_jira:
        return
    _get_or_build_client(config)


def _aggregate_marker_for(item: pytest.Item) -> pytest.Mark | None:
    return item.get_closest_marker(_AGGREGATE_MARKER_NAME)


def _scenario_id_and_label(marker: pytest.Mark) -> tuple[str, str]:
    try:
        scenario_id = marker.args[0]
    except IndexError:
        raise TypeError(
            f"@pytest.mark.{_AGGREGATE_MARKER_NAME}(...) requires a positional "
            "scenario_id argument"
        ) from None
    scenario = marker.kwargs.get("scenario") or scenario_id
    return scenario_id, scenario


def _get_or_build_client(config: pytest.Config) -> Any:
    """Return the cached ``JiraClient | None`` for this session, building
    (and caching the outcome of) it exactly once. A
    ``JiraCredentialsUnavailableError`` raised on the first call propagates
    to every subsequent call too -- it is never retried/re-masked."""
    if _CLIENT_STASH_KEY not in config.stash:
        reporting_config = reporting_config_from_env()
        config.stash[_CONFIG_STASH_KEY] = reporting_config
        config.stash[_CLIENT_STASH_KEY] = build_jira_client(reporting_config)
    return config.stash[_CLIENT_STASH_KEY]


@pytest.hookimpl(hookwrapper=True)
def pytest_runtest_makereport(item: pytest.Item, call: pytest.CallInfo):
    outcome = yield

    if call.when == "setup":
        # A fixture/setup-phase result (pass, fail, or skip) means the
        # test's own body hasn't started yet -- an environment/
        # pre-deployment/provisioning problem here is never a test outcome,
        # so it is never reported/counted.
        return

    marker = _aggregate_marker_for(item)
    if marker is None:
        return

    if call.when == "call":
        _accumulate_aggregate(item, call, outcome, marker)
    elif call.when == "teardown":
        _accumulate_aggregate_teardown(item, call, outcome, marker)


def _accumulate_aggregate(
    item: pytest.Item,
    call: pytest.CallInfo,
    outcome: Any,
    marker: pytest.Mark,
) -> None:
    """Fold one ``jira_aggregate_test_case``-marked test's outcome into its
    scenario's running state. Never reports to Jira directly -- see
    :func:`pytest_sessionfinish`."""
    report = outcome.get_result()
    if report.skipped:
        # Not applicable to the active PATTERN_VARIANT (or otherwise
        # skipped) -- never counted, so it can never make the aggregate
        # FAIL, and never single-handedly makes it "ran" either.
        return
    if not (report.passed or report.failed):
        return

    scenario_id, scenario = _scenario_id_and_label(marker)

    states: dict[str, _AggregateScenarioState] = item.config.stash.setdefault(
        _AGGREGATE_STASH_KEY, {}
    )
    state = states.setdefault(scenario_id, _AggregateScenarioState(scenario=scenario))
    if state.module_path is None:
        state.module_path = item.nodeid.split("::", 1)[0]
    state.considered += 1
    state.total_duration_seconds += report.duration or 0.0
    if report.failed:
        message = str(call.excinfo.value) if call.excinfo is not None else "test failed"
        state.failures.append((item.nodeid, message))
    else:
        # Recorded so a later teardown failure for this same node id can be
        # recognized as "cleanup of a scenario that actually ran and
        # passed" -- see _accumulate_aggregate_teardown.
        state.passed_nodeids.add(item.nodeid)


def _accumulate_aggregate_teardown(
    item: pytest.Item,
    call: pytest.CallInfo,
    outcome: Any,
    marker: pytest.Mark,
) -> None:
    """Fold a teardown-phase failure into its scenario's state, but only
    when it reflects a failure of a smoke check that actually executed.

    A teardown failure is otherwise indistinguishable from ordinary
    environment/cleanup noise, so it is only counted when this same node id
    already has a *passing* "call" phase on record for this scenario --
    i.e. the test body ran and succeeded, and cleanup that belongs to that
    executed scenario then failed. It is ignored when:

    - the test was skipped or never reached "call" (a setup failure) --
      there's no executed scenario for this teardown to reflect a failure
      of, so nothing is reported;
    - the "call" phase itself already failed -- already counted as a
      failure for this node id; a second entry would be redundant.
    """
    report = outcome.get_result()
    if not report.failed:
        return

    scenario_id, _scenario = _scenario_id_and_label(marker)
    states: dict[str, _AggregateScenarioState] = item.config.stash.setdefault(
        _AGGREGATE_STASH_KEY, {}
    )
    state = states.get(scenario_id)
    if state is None or item.nodeid not in state.passed_nodeids:
        return

    message = str(call.excinfo.value) if call.excinfo is not None else "teardown failed"
    state.failures.append((item.nodeid, f"(teardown) {message}"))


def pytest_sessionfinish(session: pytest.Session, exitstatus: int) -> None:
    """Report every accumulated ``jira_aggregate_test_case`` scenario exactly
    once, now that every test has run.

    A scenario with zero counted (non-skipped, ``"call"``-phase) tests --
    every constituent test was skipped for the active variant, or none ever
    reached the call phase -- reports nothing at all.
    """
    config = session.config
    states: dict[str, _AggregateScenarioState] = config.stash.get(
        _AGGREGATE_STASH_KEY, {}
    )
    if not states:
        return

    try:
        client = _get_or_build_client(config)
    except JiraCredentialsUnavailableError as exc:
        logger.warning(
            "Skipping aggregate Jira reporting for %d scenario(s) (%s): %s",
            len(states),
            ", ".join(sorted(states)),
            exc,
        )
        return

    reporting_config = config.stash[_CONFIG_STASH_KEY]
    run_id = get_session_run_id(reporting_config)

    for scenario_id, state in states.items():
        if state.considered == 0:
            continue

        failure_summary = None
        if state.failures:
            failure_summary = "; ".join(
                f"{nodeid}: {message}" for nodeid, message in state.failures
            )

        report_scenario_outcome(
            scenario_id,
            state.scenario,
            TestOutcome.FAIL if state.failures else TestOutcome.PASS,
            run_id=run_id,
            client=client,
            config=reporting_config,
            failure_summary=failure_summary,
            duration_seconds=state.total_duration_seconds,
            test_function=state.module_path,
            raise_on_error=False,
        )
