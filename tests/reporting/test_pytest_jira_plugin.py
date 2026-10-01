"""Unit tests for reporting.pytest_jira_plugin: the marker-based automatic
Jira Test Result reporting hook used by smoke (and available to any other
pytest suite).

``pytest_runtest_makereport`` is a ``hookwrapper`` -- pluggy normally drives
it, not a direct caller -- so these tests drive the generator manually
(advance to its ``yield``, then ``.send()`` a fake pluggy result object).
Fake ``Item``/``CallInfo``/report objects stand in for pytest's real ones;
``pytest.Stash``/``pytest.StashKey`` are the real classes (used exactly as
pytest itself uses them), so the session-caching behavior under test is
faithful, not reimplemented. Jira is always mocked; no network is used.
"""

from __future__ import annotations

import logging

import pytest

import reporting.pytest_jira_plugin as plugin
from reporting.jira_client import JiraWriteError
from reporting.jira_results import JiraCredentialsUnavailableError


class FakeClient:
    """Minimal fake JiraClient -- same shape as the fakes in
    test_jira_scenario_reporter.py / test_sanity_jira_wiring.py."""

    def __init__(self, *, fail_create: bool = False):
        self.calls: list[str] = []
        self.created: list[dict] = []
        self.transitioned: list[tuple[str, str]] = []
        self._fail_create = fail_create
        self._next_seq = 9000
        self._status_by_key: dict[str, str] = {}

    def get_issue(self, issue_key, *, expand=None):
        self.calls.append("get_issue")
        return {
            "key": issue_key,
            "fields": {
                "project": {"key": "RHELTEST"},
                "issuetype": {"name": "Test Case"},
                "labels": ["ramen-dr", "automation"],
            },
        }

    def get_transitions(self, issue_key):
        self.calls.append("get_transitions")
        return [
            {"id": "3", "name": "PASS"},
            {"id": "4", "name": "FAIL"},
        ]

    def create_issue(self, fields):
        self.calls.append("create_issue")
        if self._fail_create:
            raise JiraWriteError("simulated create failure")
        self._next_seq += 1
        key = f"RHELTEST-{self._next_seq}"
        self.created.append(fields)
        self._status_by_key[key] = "New"
        return key

    def transition_issue(self, issue_key, transition_id):
        self.calls.append("transition_issue")
        self.transitioned.append((issue_key, str(transition_id)))


class _FakeConfig:
    def __init__(self):
        self.stash = pytest.Stash()


class _FakeItem:
    def __init__(
        self,
        *,
        marker=None,
        nodeid="tests/ui/smoke/test_x.py::test_x",
        config=None,
    ):
        self._marker = marker
        self.nodeid = nodeid
        # Real pytest items within one session all share the *same*
        # session-wide config object -- default to a fresh one (fine for
        # single-item tests), but callers accumulating multiple items into
        # one aggregate scenario must pass one shared `config` explicitly.
        self.config = config if config is not None else _FakeConfig()

    def get_closest_marker(self, name):
        if self._marker is not None and self._marker.name == name:
            return self._marker
        return None


class _FakeExcInfo:
    def __init__(self, value):
        self.value = value


class _FakeCall:
    def __init__(self, *, when="call", excinfo=None):
        self.when = when
        self.excinfo = excinfo


class _FakeReport:
    def __init__(self, *, passed=False, failed=False, skipped=False, duration=1.23):
        self.passed = passed
        self.failed = failed
        self.skipped = skipped
        self.duration = duration


class _FakeOutcome:
    """Mimics pluggy's _Result -- the object a hookwrapper's `yield`
    resolves to once every non-wrapper hookimpl has run."""

    def __init__(self, report):
        self._report = report

    def get_result(self):
        return self._report


def _drive_makereport(item, call, report):
    """Manually drive the pytest_runtest_makereport hookwrapper generator."""
    gen = plugin.pytest_runtest_makereport(item=item, call=call)
    next(gen)  # advance to `outcome = yield`
    try:
        gen.send(_FakeOutcome(report))
    except StopIteration:
        pass
    else:  # pragma: no cover - defensive; a hookwrapper must stop here
        raise AssertionError("hookwrapper did not stop after being resumed")


def _jira_marker(scenario_id: str = "failover_primary_to_secondary", **kwargs):
    kwargs.setdefault("scenario", "Some scenario label")
    return pytest.mark.jira_test_case(scenario_id, **kwargs).mark


def _aggregate_marker(scenario_id: str = "deployment_smoke_validation", **kwargs):
    kwargs.setdefault("scenario", "ODF deployment smoke validation")
    return pytest.mark.jira_aggregate_test_case(scenario_id, **kwargs).mark


def _enable_jira_env(monkeypatch, **overrides):
    env = {
        "JIRA_REPORT_RESULTS": "true",
        "JIRA_REPORT_DRY_RUN": "false",
        "JIRA_BASE_URL": "https://example.invalid",
        "JIRA_EMAIL": "test@example.invalid",
        "JIRA_API_TOKEN": "not-a-real-token",
    }
    env.update(overrides)
    for key, value in env.items():
        if value is None:
            monkeypatch.delenv(key, raising=False)
        else:
            monkeypatch.setenv(key, value)


# --------------------------------------------------------------------------
# pytest_configure -- marker registration
# --------------------------------------------------------------------------


def test_pytest_configure_registers_the_marker():
    lines: list[tuple[str, str]] = []

    class _Config:
        def addinivalue_line(self, section, line):
            lines.append((section, line))

    plugin.pytest_configure(_Config())
    assert lines
    section, line = lines[0]
    assert section == "markers"
    assert line.startswith("jira_test_case(")


# --------------------------------------------------------------------------
# Never reports: unmarked, skipped, or non-"call"-phase
# --------------------------------------------------------------------------


def test_unmarked_test_makes_zero_jira_calls(monkeypatch):
    _enable_jira_env(monkeypatch)
    client = FakeClient()
    monkeypatch.setattr("reporting.jira_results.JiraClient", lambda config: client)

    item = _FakeItem(marker=None)
    _drive_makereport(item, _FakeCall(when="call"), _FakeReport(passed=True))

    assert client.calls == []
    # No credentials were even required -- the client was never built.
    assert plugin._CLIENT_STASH_KEY not in item.config.stash


def test_skipped_marked_test_reports_nothing(monkeypatch):
    _enable_jira_env(monkeypatch)
    client = FakeClient()
    monkeypatch.setattr("reporting.jira_results.JiraClient", lambda config: client)

    item = _FakeItem(marker=_jira_marker())
    _drive_makereport(item, _FakeCall(when="call"), _FakeReport(skipped=True))

    assert client.calls == []


def test_setup_phase_failure_reports_nothing_even_with_marker(monkeypatch):
    """A fixture/setup failure means the scenario body never ran -- never
    fabricate a Jira result for it (same rule as the sanity DR boundaries)."""
    _enable_jira_env(monkeypatch)
    client = FakeClient()
    monkeypatch.setattr("reporting.jira_results.JiraClient", lambda config: client)

    item = _FakeItem(marker=_jira_marker())
    _drive_makereport(item, _FakeCall(when="setup"), _FakeReport(failed=True))

    assert client.calls == []


# --------------------------------------------------------------------------
# PASS / FAIL automatic reporting for the "call" phase
# --------------------------------------------------------------------------


def test_passing_marked_test_reports_pass(monkeypatch):
    _enable_jira_env(monkeypatch)
    client = FakeClient()
    monkeypatch.setattr("reporting.jira_results.JiraClient", lambda config: client)

    item = _FakeItem(marker=_jira_marker("failover_primary_to_secondary"))
    _drive_makereport(item, _FakeCall(when="call"), _FakeReport(passed=True))

    assert client.created[0]["parent"] == {"key": "RHELTEST-3600"}
    assert client.transitioned == [(client.transitioned[0][0], "3")]  # PASS


def test_failing_marked_test_reports_fail_with_summary(monkeypatch):
    _enable_jira_env(monkeypatch)
    client = FakeClient()
    monkeypatch.setattr("reporting.jira_results.JiraClient", lambda config: client)

    item = _FakeItem(marker=_jira_marker("relocate_secondary_to_primary"))
    exc = RuntimeError("smoke check boom")
    _drive_makereport(
        item,
        _FakeCall(when="call", excinfo=_FakeExcInfo(exc)),
        _FakeReport(failed=True, duration=4.5),
    )

    assert client.created[0]["parent"] == {"key": "RHELTEST-3610"}
    assert client.transitioned == [(client.transitioned[0][0], "4")]  # FAIL
    description_text = str(client.created[0]["description"])
    assert "smoke check boom" in description_text


def test_scenario_kwarg_is_used_in_the_created_summary(monkeypatch):
    _enable_jira_env(monkeypatch)
    client = FakeClient()
    monkeypatch.setattr("reporting.jira_results.JiraClient", lambda config: client)

    item = _FakeItem(
        marker=_jira_marker("failover_primary_to_secondary", scenario="My Smoke Check")
    )
    _drive_makereport(item, _FakeCall(when="call"), _FakeReport(passed=True))

    assert "My Smoke Check" in client.created[0]["summary"]


def test_unapproved_scenario_id_raises_keyerror(monkeypatch):
    """Never invents a Jira Test Case mapping -- an unapproved scenario id
    must raise, never silently fall back to guessing a parent key."""
    _enable_jira_env(monkeypatch)
    client = FakeClient()
    monkeypatch.setattr("reporting.jira_results.JiraClient", lambda config: client)

    item = _FakeItem(marker=_jira_marker("totally_unapproved_scenario"))
    with pytest.raises(KeyError, match="not an approved"):
        _drive_makereport(item, _FakeCall(when="call"), _FakeReport(passed=True))


# --------------------------------------------------------------------------
# Reporting failures are logged, never raised (never affect the real
# pytest outcome that was already computed by the time this hook runs).
# --------------------------------------------------------------------------


def test_jira_reporting_failure_is_logged_not_raised(monkeypatch, caplog):
    _enable_jira_env(monkeypatch)
    client = FakeClient(fail_create=True)
    monkeypatch.setattr("reporting.jira_results.JiraClient", lambda config: client)

    item = _FakeItem(marker=_jira_marker())
    with caplog.at_level(logging.WARNING, logger="reporting.pytest_jira_plugin"):
        _drive_makereport(item, _FakeCall(when="call"), _FakeReport(passed=True))

    assert "Jira reporting failed" in caplog.text


# --------------------------------------------------------------------------
# Credentials fail-fast at collection time (not buried in the first
# marked test's report)
# --------------------------------------------------------------------------


def test_collection_modifyitems_noop_when_no_item_is_marked(monkeypatch):
    monkeypatch.delenv("JIRA_REPORT_RESULTS", raising=False)
    monkeypatch.delenv("JIRA_BASE_URL", raising=False)
    monkeypatch.delenv("JIRA_EMAIL", raising=False)
    monkeypatch.delenv("JIRA_API_TOKEN", raising=False)

    config = _FakeConfig()
    items = [_FakeItem(marker=None), _FakeItem(marker=None)]
    plugin.pytest_collection_modifyitems(config, items)  # must not raise

    assert plugin._CLIENT_STASH_KEY not in config.stash


def test_collection_modifyitems_fails_fast_when_credentials_missing(monkeypatch):
    # report_results defaults to True; no credentials configured at all.
    monkeypatch.delenv("JIRA_REPORT_RESULTS", raising=False)
    monkeypatch.delenv("JIRA_BASE_URL", raising=False)
    monkeypatch.delenv("JIRA_EMAIL", raising=False)
    monkeypatch.delenv("JIRA_API_TOKEN", raising=False)

    config = _FakeConfig()
    items = [_FakeItem(marker=None), _FakeItem(marker=_jira_marker())]

    with pytest.raises(JiraCredentialsUnavailableError):
        plugin.pytest_collection_modifyitems(config, items)


def test_collection_modifyitems_passes_when_reporting_explicitly_disabled(
    monkeypatch,
):
    monkeypatch.setenv("JIRA_REPORT_RESULTS", "false")
    monkeypatch.delenv("JIRA_BASE_URL", raising=False)
    monkeypatch.delenv("JIRA_EMAIL", raising=False)
    monkeypatch.delenv("JIRA_API_TOKEN", raising=False)

    config = _FakeConfig()
    items = [_FakeItem(marker=_jira_marker())]
    plugin.pytest_collection_modifyitems(config, items)  # must not raise
    assert config.stash[plugin._CLIENT_STASH_KEY] is None


# --------------------------------------------------------------------------
# One run id shared across every marked test in one session
# --------------------------------------------------------------------------


def test_two_marked_tests_in_one_session_share_one_run_id(monkeypatch):
    from reporting.jira_results import reset_session_run_id_cache

    reset_session_run_id_cache()
    monkeypatch.delenv("JIRA_RUN_ID", raising=False)
    _enable_jira_env(monkeypatch, JIRA_RUN_ID=None)
    client = FakeClient()
    monkeypatch.setattr("reporting.jira_results.JiraClient", lambda config: client)

    item_a = _FakeItem(marker=_jira_marker("failover_primary_to_secondary"))
    item_b = _FakeItem(marker=_jira_marker("relocate_secondary_to_primary"))
    _drive_makereport(item_a, _FakeCall(when="call"), _FakeReport(passed=True))
    _drive_makereport(item_b, _FakeCall(when="call"), _FakeReport(passed=True))

    run_id_a = client.created[0]["summary"].rsplit("| ", 1)[-1]
    run_id_b = client.created[1]["summary"].rsplit("| ", 1)[-1]
    assert run_id_a == run_id_b
    reset_session_run_id_cache()


# --------------------------------------------------------------------------
# jira_aggregate_test_case: one Jira Test Result for a whole group,
# reported once at pytest_sessionfinish (used by the smoke suite ->
# deployment_smoke_validation / RHELTEST-3612).
# --------------------------------------------------------------------------


class _FakeSession:
    def __init__(self, config):
        self.config = config


def _finish_session(config):
    plugin.pytest_sessionfinish(_FakeSession(config), exitstatus=0)


def test_aggregate_marker_registered_in_pytest_configure():
    lines: list[tuple[str, str]] = []

    class _Config:
        def addinivalue_line(self, section, line):
            lines.append((section, line))

    plugin.pytest_configure(_Config())
    assert len(lines) == 2
    section, line = lines[1]
    assert section == "markers"
    assert line.startswith("jira_aggregate_test_case(")


def test_aggregate_skipped_tests_are_never_counted(monkeypatch):
    _enable_jira_env(monkeypatch)
    client = FakeClient()
    monkeypatch.setattr("reporting.jira_results.JiraClient", lambda config: client)

    item = _FakeItem(marker=_aggregate_marker())
    _drive_makereport(item, _FakeCall(when="call"), _FakeReport(skipped=True))
    _finish_session(item.config)

    assert client.calls == []


def test_aggregate_zero_considered_reports_nothing(monkeypatch):
    """Every constituent test skipped (e.g. a partner variant where none of
    the ODF-only smoke checks are applicable) -- never fabricate a result."""
    _enable_jira_env(monkeypatch)
    client = FakeClient()
    monkeypatch.setattr("reporting.jira_results.JiraClient", lambda config: client)

    shared_config = _FakeConfig()
    item_a = _FakeItem(
        marker=_aggregate_marker(), nodeid="test_a", config=shared_config
    )
    item_b = _FakeItem(
        marker=_aggregate_marker(), nodeid="test_b", config=shared_config
    )
    _drive_makereport(item_a, _FakeCall(when="call"), _FakeReport(skipped=True))
    _drive_makereport(item_b, _FakeCall(when="call"), _FakeReport(skipped=True))
    _finish_session(shared_config)

    assert client.calls == []


def test_aggregate_setup_phase_failure_is_never_counted(monkeypatch):
    _enable_jira_env(monkeypatch)
    client = FakeClient()
    monkeypatch.setattr("reporting.jira_results.JiraClient", lambda config: client)

    item = _FakeItem(marker=_aggregate_marker())
    _drive_makereport(item, _FakeCall(when="setup"), _FakeReport(failed=True))
    _finish_session(item.config)

    assert client.calls == []


def test_aggregate_all_passing_reports_exactly_one_pass(monkeypatch):
    _enable_jira_env(monkeypatch)
    client = FakeClient()
    monkeypatch.setattr("reporting.jira_results.JiraClient", lambda config: client)

    shared_config = _FakeConfig()
    item_a = _FakeItem(
        marker=_aggregate_marker(), nodeid="test_a", config=shared_config
    )
    item_b = _FakeItem(
        marker=_aggregate_marker(), nodeid="test_b", config=shared_config
    )
    _drive_makereport(item_a, _FakeCall(when="call"), _FakeReport(passed=True))
    _drive_makereport(item_b, _FakeCall(when="call"), _FakeReport(passed=True))
    _finish_session(shared_config)

    assert len(client.created) == 1
    assert client.created[0]["parent"] == {"key": "RHELTEST-3612"}
    assert client.transitioned == [(client.transitioned[0][0], "3")]  # PASS


def test_aggregate_test_function_is_the_module_path_of_the_first_counted_test(
    monkeypatch,
):
    """The aggregate's "Test function" must reflect the real smoke module
    that was actually run -- derived generically from the nodeid, never a
    different module hard-coded in the plugin itself."""
    _enable_jira_env(monkeypatch)
    client = FakeClient()
    monkeypatch.setattr("reporting.jira_results.JiraClient", lambda config: client)

    shared_config = _FakeConfig()
    item_a = _FakeItem(
        marker=_aggregate_marker(),
        nodeid="tests/ui/smoke/test_smoke.py::TestInfraSmoke::test_a",
        config=shared_config,
    )
    item_b = _FakeItem(
        marker=_aggregate_marker(),
        nodeid="tests/ui/smoke/test_smoke.py::TestInfraSmoke::test_b",
        config=shared_config,
    )
    _drive_makereport(item_a, _FakeCall(when="call"), _FakeReport(passed=True))
    _drive_makereport(item_b, _FakeCall(when="call"), _FakeReport(passed=True))
    _finish_session(shared_config)

    description_text = str(client.created[0]["description"])
    assert "Test function: tests/ui/smoke/test_smoke.py" in description_text
    # Never the full nodeid of whichever individual test happened to be
    # considered first -- just the shared module path.
    assert "TestInfraSmoke" not in description_text


def test_aggregate_one_failure_reports_exactly_one_fail_naming_the_node_id(
    monkeypatch,
):
    _enable_jira_env(monkeypatch)
    client = FakeClient()
    monkeypatch.setattr("reporting.jira_results.JiraClient", lambda config: client)

    shared_config = _FakeConfig()
    item_a = _FakeItem(
        marker=_aggregate_marker(),
        nodeid="tests/ui/smoke/test_smoke.py::test_a",
        config=shared_config,
    )
    item_b = _FakeItem(
        marker=_aggregate_marker(),
        nodeid="tests/ui/smoke/test_smoke.py::test_b",
        config=shared_config,
    )
    _drive_makereport(item_a, _FakeCall(when="call"), _FakeReport(passed=True))
    _drive_makereport(
        item_b,
        _FakeCall(when="call", excinfo=_FakeExcInfo(RuntimeError("vault not running"))),
        _FakeReport(failed=True),
    )
    _finish_session(shared_config)

    assert len(client.created) == 1
    assert client.transitioned == [(client.transitioned[0][0], "4")]  # FAIL
    description_text = str(client.created[0]["description"])
    assert "tests/ui/smoke/test_smoke.py::test_b" in description_text
    assert "vault not running" in description_text


def test_aggregate_multiple_failures_report_exactly_one_fail_not_several(
    monkeypatch,
):
    _enable_jira_env(monkeypatch)
    client = FakeClient()
    monkeypatch.setattr("reporting.jira_results.JiraClient", lambda config: client)

    shared_config = _FakeConfig()
    item_a = _FakeItem(
        marker=_aggregate_marker(), nodeid="test_a", config=shared_config
    )
    item_b = _FakeItem(
        marker=_aggregate_marker(), nodeid="test_b", config=shared_config
    )
    item_c = _FakeItem(
        marker=_aggregate_marker(), nodeid="test_c", config=shared_config
    )
    _drive_makereport(
        item_a,
        _FakeCall(when="call", excinfo=_FakeExcInfo(RuntimeError("boom-a"))),
        _FakeReport(failed=True),
    )
    _drive_makereport(
        item_b,
        _FakeCall(when="call", excinfo=_FakeExcInfo(RuntimeError("boom-b"))),
        _FakeReport(failed=True),
    )
    _drive_makereport(item_c, _FakeCall(when="call"), _FakeReport(passed=True))
    _finish_session(shared_config)

    # Exactly one create_issue call total, even though two tests failed --
    # never one FAIL Test Result per failing constituent test.
    assert client.calls.count("create_issue") == 1
    assert len(client.created) == 1
    description_text = str(client.created[0]["description"])
    assert "test_a" in description_text and "boom-a" in description_text
    assert "test_b" in description_text and "boom-b" in description_text


def test_aggregate_and_individual_marker_together_raises_typeerror():
    both_marks = {
        plugin._MARKER_NAME: _jira_marker(),
        plugin._AGGREGATE_MARKER_NAME: _aggregate_marker(),
    }

    class _BothMarkersItem(_FakeItem):
        def get_closest_marker(self, name):
            return both_marks.get(name)

    item = _BothMarkersItem(marker=None)
    with pytest.raises(TypeError, match="use exactly one"):
        _drive_makereport(item, _FakeCall(when="call"), _FakeReport(passed=True))


def test_aggregate_credentials_missing_logs_warning_and_does_not_raise(
    monkeypatch, caplog
):
    monkeypatch.delenv("JIRA_REPORT_RESULTS", raising=False)
    monkeypatch.delenv("JIRA_BASE_URL", raising=False)
    monkeypatch.delenv("JIRA_EMAIL", raising=False)
    monkeypatch.delenv("JIRA_API_TOKEN", raising=False)

    item = _FakeItem(marker=_aggregate_marker())
    _drive_makereport(item, _FakeCall(when="call"), _FakeReport(passed=True))

    with caplog.at_level(logging.WARNING, logger="reporting.pytest_jira_plugin"):
        _finish_session(item.config)  # must not raise

    assert "Skipping aggregate Jira reporting" in caplog.text


def test_sessionfinish_noop_when_no_aggregate_scenarios_seen():
    config = _FakeConfig()
    _finish_session(config)  # must not raise, must not touch the stash
    assert plugin._CLIENT_STASH_KEY not in config.stash


def test_aggregate_reporting_failure_is_logged_not_raised(monkeypatch, caplog):
    _enable_jira_env(monkeypatch)
    client = FakeClient(fail_create=True)
    monkeypatch.setattr("reporting.jira_results.JiraClient", lambda config: client)

    item = _FakeItem(marker=_aggregate_marker())
    _drive_makereport(item, _FakeCall(when="call"), _FakeReport(passed=True))

    with caplog.at_level(logging.WARNING, logger="reporting.pytest_jira_plugin"):
        _finish_session(item.config)  # must not raise

    assert "Aggregate Jira reporting failed" in caplog.text


def test_aggregate_shares_session_run_id_with_individual_marker(monkeypatch):
    from reporting.jira_results import reset_session_run_id_cache

    reset_session_run_id_cache()
    monkeypatch.delenv("JIRA_RUN_ID", raising=False)
    _enable_jira_env(monkeypatch, JIRA_RUN_ID=None)
    client = FakeClient()
    monkeypatch.setattr("reporting.jira_results.JiraClient", lambda config: client)

    shared_config = _FakeConfig()
    individual_item = _FakeItem(
        marker=_jira_marker("failover_primary_to_secondary"),
        nodeid="test_sanity",
        config=shared_config,
    )
    aggregate_item = _FakeItem(
        marker=_aggregate_marker(), nodeid="test_smoke_a", config=shared_config
    )
    _drive_makereport(individual_item, _FakeCall(when="call"), _FakeReport(passed=True))
    _drive_makereport(aggregate_item, _FakeCall(when="call"), _FakeReport(passed=True))
    _finish_session(shared_config)

    assert len(client.created) == 2
    run_id_individual = client.created[0]["summary"].rsplit("| ", 1)[-1]
    run_id_aggregate = client.created[1]["summary"].rsplit("| ", 1)[-1]
    assert run_id_individual == run_id_aggregate
    reset_session_run_id_cache()


# --------------------------------------------------------------------------
# jira_aggregate_test_case: teardown-phase handling.
#
# Only a teardown failure that follows that *same* node id's own passing
# "call" phase reflects a failure of an executed scenario -- everything
# else (skip, setup failure, or a teardown failure stacked on an
# already-failed call) is ignored, per the "no environment/pre-deployment/
# setup failures in the dashboard" rule.
# --------------------------------------------------------------------------


def test_aggregate_passing_teardown_after_passing_call_is_still_one_pass(monkeypatch):
    _enable_jira_env(monkeypatch)
    client = FakeClient()
    monkeypatch.setattr("reporting.jira_results.JiraClient", lambda config: client)

    item = _FakeItem(marker=_aggregate_marker(), nodeid="test_a")
    _drive_makereport(item, _FakeCall(when="call"), _FakeReport(passed=True))
    _drive_makereport(item, _FakeCall(when="teardown"), _FakeReport(passed=True))
    _finish_session(item.config)

    assert len(client.created) == 1
    assert client.transitioned == [(client.transitioned[0][0], "3")]  # PASS


def test_aggregate_teardown_failure_after_passing_call_flips_to_fail(monkeypatch):
    """Cleanup belonging to a scenario that actually ran and passed then
    failed -- this IS a failure of that executed scenario, so it must flip
    the aggregate from PASS to FAIL (not be silently ignored like a setup
    failure would be)."""
    _enable_jira_env(monkeypatch)
    client = FakeClient()
    monkeypatch.setattr("reporting.jira_results.JiraClient", lambda config: client)

    item = _FakeItem(
        marker=_aggregate_marker(),
        nodeid="tests/ui/smoke/test_smoke.py::test_a",
    )
    _drive_makereport(item, _FakeCall(when="call"), _FakeReport(passed=True))
    _drive_makereport(
        item,
        _FakeCall(when="teardown", excinfo=_FakeExcInfo(RuntimeError("cleanup boom"))),
        _FakeReport(failed=True),
    )
    _finish_session(item.config)

    assert len(client.created) == 1
    assert client.transitioned == [(client.transitioned[0][0], "4")]  # FAIL
    description_text = str(client.created[0]["description"])
    assert "tests/ui/smoke/test_smoke.py::test_a" in description_text
    assert "(teardown)" in description_text
    assert "cleanup boom" in description_text


def test_aggregate_teardown_failure_after_call_failure_is_not_duplicated(monkeypatch):
    """The call already failed and was already counted -- a teardown
    failure piled on top must not add a second failure entry for the same
    node id (still exactly one create_issue call, one failure listed)."""
    _enable_jira_env(monkeypatch)
    client = FakeClient()
    monkeypatch.setattr("reporting.jira_results.JiraClient", lambda config: client)

    # Module path ("mod.py") deliberately differs from the bare nodeid used
    # elsewhere in this file: it is shown separately as "Test function", so
    # it must not collide with the "test_a" substring being counted below.
    item = _FakeItem(marker=_aggregate_marker(), nodeid="mod.py::test_a")
    _drive_makereport(
        item,
        _FakeCall(when="call", excinfo=_FakeExcInfo(RuntimeError("call boom"))),
        _FakeReport(failed=True),
    )
    _drive_makereport(
        item,
        _FakeCall(when="teardown", excinfo=_FakeExcInfo(RuntimeError("cleanup boom"))),
        _FakeReport(failed=True),
    )
    _finish_session(item.config)

    assert client.calls.count("create_issue") == 1
    description_text = str(client.created[0]["description"])
    assert description_text.count("test_a") == 1
    assert "cleanup boom" not in description_text
    assert "call boom" in description_text


def test_aggregate_teardown_failure_after_skip_is_ignored(monkeypatch):
    """Teardown of a skipped (not-applicable-to-this-variant) test must
    never make the aggregate FAIL -- there is no executed scenario for it
    to reflect a failure of."""
    _enable_jira_env(monkeypatch)
    client = FakeClient()
    monkeypatch.setattr("reporting.jira_results.JiraClient", lambda config: client)

    item = _FakeItem(marker=_aggregate_marker(), nodeid="test_a")
    _drive_makereport(item, _FakeCall(when="call"), _FakeReport(skipped=True))
    _drive_makereport(
        item,
        _FakeCall(when="teardown", excinfo=_FakeExcInfo(RuntimeError("cleanup boom"))),
        _FakeReport(failed=True),
    )
    _finish_session(item.config)

    # Nothing was ever considered for this scenario -- reports nothing at all.
    assert client.calls == []


def test_aggregate_teardown_failure_after_setup_failure_is_ignored(monkeypatch):
    """An environment/pre-deployment/provisioning-style setup failure means
    the test body never started -- a teardown failure while cleaning up
    that partial setup must not be reported either."""
    _enable_jira_env(monkeypatch)
    client = FakeClient()
    monkeypatch.setattr("reporting.jira_results.JiraClient", lambda config: client)

    item = _FakeItem(marker=_aggregate_marker(), nodeid="test_a")
    _drive_makereport(
        item,
        _FakeCall(when="setup", excinfo=_FakeExcInfo(RuntimeError("fixture boom"))),
        _FakeReport(failed=True),
    )
    _drive_makereport(
        item,
        _FakeCall(when="teardown", excinfo=_FakeExcInfo(RuntimeError("cleanup boom"))),
        _FakeReport(failed=True),
    )
    _finish_session(item.config)

    assert client.calls == []


def test_individual_marker_teardown_failure_is_a_noop(monkeypatch):
    """jira_test_case reports immediately at "call" time and has no
    teardown handling (it isn't used by any production per-test scenario
    today) -- a teardown-phase report for an individually-marked test must
    not raise or report anything additional."""
    _enable_jira_env(monkeypatch)
    client = FakeClient()
    monkeypatch.setattr("reporting.jira_results.JiraClient", lambda config: client)

    item = _FakeItem(marker=_jira_marker())
    _drive_makereport(item, _FakeCall(when="call"), _FakeReport(passed=True))
    assert len(client.created) == 1

    _drive_makereport(
        item,
        _FakeCall(when="teardown", excinfo=_FakeExcInfo(RuntimeError("cleanup boom"))),
        _FakeReport(failed=True),
    )  # must not raise, must not report again
    assert len(client.created) == 1


def test_aggregate_teardown_failure_for_one_test_does_not_affect_others(monkeypatch):
    """A teardown failure is scoped to its own node id -- it must not spill
    over and mark an unrelated, genuinely-passing constituent test as
    failed."""
    _enable_jira_env(monkeypatch)
    client = FakeClient()
    monkeypatch.setattr("reporting.jira_results.JiraClient", lambda config: client)

    shared_config = _FakeConfig()
    item_a = _FakeItem(
        marker=_aggregate_marker(), nodeid="test_a", config=shared_config
    )
    item_b = _FakeItem(
        marker=_aggregate_marker(), nodeid="test_b", config=shared_config
    )
    _drive_makereport(item_a, _FakeCall(when="call"), _FakeReport(passed=True))
    _drive_makereport(item_a, _FakeCall(when="teardown"), _FakeReport(passed=True))
    _drive_makereport(item_b, _FakeCall(when="call"), _FakeReport(passed=True))
    _finish_session(shared_config)

    assert len(client.created) == 1
    assert client.transitioned == [(client.transitioned[0][0], "3")]  # PASS
