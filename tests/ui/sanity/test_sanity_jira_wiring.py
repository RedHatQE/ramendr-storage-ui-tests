"""Unit tests for the Jira Test Result reporting wiring inside
``tests/ui/sanity/test_sanity.py::test_sanity_disaster_recovery_ui``
(adaptive/resume mode -- ``RAMENDR_SANITY_FORCE_FULL=0``).

Every DR/Playwright/``oc``-touching helper is monkeypatched to a no-op or a
small scripted fake, and the real Jira client class is replaced with an
in-memory fake -- these tests never contact Jira, Playwright, or a real
OpenShift cluster. They call the actual ``test_sanity_disaster_recovery_ui``
method directly (bypassing pytest collection/markers, which don't matter
here) so the resume/PASS/FAIL wiring is verified against the real production
code path rather than a reimplementation of it.

This file lives next to ``test_sanity.py`` (no ``__init__.py`` in this
directory) so pytest's own rootdir-based import of that module -- already
triggered by collecting ``test_sanity.py`` itself -- makes a plain
``import test_sanity`` resolve to the same module object.
"""

from __future__ import annotations

import test_sanity as sanity

from reporting.jira_client import JiraWriteError

_HEALTHY_PRIMARY_FRESH = {
    "policy": "2m-vm",
    "cluster": "ocp-primary",
    "status": "Healthy",
}
_HEALTHY_SECONDARY_POST_FAILOVER = {
    "policy": "2m-vm",
    "cluster": "ocp-secondary",
    "status": "Healthy",
}
_HEALTHY_PRIMARY_POST_RELOCATE = {
    "policy": "2m-vm",
    "cluster": "ocp-primary",
    "status": "Healthy",
}


class _FakeLoginPage:
    def __init__(self, page):
        pass

    def open(self, base_url):
        pass

    def assert_page_loaded(self):
        pass

    def login(self, username, password):
        pass


class _FakeDashboardPage:
    def __init__(self, page):
        pass

    def assert_page_loaded(self):
        pass

    def dismiss_welcome_if_present(self):
        pass


class _FakeDRPCPage:
    """Scripted DRPC page object: enough of the real DRPCPage surface for
    the adaptive flow, no network/browser calls. ``initiate_*_dialog``
    updates ``_state`` to the settled post-action state directly -- the
    intermediate progress states aren't relevant to Jira wiring, and the
    real settling loops are separately monkeypatched to no-ops below.
    """

    def __init__(self, page, *, initial_state: dict):
        self._state = dict(initial_state)

    def navigate(self, base_url):
        pass

    def assert_in_disaster_recovery_view(self):
        pass

    def navigate_policies_tab(self):
        pass

    def assert_drpolicy(self, name, *, expected_status, expected_applications):
        pass

    def navigate_protected_applications_tab(self):
        pass

    def assert_drpc(self, name, *, expected_policy, expected_cluster):
        pass

    def assert_drpc_actions_menu(self, name):
        pass

    def get_drpc_state(self, name):
        return dict(self._state)

    def open_failover_dialog(self, name):
        pass

    def assert_failover_dialog_contents(self):
        pass

    def cancel_failover_dialog(self):
        pass

    def initiate_failover_dialog(self):
        self._state = dict(_HEALTHY_SECONDARY_POST_FAILOVER)

    def wait_for_failover_progress_state(self, name):
        pass

    def open_failover_progress_popover(self, name):
        pass

    def assert_failover_progress_popover(self, *, expected_target_cluster):
        pass

    def wait_for_failover_complete_state(self, name, *, expected_cluster, timeout_ms):
        pass

    def open_relocate_dialog(self, name):
        pass

    def assert_relocate_dialog_contents(self):
        pass

    def initiate_relocate_dialog(self):
        self._state = dict(_HEALTHY_PRIMARY_POST_RELOCATE)

    def wait_for_relocate_complete_state(self, name, *, expected_cluster, timeout_ms):
        pass


class FakeSanityJiraClient:
    """In-memory fake covering both RHELTEST-3600 and RHELTEST-3610 parents,
    since one real client instance is shared by both scenario boundaries."""

    def __init__(self):
        self.calls: list[tuple] = []
        self.created: list[tuple[str, dict]] = []
        self.transitions_applied: list[tuple[str, str]] = []
        self.fail_create_for: set[str] = set()
        self._next_seq = 9000
        self._status_by_key: dict[str, str] = {}
        self._fields_by_key: dict[str, dict] = {}

    def get_issue(self, issue_key, *, expand=None):
        self.calls.append(("get_issue", issue_key))
        if issue_key in self._fields_by_key:
            fields = self._fields_by_key[issue_key]
            custom_fields = {
                k: v for k, v in fields.items() if k.startswith("customfield_")
            }
            return {
                "fields": {
                    "status": {"name": self._status_by_key.get(issue_key, "New")},
                    "parent": fields.get("parent", {}),
                    "labels": fields.get("labels", []),
                    **custom_fields,
                }
            }
        # Parent Test Case lookup (RHELTEST-3600 / RHELTEST-3610).
        return {
            "key": issue_key,
            "fields": {
                "project": {"key": "RHELTEST"},
                "issuetype": {"name": "Test Case"},
                "labels": ["ramen-dr", "automation"],
            },
        }

    def get_transitions(self, issue_key):
        self.calls.append(("get_transitions", issue_key))
        return [
            {"id": "2", "name": "New"},
            {"id": "3", "name": "PASS"},
            {"id": "4", "name": "FAIL"},
            {"id": "5", "name": "Blocked"},
        ]

    def create_issue(self, fields):
        parent_key = fields["parent"]["key"]
        self.calls.append(("create_issue", parent_key))
        if parent_key in self.fail_create_for:
            raise JiraWriteError("simulated create failure")
        self._next_seq += 1
        key = f"RHELTEST-{self._next_seq}"
        self._fields_by_key[key] = fields
        self._status_by_key[key] = "New"
        self.created.append((key, fields))
        return key

    def transition_issue(self, issue_key, transition_id):
        self.calls.append(("transition_issue", issue_key, str(transition_id)))
        self._status_by_key[issue_key] = {
            "3": "PASS",
            "4": "FAIL",
            "5": "Blocked",
        }.get(str(transition_id), "New")
        self.transitions_applied.append((issue_key, str(transition_id)))

    def outcome_for_parent(self, parent_key: str) -> str | None:
        """Return the last transition id applied to the Test Result created
        for *parent_key*, or None if nothing was ever created for it."""
        for key, fields in self.created:
            if fields["parent"]["key"] == parent_key:
                applied = [t for k, t in self.transitions_applied if k == key]
                return applied[-1] if applied else None
        return None

    def summary_for_parent(self, parent_key: str) -> str | None:
        for _key, fields in self.created:
            if fields["parent"]["key"] == parent_key:
                return fields["summary"]
        return None


def _make_run_dr_data_validation(raise_for_phase: str | None = None):
    calls: list[str] = []

    def fn(*, phase, initiated_utc=None):
        calls.append(phase)
        if phase == raise_for_phase:
            raise AssertionError(f"simulated DR data validation failure for {phase}")

    fn.calls = calls  # type: ignore[attr-defined]
    return fn


def _patch_common(monkeypatch, *, initial_state: dict, backend_phase: str, client):
    """Patch every DR/Playwright/oc-touching dependency of test_sanity.py's
    adaptive flow to a no-op or scripted fake, and force RAMENDR_SANITY_FORCE_FULL
    off so the resume-aware branch (not _run_force_full_sanity_dr_flow) runs."""
    monkeypatch.setattr(sanity, "_FORCE_FULL_SANITY", False)
    monkeypatch.setattr(sanity, "_require_ui_credentials", lambda: None)
    monkeypatch.setattr(sanity, "LoginPage", _FakeLoginPage)
    monkeypatch.setattr(sanity, "DashboardPage", _FakeDashboardPage)
    monkeypatch.setattr(
        sanity,
        "DRPCPage",
        lambda page: _FakeDRPCPage(page, initial_state=initial_state),
    )
    monkeypatch.setattr(
        sanity,
        "_get_drpc_protected_condition",
        lambda: {
            "phase": backend_phase,
            "progression": "",
            "protected": "True",
            "protected_reason": "",
            "protected_message": "",
            "no_cluster_data_conflict": "True",
            "no_cluster_data_conflict_reason": "",
        },
    )
    monkeypatch.setattr(sanity, "_save_hammerdb_baseline_snapshot", lambda **kw: None)
    monkeypatch.setattr(sanity, "_run_cleanup_non_primary_cluster", lambda **kw: None)
    monkeypatch.setattr(
        sanity, "_wait_for_vms_running_with_ssh_service", lambda *a, **kw: []
    )
    monkeypatch.setattr(sanity, "_probe_ssh_via_pod", lambda *a, **kw: None)
    monkeypatch.setattr(sanity, "_assert_rto_within_standard", lambda **kw: None)
    monkeypatch.setattr(
        sanity, "_wait_for_drpc_healthy_with_recovery", lambda *a, **kw: None
    )
    monkeypatch.setattr(sanity, "_assert_managed_clusters_available", lambda: None)
    monkeypatch.setattr(sanity, "_is_relocate_truly_done", lambda *a, **kw: True)
    monkeypatch.setattr(
        sanity, "_wait_for_relocate_secondary_cleared", lambda *a, **kw: None
    )
    monkeypatch.setattr(sanity, "_relocate_best_effort_progress", lambda *a, **kw: None)
    monkeypatch.setattr(sanity, "JiraClient", lambda config: client)


def _enable_jira_env(monkeypatch, **overrides):
    env = {
        "JIRA_REPORT_RESULTS": "true",
        "JIRA_REPORT_DRY_RUN": "false",
        "JIRA_BASE_URL": "https://example.invalid",
        "JIRA_EMAIL": "test@example.invalid",
        "JIRA_API_TOKEN": "not-a-real-token",
        "JIRA_RUN_ID": "test-run-id",
    }
    env.update(overrides)
    for key, value in env.items():
        if value is None:
            monkeypatch.delenv(key, raising=False)
        else:
            monkeypatch.setenv(key, value)


def _run_sanity_test(monkeypatch, *, run_dr_data_validation):
    monkeypatch.setattr(sanity, "_run_dr_data_validation", run_dr_data_validation)
    sanity.TestUiSanity().test_sanity_disaster_recovery_ui(object())


# --------------------------------------------------------------------------
# Fresh run: both scenarios genuinely execute -> both report.
# --------------------------------------------------------------------------


def test_fresh_run_reports_failover_pass_and_relocate_pass(monkeypatch):
    client = FakeSanityJiraClient()
    _patch_common(
        monkeypatch,
        initial_state=_HEALTHY_PRIMARY_FRESH,
        backend_phase="Deployed",
        client=client,
    )
    _enable_jira_env(monkeypatch)

    _run_sanity_test(monkeypatch, run_dr_data_validation=_make_run_dr_data_validation())

    assert client.outcome_for_parent("RHELTEST-3600") == "3"  # PASS
    assert client.outcome_for_parent("RHELTEST-3610") == "3"  # PASS


def test_fresh_run_failover_and_relocate_share_one_run_id(monkeypatch):
    client = FakeSanityJiraClient()
    _patch_common(
        monkeypatch,
        initial_state=_HEALTHY_PRIMARY_FRESH,
        backend_phase="Deployed",
        client=client,
    )
    _enable_jira_env(monkeypatch, JIRA_RUN_ID="shared-run-xyz")

    _run_sanity_test(monkeypatch, run_dr_data_validation=_make_run_dr_data_validation())

    failover_summary = client.summary_for_parent("RHELTEST-3600")
    relocate_summary = client.summary_for_parent("RHELTEST-3610")
    assert failover_summary.endswith("| shared-run-xyz")
    assert relocate_summary.endswith("| shared-run-xyz")


# --------------------------------------------------------------------------
# Resume behavior
# --------------------------------------------------------------------------


def test_resume_after_failover_does_not_report_a_false_failover_pass(monkeypatch):
    """post_failover: only relocate genuinely executes this invocation --
    RHELTEST-3600 must get NO Jira Test Result, RHELTEST-3610 gets PASS."""
    client = FakeSanityJiraClient()
    _patch_common(
        monkeypatch,
        initial_state=_HEALTHY_SECONDARY_POST_FAILOVER,
        backend_phase="FailedOver",
        client=client,
    )
    _enable_jira_env(monkeypatch)

    _run_sanity_test(monkeypatch, run_dr_data_validation=_make_run_dr_data_validation())

    assert client.outcome_for_parent("RHELTEST-3600") is None  # never created
    assert client.outcome_for_parent("RHELTEST-3610") == "3"  # PASS


def test_resume_after_relocate_fabricates_no_results(monkeypatch):
    """post_relocate: nothing new is executed this invocation -- neither
    RHELTEST-3600 nor RHELTEST-3610 should get a Jira Test Result."""
    client = FakeSanityJiraClient()
    _patch_common(
        monkeypatch,
        initial_state=_HEALTHY_PRIMARY_POST_RELOCATE,
        backend_phase="Relocated",
        client=client,
    )
    _enable_jira_env(monkeypatch)

    _run_sanity_test(monkeypatch, run_dr_data_validation=_make_run_dr_data_validation())

    assert client.created == []
    assert client.outcome_for_parent("RHELTEST-3600") is None
    assert client.outcome_for_parent("RHELTEST-3610") is None


# --------------------------------------------------------------------------
# Independent failure attribution
# --------------------------------------------------------------------------


def test_failure_during_failover_reports_only_failover_fail(monkeypatch):
    client = FakeSanityJiraClient()
    _patch_common(
        monkeypatch,
        initial_state=_HEALTHY_PRIMARY_FRESH,
        backend_phase="Deployed",
        client=client,
    )
    _enable_jira_env(monkeypatch)

    import pytest

    with pytest.raises(AssertionError, match="failover"):
        _run_sanity_test(
            monkeypatch,
            run_dr_data_validation=_make_run_dr_data_validation(
                raise_for_phase="failover"
            ),
        )

    assert client.outcome_for_parent("RHELTEST-3600") == "4"  # FAIL
    assert client.outcome_for_parent("RHELTEST-3610") is None  # never even started


def test_failover_pass_then_relocate_fail_reported_independently(monkeypatch):
    """The example from the spec: failover succeeds, relocate fails ->
    RHELTEST-3600 PASS, RHELTEST-3610 FAIL (never both FAIL)."""
    client = FakeSanityJiraClient()
    _patch_common(
        monkeypatch,
        initial_state=_HEALTHY_PRIMARY_FRESH,
        backend_phase="Deployed",
        client=client,
    )
    _enable_jira_env(monkeypatch)

    import pytest

    with pytest.raises(AssertionError, match="relocate"):
        _run_sanity_test(
            monkeypatch,
            run_dr_data_validation=_make_run_dr_data_validation(
                raise_for_phase="relocate"
            ),
        )

    assert client.outcome_for_parent("RHELTEST-3600") == "3"  # PASS
    assert client.outcome_for_parent("RHELTEST-3610") == "4"  # FAIL


# --------------------------------------------------------------------------
# Reporting disabled / dry-run
# --------------------------------------------------------------------------


def test_reporting_disabled_makes_zero_jira_calls(monkeypatch):
    client = FakeSanityJiraClient()
    _patch_common(
        monkeypatch,
        initial_state=_HEALTHY_PRIMARY_FRESH,
        backend_phase="Deployed",
        client=client,
    )
    _enable_jira_env(monkeypatch, JIRA_REPORT_RESULTS="false")

    _run_sanity_test(monkeypatch, run_dr_data_validation=_make_run_dr_data_validation())

    assert client.calls == []
    assert client.created == []


def test_dry_run_makes_no_jira_writes(monkeypatch):
    client = FakeSanityJiraClient()
    _patch_common(
        monkeypatch,
        initial_state=_HEALTHY_PRIMARY_FRESH,
        backend_phase="Deployed",
        client=client,
    )
    _enable_jira_env(monkeypatch, JIRA_REPORT_DRY_RUN="true")

    _run_sanity_test(monkeypatch, run_dr_data_validation=_make_run_dr_data_validation())

    assert client.created == []
    assert client.transitions_applied == []
    # Dry-run still performs the (read-only) parent validation GET.
    assert ("get_issue", "RHELTEST-3600") in client.calls
    assert ("get_issue", "RHELTEST-3610") in client.calls


# --------------------------------------------------------------------------
# Jira-reporting failure while the scenario itself fails/succeeds
# --------------------------------------------------------------------------


def test_jira_reporting_failure_while_scenario_fails_preserves_original_exception(
    monkeypatch,
):
    client = FakeSanityJiraClient()
    client.fail_create_for.add("RHELTEST-3600")
    _patch_common(
        monkeypatch,
        initial_state=_HEALTHY_PRIMARY_FRESH,
        backend_phase="Deployed",
        client=client,
    )
    _enable_jira_env(monkeypatch)

    import pytest

    # The DR/scenario exception -- not a Jira error -- must be what escapes.
    with pytest.raises(AssertionError, match="failover"):
        _run_sanity_test(
            monkeypatch,
            run_dr_data_validation=_make_run_dr_data_validation(
                raise_for_phase="failover"
            ),
        )


def test_jira_reporting_failure_after_pass_respects_strict_flag(monkeypatch):
    client = FakeSanityJiraClient()
    client.fail_create_for.add("RHELTEST-3600")
    _patch_common(
        monkeypatch,
        initial_state=_HEALTHY_PRIMARY_FRESH,
        backend_phase="Deployed",
        client=client,
    )
    _enable_jira_env(monkeypatch, JIRA_REPORT_STRICT="true")

    import pytest

    with pytest.raises(JiraWriteError):
        _run_sanity_test(
            monkeypatch, run_dr_data_validation=_make_run_dr_data_validation()
        )


def test_jira_reporting_failure_after_pass_is_swallowed_by_default(monkeypatch):
    client = FakeSanityJiraClient()
    client.fail_create_for.add("RHELTEST-3600")
    _patch_common(
        monkeypatch,
        initial_state=_HEALTHY_PRIMARY_FRESH,
        backend_phase="Deployed",
        client=client,
    )
    _enable_jira_env(monkeypatch, JIRA_REPORT_STRICT="false")

    # Must NOT raise -- the scenario itself passed, and JIRA_REPORT_STRICT
    # defaults to false, so the Jira write failure is only logged.
    _run_sanity_test(monkeypatch, run_dr_data_validation=_make_run_dr_data_validation())

    assert client.outcome_for_parent("RHELTEST-3610") == "3"  # relocate still PASS
