"""Unit tests for reporting.pytest_jira_plugin: the jira_aggregate_test_case
marker-based automatic Jira Test Result reporting hook used by smoke.

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
from reporting.jira_results import JiraCredentialsUnavailableError, _generated_run_id


class FakeClient:
    """Minimal fake JiraClient -- same shape as the fake in
    test_jira_scenario_reporter.py."""

    def __init__(self, *, fail_create: bool = False):
        self.calls: list[str] = []
        self.created: list[dict] = []
        self.transitioned: list[tuple[str, str]] = []
        self._fail_create = fail_create
        self._next_seq = 9000

    def create_issue(self, fields):
        self.calls.append("create_issue")
        if self._fail_create:
            raise RuntimeError("simulated create failure")
        self._next_seq += 1
        key = f"RHELTEST-{self._next_seq}"
        self.created.append(fields)
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
        nodeid="tests/ui/smoke/test_smoke.py::test_x",
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


class _FakeSession:
    def __init__(self, config):
        self.config = config


def _finish_session(config):
    plugin.pytest_sessionfinish(_FakeSession(config), exitstatus=0)


# --------------------------------------------------------------------------
# pytest_configure -- marker registration
# --------------------------------------------------------------------------


def test_aggregate_marker_registered_in_pytest_configure():
    lines: list[tuple[str, str]] = []

    class _Config:
        def addinivalue_line(self, section, line):
            lines.append((section, line))

    plugin.pytest_configure(_Config())
    assert len(lines) == 1
    section, line = lines[0]
    assert section == "markers"
    assert line.startswith("jira_aggregate_test_case(")


# --------------------------------------------------------------------------
# Never reports: unmarked, skipped, or non-"call"/"teardown"-phase
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


def test_aggregate_skipped_tests_are_never_counted(monkeypatch):
    _enable_jira_env(monkeypatch)
    client = FakeClient()
    monkeypatch.setattr("reporting.jira_results.JiraClient", lambda config: client)

    item = _FakeItem(marker=_aggregate_marker())
    _drive_makereport(item, _FakeCall(when="call"), _FakeReport(skipped=True))
    _finish_session(item.config)

    assert client.calls == []


def test_aggregate_setup_phase_failure_is_never_counted(monkeypatch):
    """A fixture/setup failure means the scenario body never ran -- never
    fabricate a Jira result for it (same rule as the sanity DR boundaries)."""
    _enable_jira_env(monkeypatch)
    client = FakeClient()
    monkeypatch.setattr("reporting.jira_results.JiraClient", lambda config: client)

    item = _FakeItem(marker=_aggregate_marker())
    _drive_makereport(item, _FakeCall(when="setup"), _FakeReport(failed=True))
    _finish_session(item.config)

    assert client.calls == []


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


def test_collection_modifyitems_fails_fast_when_a_real_write_is_requested_but_credentials_missing(
    monkeypatch,
):
    monkeypatch.setenv("JIRA_REPORT_RESULTS", "true")
    monkeypatch.setenv("JIRA_REPORT_DRY_RUN", "false")
    monkeypatch.delenv("JIRA_BASE_URL", raising=False)
    monkeypatch.delenv("JIRA_EMAIL", raising=False)
    monkeypatch.delenv("JIRA_API_TOKEN", raising=False)

    config = _FakeConfig()
    items = [_FakeItem(marker=None), _FakeItem(marker=_aggregate_marker())]

    with pytest.raises(JiraCredentialsUnavailableError):
        plugin.pytest_collection_modifyitems(config, items)


def test_collection_modifyitems_passes_with_default_opt_in_config(monkeypatch):
    monkeypatch.delenv("JIRA_REPORT_RESULTS", raising=False)
    monkeypatch.delenv("JIRA_REPORT_DRY_RUN", raising=False)
    monkeypatch.delenv("JIRA_BASE_URL", raising=False)
    monkeypatch.delenv("JIRA_EMAIL", raising=False)
    monkeypatch.delenv("JIRA_API_TOKEN", raising=False)

    config = _FakeConfig()
    items = [_FakeItem(marker=_aggregate_marker())]
    plugin.pytest_collection_modifyitems(config, items)  # must not raise
    assert config.stash[plugin._CLIENT_STASH_KEY] is None


# --------------------------------------------------------------------------
# jira_aggregate_test_case: one Jira Test Result for a whole group,
# reported once at pytest_sessionfinish (used by the smoke suite ->
# deployment_smoke_validation / RHELTEST-3612).
# --------------------------------------------------------------------------


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


def test_aggregate_credentials_missing_logs_warning_and_does_not_raise(
    monkeypatch, caplog
):
    monkeypatch.setenv("JIRA_REPORT_RESULTS", "true")
    monkeypatch.setenv("JIRA_REPORT_DRY_RUN", "false")
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

    with caplog.at_level(logging.WARNING, logger="reporting.jira_results"):
        _finish_session(item.config)  # must not raise

    assert "jira reporting failed" in caplog.text.lower()


def test_two_aggregate_scenarios_in_one_session_share_one_run_id(monkeypatch):
    _generated_run_id.cache_clear()
    monkeypatch.delenv("JIRA_RUN_ID", raising=False)
    _enable_jira_env(monkeypatch, JIRA_RUN_ID=None)
    client = FakeClient()
    monkeypatch.setattr("reporting.jira_results.JiraClient", lambda config: client)

    shared_config = _FakeConfig()
    item_a = _FakeItem(
        marker=_aggregate_marker("deployment_smoke_validation"),
        nodeid="test_a",
        config=shared_config,
    )
    item_b = _FakeItem(
        marker=_aggregate_marker("deployment_smoke_validation"),
        nodeid="test_b",
        config=shared_config,
    )
    _drive_makereport(item_a, _FakeCall(when="call"), _FakeReport(passed=True))
    _drive_makereport(item_b, _FakeCall(when="call"), _FakeReport(passed=True))
    _finish_session(shared_config)

    assert len(client.created) == 1  # one scenario_id -> one Test Result
    _generated_run_id.cache_clear()


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
