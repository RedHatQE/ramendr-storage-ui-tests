"""Unit tests for reporting.jira_results.JiraScenarioReporter / jira_test_case_result.

This is the per-scenario reporting boundary used by tests/ui/sanity/test_sanity.py
to give independent Jira Test Results to independent scenarios (failover,
relocate) inside one larger pytest test. Jira is always mocked here; no test
contacts a real Jira instance.
"""

from __future__ import annotations

import logging

import pytest

from reporting.jira_client import JiraClientError, JiraWriteError
from reporting.jira_config import reporting_config_from_env
from reporting.jira_results import derive_run_id, jira_test_case_result


def _valid_parent(key: str = "RHELTEST-3600") -> dict:
    return {
        "key": key,
        "fields": {
            "project": {"key": "RHELTEST"},
            "issuetype": {"name": "Test Case"},
            "labels": ["ramen-dr", "automation"],
        },
    }


class FakeClient:
    """Fake JiraClient for JiraScenarioReporter tests. Records every call."""

    def __init__(
        self,
        *,
        parent=None,
        transitions=None,
        created_key="RHELTEST-9001",
        fail_create: bool = False,
        fail_get_after_create: bool = False,
    ):
        self.calls: list[str] = []
        self._parent = parent if parent is not None else _valid_parent()
        self._transitions = (
            transitions
            if transitions is not None
            else [
                {"id": "2", "name": "New"},
                {"id": "3", "name": "PASS"},
                {"id": "4", "name": "FAIL"},
                {"id": "5", "name": "Blocked"},
            ]
        )
        self._created_key = created_key
        self._fail_create = fail_create
        self._fail_get_after_create = fail_get_after_create
        self._status_name = "New"
        self.created_fields: dict | None = None
        self.transitioned: tuple[str, str] | None = None

    def get_issue(self, issue_key, *, expand=None):
        self.calls.append("get_issue")
        if issue_key == self._created_key and self.created_fields is not None:
            if self._fail_get_after_create:
                raise JiraClientError("transient GET failure after create")
            fields = self.created_fields
            custom_fields = {
                k: v for k, v in fields.items() if k.startswith("customfield_")
            }
            return {
                "fields": {
                    "status": {"name": self._status_name},
                    "parent": fields.get("parent", {}),
                    "labels": fields.get("labels", []),
                    **custom_fields,
                }
            }
        return self._parent

    def get_transitions(self, issue_key):
        self.calls.append("get_transitions")
        return self._transitions

    def create_issue(self, fields):
        self.calls.append("create_issue")
        if self._fail_create:
            raise JiraWriteError("simulated create failure")
        self.created_fields = fields
        return self._created_key

    def transition_issue(self, issue_key, transition_id):
        self.calls.append("transition_issue")
        self.transitioned = (issue_key, str(transition_id))
        self._status_name = {"3": "PASS", "4": "FAIL", "5": "Blocked"}.get(
            str(transition_id), self._status_name
        )


class _ScenarioBoom(RuntimeError):
    """A distinctive exception type so tests can assert it propagates unmodified."""


def _enabled_config(**overrides):
    env = {"JIRA_REPORT_RESULTS": "true", "JIRA_REPORT_DRY_RUN": "false"}
    env.update(overrides)
    return reporting_config_from_env(env)


# --------------------------------------------------------------------------
# derive_run_id
# --------------------------------------------------------------------------


def test_derive_run_id_uses_configured_run_id_when_set():
    config = reporting_config_from_env({"JIRA_RUN_ID": "ci-run-42"})
    assert derive_run_id(config) == "ci-run-42"


def test_derive_run_id_generates_a_sanity_prefixed_fallback_when_unset():
    config = reporting_config_from_env({})
    run_id = derive_run_id(config)
    assert run_id.startswith("sanity-")


def test_derive_run_id_fallback_is_unique_across_calls():
    config = reporting_config_from_env({})
    assert derive_run_id(config) != derive_run_id(config)


# --------------------------------------------------------------------------
# Context-manager usage (single contiguous block)
# --------------------------------------------------------------------------


def test_context_manager_reports_pass_on_success():
    config = _enabled_config()
    client = FakeClient()

    with jira_test_case_result(
        "failover_primary_to_secondary",
        scenario="Failover primary to secondary",
        run_id="run-1",
        client=client,
        config=config,
    ) as reporter:
        pass  # the scenario "succeeds"

    assert reporter.last_result is not None
    assert reporter.last_result.issue_key == "RHELTEST-9001"
    assert client.transitioned == ("RHELTEST-9001", "3")  # PASS


def test_context_manager_reports_fail_and_reraises_original_exception():
    config = _enabled_config()
    client = FakeClient()

    with pytest.raises(_ScenarioBoom, match="dr flow broke"):
        with jira_test_case_result(
            "failover_primary_to_secondary",
            scenario="Failover primary to secondary",
            run_id="run-1",
            client=client,
            config=config,
        ):
            raise _ScenarioBoom("dr flow broke")

    assert client.transitioned == ("RHELTEST-9001", "4")  # FAIL


def test_context_manager_never_swallows_or_replaces_the_original_exception():
    """Even when Jira reporting ITSELF fails while the scenario is failing,
    the original exception type/message must propagate unmodified."""
    config = _enabled_config()
    client = FakeClient(fail_create=True)

    with pytest.raises(_ScenarioBoom, match="original dr failure"):
        with jira_test_case_result(
            "failover_primary_to_secondary",
            scenario="Failover primary to secondary",
            run_id="run-1",
            client=client,
            config=config,
        ):
            raise _ScenarioBoom("original dr failure")


# --------------------------------------------------------------------------
# Manual start()/close_success()/close_failure() usage (non-contiguous
# boundaries -- the adaptive/resume flow in test_sanity.py).
# --------------------------------------------------------------------------


def test_manual_start_and_close_success():
    config = _enabled_config()
    client = FakeClient()

    reporter = jira_test_case_result(
        "relocate_secondary_to_primary",
        scenario="Relocate secondary to primary",
        run_id="run-1",
        client=client,
        config=config,
    )
    reporter.start()
    # ... unrelated code in between, in the real caller ...
    result = reporter.close_success()

    assert result is not None
    assert result.transition_id_used == "3"
    assert client.transitioned == ("RHELTEST-9001", "3")


def test_manual_close_failure_preserves_original_exception_and_logs_jira_error(
    caplog,
):
    """Jira reporting failing while the scenario ALSO failed must never mask
    the original scenario exception -- only ever logged."""
    config = _enabled_config()
    client = FakeClient(fail_create=True)

    reporter = jira_test_case_result(
        "failover_primary_to_secondary",
        scenario="Failover primary to secondary",
        run_id="run-1",
        client=client,
        config=config,
    )
    reporter.start()
    original_exc = _ScenarioBoom("the real dr failure")

    with caplog.at_level(logging.WARNING, logger="reporting.jira_results"):
        result = reporter.close_failure(original_exc)

    assert result is None  # Jira reporting itself failed
    assert "original scenario failure is preserved" in caplog.text.lower()


def test_double_close_is_a_noop_and_reports_only_once():
    """A boundary already closed (e.g. its own close_success()) must not be
    reported again by an outer safety-net close_failure()."""
    config = _enabled_config()
    client = FakeClient()

    reporter = jira_test_case_result(
        "failover_primary_to_secondary",
        scenario="Failover primary to secondary",
        run_id="run-1",
        client=client,
        config=config,
    )
    reporter.start()
    first = reporter.close_success()
    assert first is not None
    assert client.calls.count("create_issue") == 1

    # Simulates the outer except-handler safety net calling close_failure()
    # on a reporter that already closed successfully -- must be a no-op.
    second = reporter.close_failure(_ScenarioBoom("too late"))
    assert second is None
    assert client.calls.count("create_issue") == 1  # not reported a second time


def test_close_success_then_close_success_again_is_a_noop():
    config = _enabled_config()
    client = FakeClient()

    reporter = jira_test_case_result(
        "failover_primary_to_secondary",
        scenario="Failover primary to secondary",
        run_id="run-1",
        client=client,
        config=config,
    )
    reporter.start()
    reporter.close_success()
    reporter.close_success()  # no-op
    assert client.calls.count("create_issue") == 1


# --------------------------------------------------------------------------
# Safety gates (reporting disabled / dry-run) -- reused from report_test_result
# but verified again at the JiraScenarioReporter level.
# --------------------------------------------------------------------------


def test_reporting_disabled_makes_zero_jira_calls():
    config = reporting_config_from_env({"JIRA_REPORT_RESULTS": "false"})
    client = FakeClient()

    with jira_test_case_result(
        "failover_primary_to_secondary",
        scenario="Failover primary to secondary",
        run_id="run-1",
        client=client,
        config=config,
    ):
        pass

    assert client.calls == []  # not even a GET


def test_dry_run_makes_no_writes():
    config = reporting_config_from_env(
        {"JIRA_REPORT_RESULTS": "true", "JIRA_REPORT_DRY_RUN": "true"}
    )
    client = FakeClient()

    with jira_test_case_result(
        "failover_primary_to_secondary",
        scenario="Failover primary to secondary",
        run_id="run-1",
        client=client,
        config=config,
    ) as reporter:
        pass

    assert "create_issue" not in client.calls
    assert "transition_issue" not in client.calls
    assert reporter.last_result.dry_run is True


# --------------------------------------------------------------------------
# JIRA_REPORT_STRICT
# --------------------------------------------------------------------------


def test_close_success_swallows_jira_failure_by_default():
    """A Jira write failure while the scenario PASSED is logged-only by
    default (JIRA_REPORT_STRICT=false) -- it never fails the test."""
    config = _enabled_config(JIRA_REPORT_STRICT="false")
    client = FakeClient(fail_create=True)

    reporter = jira_test_case_result(
        "failover_primary_to_secondary",
        scenario="Failover primary to secondary",
        run_id="run-1",
        client=client,
        config=config,
    )
    reporter.start()
    result = reporter.close_success()  # must not raise
    assert result is None


def test_close_success_raises_when_strict_and_jira_write_fails():
    """With JIRA_REPORT_STRICT=true, a Jira write failure on an otherwise
    passing scenario DOES surface as an exception."""
    config = _enabled_config(JIRA_REPORT_STRICT="true")
    client = FakeClient(fail_create=True)

    reporter = jira_test_case_result(
        "failover_primary_to_secondary",
        scenario="Failover primary to secondary",
        run_id="run-1",
        client=client,
        config=config,
    )
    reporter.start()
    with pytest.raises(JiraWriteError):
        reporter.close_success()


def test_context_manager_with_strict_still_never_masks_a_scenario_failure():
    """Strict mode only affects the PASS-reporting-failure case -- a FAIL
    boundary's own Jira-reporting failure is ALWAYS just logged, regardless
    of JIRA_REPORT_STRICT, so the original scenario exception always wins."""
    config = _enabled_config(JIRA_REPORT_STRICT="true")
    client = FakeClient(fail_create=True)

    with pytest.raises(_ScenarioBoom, match="original dr failure"):
        with jira_test_case_result(
            "failover_primary_to_secondary",
            scenario="Failover primary to secondary",
            run_id="run-1",
            client=client,
            config=config,
        ):
            raise _ScenarioBoom("original dr failure")


# --------------------------------------------------------------------------
# Shared run id + independent scenarios
# --------------------------------------------------------------------------


def test_two_scenarios_share_one_run_id_but_report_independently():
    config = _enabled_config()
    client_failover = FakeClient(created_key="RHELTEST-9001")
    client_relocate = FakeClient(
        parent=_valid_parent("RHELTEST-3610"), created_key="RHELTEST-9002"
    )
    run_id = derive_run_id(reporting_config_from_env({"JIRA_RUN_ID": "shared-run-1"}))

    with jira_test_case_result(
        "failover_primary_to_secondary",
        scenario="Failover primary to secondary",
        run_id=run_id,
        client=client_failover,
        config=config,
    ):
        pass

    with pytest.raises(_ScenarioBoom):
        with jira_test_case_result(
            "relocate_secondary_to_primary",
            scenario="Relocate secondary to primary",
            run_id=run_id,
            client=client_relocate,
            config=config,
        ):
            raise _ScenarioBoom("relocate broke")

    failover_fields = client_failover.created_fields
    relocate_fields = client_relocate.created_fields
    assert failover_fields["summary"].endswith(f"| {run_id}")
    assert relocate_fields["summary"].endswith(f"| {run_id}")
    assert client_failover.transitioned == ("RHELTEST-9001", "3")  # PASS
    assert client_relocate.transitioned == ("RHELTEST-9002", "4")  # FAIL
