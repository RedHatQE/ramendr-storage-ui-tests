"""Unit tests for the read-only Jira Test Result discovery script.

Jira is always mocked (a fake JiraClient is injected); the script never
contacts a real Jira instance and never issues a write.
"""

from __future__ import annotations

import importlib.util
import json
from pathlib import Path

_HELPER = (
    Path(__file__).resolve().parents[2]
    / "scripts"
    / "jira"
    / "discover_test_result_schema.py"
)
_spec = importlib.util.spec_from_file_location("discover_test_result_schema", _HELPER)
assert _spec is not None and _spec.loader is not None
discover = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(discover)


# --------------------------------------------------------------------------
# Pure helper functions
# --------------------------------------------------------------------------


def test_find_test_result_issue_type_matches_by_name():
    issue_types = [
        {"id": "1", "name": "Test Case"},
        {"id": "2", "name": "Test Result", "subtask": False, "hierarchyLevel": 0},
    ]
    found = discover.find_test_result_issue_type(issue_types)
    assert found == issue_types[1]


def test_find_test_result_issue_type_returns_none_when_missing():
    assert discover.find_test_result_issue_type([{"id": "1", "name": "Bug"}]) is None


def test_find_issue_type_by_name_is_exact_match_not_substring():
    items = [
        {"id": "1", "name": "Test Result Extra"},
        {"id": "2", "name": "Test Result"},
    ]
    found = discover.find_issue_type_by_name(items, "Test Result")
    assert found == items[1]


def test_sanitize_issue_type_extracts_expected_keys():
    sanitized = discover.sanitize_issue_type(
        {
            "id": "10500",
            "name": "Test Result",
            "subtask": True,
            "hierarchyLevel": -1,
            "iconUrl": "https://example/icon.png",
            "description": "internal notes",
        }
    )
    assert sanitized == {
        "id": "10500",
        "name": "Test Result",
        "subtask": True,
        "hierarchyLevel": -1,
        "iconUrl": "https://example/icon.png",
    }


def test_sanitize_global_issue_type_extracts_scope():
    sanitized = discover.sanitize_global_issue_type(
        {
            "id": "10500",
            "name": "Test Result",
            "subtask": False,
            "hierarchyLevel": 0,
            "scope": {"type": "PROJECT", "project": {"id": "11493"}},
            "description": "internal notes",
        }
    )
    assert sanitized == {
        "id": "10500",
        "name": "Test Result",
        "subtask": False,
        "hierarchyLevel": 0,
        "scope_type": "PROJECT",
        "scope_project_id": "11493",
    }


def test_sanitize_global_issue_type_handles_missing_scope():
    sanitized = discover.sanitize_global_issue_type({"id": "1", "name": "Bug"})
    assert sanitized["scope_type"] is None
    assert sanitized["scope_project_id"] is None


def test_sanitize_project_issue_type_extracts_expected_keys():
    sanitized = discover.sanitize_project_issue_type(
        {
            "id": "10500",
            "name": "Test Result",
            "subtask": False,
            "hierarchyLevel": 0,
            "avatarId": 12345,
        }
    )
    assert sanitized == {
        "id": "10500",
        "name": "Test Result",
        "subtask": False,
        "hierarchyLevel": 0,
    }


def test_build_field_rows_sorted_by_name():
    create_fields = {
        "summary": {
            "name": "Summary",
            "required": True,
            "schema": {"type": "string"},
            "operations": ["set"],
        },
        "customfield_12345": {
            "name": "Compose Version",
            "required": False,
            "schema": {"type": "string", "custom": "com.atlassian:textfield"},
            "operations": ["set"],
            "allowedValues": [{"id": "1", "value": "1.3.0"}],
        },
    }
    rows = discover.build_field_rows(create_fields)
    assert [r["name"] for r in rows] == ["Compose Version", "Summary"]
    compose = rows[0]
    assert compose["field_id"] == "customfield_12345"
    assert compose["required"] is False
    assert compose["schema_custom"] == "com.atlassian:textfield"
    assert compose["allowed_values"] == [{"id": "1", "value": "1.3.0"}]


def test_find_field_rows_by_name_is_case_insensitive():
    rows = [
        {"name": "Compose Version", "field_id": "customfield_1"},
        {"name": "Fix versions", "field_id": "fixVersions"},
    ]
    matches = discover.find_field_rows_by_name(rows, "compose version")
    assert [m["field_id"] for m in matches] == ["customfield_1"]


def test_format_field_table_contains_header_and_rows():
    rows = discover.build_field_rows(
        {
            "summary": {
                "name": "Summary",
                "required": True,
                "schema": {"type": "string"},
            }
        }
    )
    table = discover.format_field_table(rows)
    assert "FIELD NAME" in table
    assert "Summary" in table
    assert "summary" in table


def test_sanitize_sample_issue_extracts_custom_fields_of_interest():
    issue = {
        "key": "RHELTEST-9001",
        "names": {
            "customfield_100": "Compose Version",
            "customfield_200": "Unrelated Field",
        },
        "fields": {
            "issuetype": {"id": "2", "name": "Test Result", "subtask": False},
            "status": {"name": "PASS"},
            "parent": {"key": "RHELTEST-3600"},
            "labels": ["ramen-dr", "automation"],
            "fixVersions": [],
            "reporter": {
                "accountId": "acc-1",
                "displayName": "QE Bot",
                "emailAddress": "x@example.com",
            },
            "assignee": None,
            "description": {"type": "doc"},
            "customfield_100": "rhdr-1.3.0-compose",
            "customfield_200": "should not be captured",
        },
    }
    sanitized = discover.sanitize_sample_issue(issue)
    assert sanitized["key"] == "RHELTEST-9001"
    assert sanitized["issuetype"] == {
        "id": "2",
        "name": "Test Result",
        "subtask": False,
    }
    assert sanitized["parent"] == {"key": "RHELTEST-3600"}
    assert sanitized["labels"] == ["ramen-dr", "automation"]
    assert sanitized["reporter"] == {"accountId": "acc-1", "displayName": "QE Bot"}
    assert sanitized["assignee"] is None
    assert sanitized["description_present"] is True
    assert sanitized["custom_fields_of_interest"] == {
        "customfield_100": {"name": "Compose Version", "value": "rhdr-1.3.0-compose"}
    }
    # Unrelated custom fields (and email addresses) must never be captured.
    assert "customfield_200" not in sanitized["custom_fields_of_interest"]
    assert "x@example.com" not in json.dumps(sanitized)


def test_sanitize_transitions_extracts_target_status():
    transitions = [
        {"id": "31", "name": "Pass", "to": {"id": "10001", "name": "PASS"}},
        {"id": "41", "name": "Fail", "to": {"id": "10002", "name": "FAIL"}},
    ]
    sanitized = discover.sanitize_transitions(transitions)
    assert sanitized == [
        {
            "transition_id": "31",
            "transition_name": "Pass",
            "to_status_id": "10001",
            "to_status_name": "PASS",
        },
        {
            "transition_id": "41",
            "transition_name": "Fail",
            "to_status_id": "10002",
            "to_status_name": "FAIL",
        },
    ]


def test_build_config_never_puts_secrets_in_argparse_defaults(monkeypatch):
    monkeypatch.setenv("JIRA_EMAIL", "secret@example.com")
    monkeypatch.setenv("JIRA_API_TOKEN", "super-secret-token")
    parser = discover.build_arg_parser()
    help_text = parser.format_help()
    assert "secret@example.com" not in help_text
    assert "super-secret-token" not in help_text


# --------------------------------------------------------------------------
# diagnose_test_result_availability (pure, no client)
# --------------------------------------------------------------------------


def test_diagnose_returns_inconclusive_when_no_sample_and_not_in_createmeta():
    diagnosis = discover.diagnose_test_result_availability(
        create_metadata_has_test_result=False,
        sample_issue_type_id=None,
        sample_issue_type_name=None,
        sample_issue_type_subtask=None,
        associated_with_project_issue_type_scheme=None,
        create_fields_probe_field_count=None,
        create_fields_probe_error=None,
    )
    assert diagnosis["exists_in_project"] is False
    assert diagnosis["likely_cause"] == "inconclusive"


def test_diagnose_reports_no_blocker_when_createmeta_has_it():
    diagnosis = discover.diagnose_test_result_availability(
        create_metadata_has_test_result=True,
        sample_issue_type_id="2",
        sample_issue_type_name="Test Result",
        sample_issue_type_subtask=False,
        associated_with_project_issue_type_scheme=True,
        create_fields_probe_field_count=5,
        create_fields_probe_error=None,
    )
    assert diagnosis["exists_in_project"] is True
    assert diagnosis["likely_cause"] == "none"


def test_diagnose_flags_discovery_code_assumption_when_direct_probe_returns_fields():
    diagnosis = discover.diagnose_test_result_availability(
        create_metadata_has_test_result=False,
        sample_issue_type_id="2",
        sample_issue_type_name="Test Result",
        sample_issue_type_subtask=False,
        associated_with_project_issue_type_scheme=True,
        create_fields_probe_field_count=4,
        create_fields_probe_error=None,
    )
    assert diagnosis["likely_cause"] == "discovery_code_assumption"


def test_diagnose_does_not_flag_discovery_code_assumption_when_probe_returns_zero_fields():
    """A probe that succeeds (HTTP 200) with zero fields is NOT proof of a bug in
    our own listing code -- Jira Cloud returns exactly this (200 + empty) when a
    type genuinely isn't createable for the current user/project. This is the
    real production scenario observed for RHELTEST Test Result (id=10272).
    """
    diagnosis = discover.diagnose_test_result_availability(
        create_metadata_has_test_result=False,
        sample_issue_type_id="10272",
        sample_issue_type_name="Test Result",
        sample_issue_type_subtask=True,
        associated_with_project_issue_type_scheme=True,
        create_fields_probe_field_count=0,
        create_fields_probe_error=None,
        create_issues_permission=True,
    )
    assert diagnosis["likely_cause"] != "discovery_code_assumption"
    assert diagnosis["likely_cause"] == "hierarchy_or_parent_requirement"


def test_diagnose_flags_hierarchy_or_parent_requirement_for_subtask_type():
    diagnosis = discover.diagnose_test_result_availability(
        create_metadata_has_test_result=False,
        sample_issue_type_id="2",
        sample_issue_type_name="Test Result",
        sample_issue_type_subtask=True,
        associated_with_project_issue_type_scheme=True,
        create_fields_probe_field_count=None,
        create_fields_probe_error="GET ... failed: HTTP 400",
    )
    assert diagnosis["likely_cause"] == "hierarchy_or_parent_requirement"


def test_diagnose_flags_create_screen_configuration_for_non_subtask_type():
    diagnosis = discover.diagnose_test_result_availability(
        create_metadata_has_test_result=False,
        sample_issue_type_id="2",
        sample_issue_type_name="Test Result",
        sample_issue_type_subtask=False,
        associated_with_project_issue_type_scheme=True,
        create_fields_probe_field_count=None,
        create_fields_probe_error="GET ... failed: HTTP 400",
    )
    assert diagnosis["likely_cause"] == "create_screen_configuration"


def test_diagnose_flags_permission_when_probe_error_is_403():
    diagnosis = discover.diagnose_test_result_availability(
        create_metadata_has_test_result=False,
        sample_issue_type_id="2",
        sample_issue_type_name="Test Result",
        sample_issue_type_subtask=False,
        associated_with_project_issue_type_scheme=True,
        create_fields_probe_field_count=None,
        create_fields_probe_error="GET ... failed: missing permission (HTTP 403)",
    )
    assert diagnosis["likely_cause"] == "permission"


def test_diagnose_flags_permission_when_mypermissions_reports_false():
    """GET /mypermissions is a direct, authoritative signal and should win over
    weaker heuristics (subtask/scheme-association guesses)."""
    diagnosis = discover.diagnose_test_result_availability(
        create_metadata_has_test_result=False,
        sample_issue_type_id="2",
        sample_issue_type_name="Test Result",
        sample_issue_type_subtask=True,
        associated_with_project_issue_type_scheme=True,
        create_fields_probe_field_count=None,
        create_fields_probe_error=None,
        create_issues_permission=False,
    )
    assert diagnosis["likely_cause"] == "permission"


def test_diagnose_flags_permission_when_entire_createmeta_listing_is_empty():
    """If the createmeta issuetypes *listing* is empty for every type (not just
    Test Result), that is documented Jira Cloud behavior for a user lacking
    Create-issue permission on the project -- a project-wide problem, not a
    Test-Result-specific one."""
    diagnosis = discover.diagnose_test_result_availability(
        create_metadata_has_test_result=False,
        create_issue_types_listing_empty=True,
        sample_issue_type_id="10272",
        sample_issue_type_name="Test Result",
        sample_issue_type_subtask=True,
        associated_with_project_issue_type_scheme=True,
        create_fields_probe_field_count=0,
        create_fields_probe_error=None,
        create_issues_permission=None,
    )
    assert diagnosis["likely_cause"] == "permission"


def test_diagnose_flags_create_screen_configuration_when_not_in_project_scheme():
    diagnosis = discover.diagnose_test_result_availability(
        create_metadata_has_test_result=False,
        sample_issue_type_id="2",
        sample_issue_type_name="Test Result",
        sample_issue_type_subtask=False,
        associated_with_project_issue_type_scheme=False,
        create_fields_probe_field_count=None,
        create_fields_probe_error="GET ... failed: HTTP 400",
    )
    assert diagnosis["likely_cause"] == "create_screen_configuration"


def test_diagnose_never_treats_absence_from_createmeta_as_nonexistence():
    """Absence from create metadata must never by itself imply exists_in_project=False."""
    diagnosis = discover.diagnose_test_result_availability(
        create_metadata_has_test_result=False,
        sample_issue_type_id="2",
        sample_issue_type_name="Test Result",
        sample_issue_type_subtask=False,
        associated_with_project_issue_type_scheme=True,
        create_fields_probe_field_count=None,
        create_fields_probe_error="GET ... failed: HTTP 400",
    )
    assert diagnosis["exists_in_project"] is True
    assert diagnosis["viewable_by_current_user"] is True
    assert diagnosis["createable_via_create_metadata"] is False


# --------------------------------------------------------------------------
# Full discovery run against a fake (read-only) client
# --------------------------------------------------------------------------


class FakeDiscoveryClient:
    """Fake JiraClient used to prove the script only ever calls GET-shaped methods.

    Defaults represent the "happy path": Test Result (id=2) IS present in
    create metadata. Subclasses override specific methods to represent the
    "missing from create metadata" diagnostic scenarios.
    """

    def __init__(self):
        self.calls: list[str] = []

    def get_current_user(self):
        self.calls.append("get_current_user")
        return {"displayName": "QE Bot", "accountId": "acc-1"}

    def get_project(self, project_key):
        self.calls.append("get_project")
        return {"id": "11493", "key": project_key, "name": "RHEL Testing"}

    def get_create_issue_types(self, project_key):
        self.calls.append("get_create_issue_types")
        return [
            {"id": "1", "name": "Test Case", "subtask": False},
            {"id": "2", "name": "Test Result", "subtask": False, "hierarchyLevel": 0},
        ]

    def get_project_issue_types(self, project_id):
        self.calls.append("get_project_issue_types")
        return [
            {"id": "1", "name": "Test Case", "subtask": False},
            {"id": "2", "name": "Test Result", "subtask": False, "hierarchyLevel": 0},
        ]

    def get_issue_type(self, issue_type_id):
        self.calls.append("get_issue_type")
        return {
            "id": issue_type_id,
            "name": "Test Result",
            "subtask": False,
            "hierarchyLevel": 0,
            "scope": {"type": "PROJECT", "project": {"id": "11493"}},
        }

    def get_create_fields(self, project_key, issue_type_id):
        self.calls.append("get_create_fields")
        return {
            "summary": {
                "name": "Summary",
                "required": True,
                "schema": {"type": "string"},
            },
            "parent": {
                "name": "Parent",
                "required": False,
                "schema": {"type": "issuelink"},
            },
            "customfield_12345": {
                "name": "Compose Version",
                "required": False,
                "schema": {"type": "string", "custom": "textfield"},
            },
            "labels": {
                "name": "Labels",
                "required": False,
                "schema": {"type": "array", "items": "string"},
            },
        }

    def get_fields(self):
        self.calls.append("get_fields")
        return [{"id": "customfield_12345", "name": "Compose Version"}]

    def get_issue(self, issue_key, *, expand=None):
        self.calls.append("get_issue")
        return {
            "key": issue_key,
            "names": {"customfield_12345": "Compose Version"},
            "fields": {
                "issuetype": {"id": "2", "name": "Test Result", "subtask": False},
                "status": {"name": "PASS"},
                "parent": {"key": "RHELTEST-3600"},
                "labels": ["ramen-dr", "automation"],
                "fixVersions": [],
                "reporter": None,
                "assignee": None,
                "description": None,
                "customfield_12345": "rhdr-1.3.0",
            },
        }

    def get_transitions(self, issue_key):
        self.calls.append("get_transitions")
        return [{"id": "31", "name": "Pass", "to": {"id": "10001", "name": "PASS"}}]

    def get_my_permissions(self, project_key, permissions):
        self.calls.append("get_my_permissions")
        return {"permissions": {"CREATE_ISSUES": {"havePermission": True}}}


def _args(output_dir: Path, sample: str | None = None) -> "object":
    parser = discover.build_arg_parser()
    argv = [
        "--base-url",
        "https://redhat.atlassian.net",
        "--project",
        "RHELTEST",
        "--output-dir",
        str(output_dir),
    ]
    if sample:
        argv += ["--sample-test-result", sample]
    return parser.parse_args(argv)


def _run(tmp_path, monkeypatch, client, *, sample: str | None = None) -> int:
    monkeypatch.setattr(discover, "JiraClient", lambda config: client)
    monkeypatch.setenv("JIRA_EMAIL", "qe@example.com")
    monkeypatch.setenv("JIRA_API_TOKEN", "secret-token-value")
    return discover.run_discovery(_args(tmp_path, sample=sample))


_WRITE_LIKE_CALLS = {"create_issue", "transition_issue", "post", "put", "delete"}


def test_run_discovery_never_calls_any_write_method(tmp_path, monkeypatch):
    fake_client = FakeDiscoveryClient()
    exit_code = _run(tmp_path, monkeypatch, fake_client)

    assert exit_code == 0
    assert not (_WRITE_LIKE_CALLS & set(fake_client.calls))
    assert fake_client.calls == [
        "get_current_user",
        "get_project",
        "get_create_issue_types",
        "get_project_issue_types",
        "get_issue_type",
        "get_create_fields",
        "get_my_permissions",
        "get_fields",
    ]


def test_run_discovery_with_sample_fetches_issue_and_transitions(tmp_path, monkeypatch):
    fake_client = FakeDiscoveryClient()
    exit_code = _run(tmp_path, monkeypatch, fake_client, sample="RHELTEST-3600")

    assert exit_code == 0
    assert not (_WRITE_LIKE_CALLS & set(fake_client.calls))
    assert "get_issue" in fake_client.calls
    assert "get_transitions" in fake_client.calls
    assert (tmp_path / "sample-test-result.json").exists()
    assert (tmp_path / "test-result-transitions.json").exists()


def test_run_discovery_writes_expected_output_files(tmp_path, monkeypatch, capsys):
    fake_client = FakeDiscoveryClient()
    _run(tmp_path, monkeypatch, fake_client)

    for name in (
        "project.json",
        "issue-types.json",
        "project-issue-types.json",
        "test-result-issuetype.json",
        "test-result-create-fields.json",
        "jira-fields.json",
        "test-result-diagnosis.json",
        "discovery-summary.txt",
    ):
        assert (tmp_path / name).exists(), f"missing {name}"

    project = json.loads((tmp_path / "project.json").read_text())
    assert project == {
        "project_id": "11493",
        "project_key": "RHELTEST",
        "project_name": "RHEL Testing",
    }

    summary = (tmp_path / "discovery-summary.txt").read_text()
    assert "Test Result issue type ID            = 2" in summary

    captured = capsys.readouterr()
    assert "secret-token-value" not in captured.out
    assert "secret-token-value" not in summary


def test_run_discovery_fails_clearly_when_test_result_type_missing_everywhere(
    tmp_path, monkeypatch
):
    """No createmeta hit, no sample given, and not in the project issue-type scheme."""

    class NoTestResultClient(FakeDiscoveryClient):
        def get_create_issue_types(self, project_key):
            self.calls.append("get_create_issue_types")
            return [{"id": "1", "name": "Test Case", "subtask": False}]

        def get_project_issue_types(self, project_id):
            self.calls.append("get_project_issue_types")
            return [{"id": "1", "name": "Test Case", "subtask": False}]

    fake_client = NoTestResultClient()
    exit_code = _run(tmp_path, monkeypatch, fake_client)

    assert exit_code == 1
    assert "get_create_fields" not in fake_client.calls
    assert "get_issue_type" not in fake_client.calls

    diagnosis = json.loads((tmp_path / "test-result-diagnosis.json").read_text())
    assert diagnosis["exists_in_project"] is False
    assert diagnosis["likely_cause"] == "inconclusive"


def test_run_discovery_continues_and_diagnoses_when_missing_from_createmeta_but_sample_given(
    tmp_path, monkeypatch
):
    """Reproduces the real-world case: Test Result absent from createmeta, but a
    real sample (e.g. RHELTEST-3590) exists and the direct probe still fails.
    Discovery must NOT abort -- it must keep gathering diagnostics and exit 0.
    """

    class MissingFromCreateMetaClient(FakeDiscoveryClient):
        def get_create_issue_types(self, project_key):
            self.calls.append("get_create_issue_types")
            return [{"id": "1", "name": "Test Case", "subtask": False}]

        def get_create_fields(self, project_key, issue_type_id):
            self.calls.append("get_create_fields")
            raise discover.JiraClientError(
                f"GET issue/createmeta/{project_key}/issuetypes/{issue_type_id} "
                "failed: HTTP 400"
            )

    fake_client = MissingFromCreateMetaClient()
    exit_code = _run(tmp_path, monkeypatch, fake_client, sample="RHELTEST-3590")

    # Must NOT abort: sample resolves the issue type, so discovery keeps going.
    assert exit_code == 0
    assert not (_WRITE_LIKE_CALLS & set(fake_client.calls))
    assert "get_issue" in fake_client.calls
    assert "get_transitions" in fake_client.calls
    assert "get_issue_type" in fake_client.calls
    # The probe was attempted (read-only GET) even though createmeta lacked it.
    assert "get_create_fields" in fake_client.calls

    diagnosis = json.loads((tmp_path / "test-result-diagnosis.json").read_text())
    assert diagnosis["exists_in_project"] is True
    assert diagnosis["viewable_by_current_user"] is True
    assert diagnosis["createable_via_create_metadata"] is False
    assert diagnosis["associated_with_project_issue_type_scheme"] is True
    assert diagnosis["create_fields_probe_field_count"] is None
    assert diagnosis["likely_cause"] == "create_screen_configuration"

    summary = (tmp_path / "discovery-summary.txt").read_text()
    assert "Test Result availability diagnosis" in summary
    assert "Likely cause" in summary
    assert "secret-token-value" not in summary


def test_run_discovery_flags_permission_cause_when_probe_returns_403(
    tmp_path, monkeypatch
):
    class PermissionDeniedClient(FakeDiscoveryClient):
        def get_create_issue_types(self, project_key):
            self.calls.append("get_create_issue_types")
            return [{"id": "1", "name": "Test Case", "subtask": False}]

        def get_create_fields(self, project_key, issue_type_id):
            self.calls.append("get_create_fields")
            raise discover.JiraPermissionError(
                f"GET issue/createmeta/{project_key}/issuetypes/{issue_type_id} "
                "failed: missing permission (HTTP 403)"
            )

    fake_client = PermissionDeniedClient()
    exit_code = _run(tmp_path, monkeypatch, fake_client, sample="RHELTEST-3590")

    assert exit_code == 0
    diagnosis = json.loads((tmp_path / "test-result-diagnosis.json").read_text())
    assert diagnosis["likely_cause"] == "permission"


def test_run_discovery_flags_discovery_code_assumption_when_probe_succeeds(
    tmp_path, monkeypatch
):
    """If createmeta's issuetypes *listing* omits Test Result but a direct
    createmeta probe by id still returns fields, that's evidence of a gap in
    our own discovery/listing logic, not a real Jira restriction.
    """

    class ListingGapClient(FakeDiscoveryClient):
        def get_create_issue_types(self, project_key):
            self.calls.append("get_create_issue_types")
            return [{"id": "1", "name": "Test Case", "subtask": False}]

    fake_client = ListingGapClient()
    exit_code = _run(tmp_path, monkeypatch, fake_client, sample="RHELTEST-3590")

    assert exit_code == 0
    assert "get_create_fields" in fake_client.calls
    diagnosis = json.loads((tmp_path / "test-result-diagnosis.json").read_text())
    assert diagnosis["create_fields_probe_field_count"] == 4
    assert diagnosis["likely_cause"] == "discovery_code_assumption"


def test_run_discovery_flags_permission_when_listing_empty_and_probe_returns_zero_fields(
    tmp_path, monkeypatch
):
    """Reproduces the real RHELTEST production case: the createmeta issuetypes
    *listing* is entirely empty (every type, not just Test Result), and the
    direct per-id probe succeeds (HTTP 200) but returns zero fields. This must
    be diagnosed as a permission problem, not `discovery_code_assumption`.
    """

    class EmptyListingClient(FakeDiscoveryClient):
        def get_create_issue_types(self, project_key):
            self.calls.append("get_create_issue_types")
            return []

        def get_create_fields(self, project_key, issue_type_id):
            self.calls.append("get_create_fields")
            return {}

    fake_client = EmptyListingClient()
    exit_code = _run(tmp_path, monkeypatch, fake_client, sample="RHELTEST-3590")

    assert exit_code == 0
    diagnosis = json.loads((tmp_path / "test-result-diagnosis.json").read_text())
    assert diagnosis["create_fields_probe_field_count"] == 0
    assert diagnosis["likely_cause"] == "permission"
    assert (tmp_path / "issue-types.json").read_text().strip() == "[]"


def test_run_discovery_flags_permission_when_mypermissions_reports_false(
    tmp_path, monkeypatch
):
    class NoCreatePermissionClient(FakeDiscoveryClient):
        def get_create_issue_types(self, project_key):
            self.calls.append("get_create_issue_types")
            return [{"id": "1", "name": "Test Case", "subtask": False}]

        def get_create_fields(self, project_key, issue_type_id):
            self.calls.append("get_create_fields")
            return {}

        def get_my_permissions(self, project_key, permissions):
            self.calls.append("get_my_permissions")
            return {"permissions": {"CREATE_ISSUES": {"havePermission": False}}}

    fake_client = NoCreatePermissionClient()
    exit_code = _run(tmp_path, monkeypatch, fake_client, sample="RHELTEST-3590")

    assert exit_code == 0
    diagnosis = json.loads((tmp_path / "test-result-diagnosis.json").read_text())
    assert diagnosis["create_issues_permission"] is False
    assert diagnosis["likely_cause"] == "permission"
    assert (tmp_path / "my-permissions.json").exists()


def test_run_discovery_flags_hierarchy_or_parent_requirement_for_subtask_sample(
    tmp_path, monkeypatch
):
    class SubtaskClient(FakeDiscoveryClient):
        def get_create_issue_types(self, project_key):
            self.calls.append("get_create_issue_types")
            return [{"id": "1", "name": "Test Case", "subtask": False}]

        def get_issue(self, issue_key, *, expand=None):
            self.calls.append("get_issue")
            return {
                "key": issue_key,
                "names": {},
                "fields": {
                    "issuetype": {"id": "2", "name": "Test Result", "subtask": True},
                    "status": {"name": "PASS"},
                    "parent": {"key": "RHELTEST-3600"},
                    "labels": [],
                    "fixVersions": [],
                    "reporter": None,
                    "assignee": None,
                    "description": None,
                },
            }

        def get_create_fields(self, project_key, issue_type_id):
            self.calls.append("get_create_fields")
            raise discover.JiraClientError("GET ... failed: HTTP 400")

    fake_client = SubtaskClient()
    exit_code = _run(tmp_path, monkeypatch, fake_client, sample="RHELTEST-3590")

    assert exit_code == 0
    diagnosis = json.loads((tmp_path / "test-result-diagnosis.json").read_text())
    assert diagnosis["likely_cause"] == "hierarchy_or_parent_requirement"


def test_run_discovery_flags_create_screen_configuration_when_not_in_scheme(
    tmp_path, monkeypatch
):
    class NotInSchemeClient(FakeDiscoveryClient):
        def get_create_issue_types(self, project_key):
            self.calls.append("get_create_issue_types")
            return [{"id": "1", "name": "Test Case", "subtask": False}]

        def get_project_issue_types(self, project_id):
            self.calls.append("get_project_issue_types")
            return [{"id": "1", "name": "Test Case", "subtask": False}]

        def get_create_fields(self, project_key, issue_type_id):
            self.calls.append("get_create_fields")
            raise discover.JiraClientError("GET ... failed: HTTP 400")

    fake_client = NotInSchemeClient()
    exit_code = _run(tmp_path, monkeypatch, fake_client, sample="RHELTEST-3590")

    assert exit_code == 0
    diagnosis = json.loads((tmp_path / "test-result-diagnosis.json").read_text())
    assert diagnosis["associated_with_project_issue_type_scheme"] is False
    assert diagnosis["likely_cause"] == "create_screen_configuration"


def test_run_discovery_survives_project_issue_types_fetch_failure(
    tmp_path, monkeypatch
):
    """GET /issuetype/project failing must not crash discovery; associated_with_*
    scheme becomes None (inconclusive) rather than raising.
    """

    class ProjectIssueTypesFailClient(FakeDiscoveryClient):
        def get_create_issue_types(self, project_key):
            self.calls.append("get_create_issue_types")
            return [{"id": "1", "name": "Test Case", "subtask": False}]

        def get_project_issue_types(self, project_id):
            self.calls.append("get_project_issue_types")
            raise discover.JiraClientError("GET issuetype/project failed: HTTP 500")

        def get_create_fields(self, project_key, issue_type_id):
            self.calls.append("get_create_fields")
            raise discover.JiraClientError("GET ... failed: HTTP 400")

    fake_client = ProjectIssueTypesFailClient()
    exit_code = _run(tmp_path, monkeypatch, fake_client, sample="RHELTEST-3590")

    assert exit_code == 0
    diagnosis = json.loads((tmp_path / "test-result-diagnosis.json").read_text())
    assert diagnosis["associated_with_project_issue_type_scheme"] is None
    assert diagnosis["exists_in_project"] is True
    assert not (tmp_path / "project-issue-types.json").exists()


def test_main_requires_base_url(monkeypatch):
    monkeypatch.delenv("JIRA_BASE_URL", raising=False)
    exit_code = discover.main(["--base-url", ""])
    assert exit_code == 2


def test_main_exits_cleanly_on_auth_error(tmp_path, monkeypatch):
    class UnauthorizedClient(FakeDiscoveryClient):
        def get_current_user(self):
            raise discover.JiraAuthenticationError(
                "GET myself failed: authentication invalid (HTTP 401)"
            )

    monkeypatch.setattr(discover, "JiraClient", lambda config: UnauthorizedClient())
    monkeypatch.setenv("JIRA_EMAIL", "qe@example.com")
    monkeypatch.setenv("JIRA_API_TOKEN", "secret-token-value")

    exit_code = discover.main(
        [
            "--base-url",
            "https://redhat.atlassian.net",
            "--output-dir",
            str(tmp_path),
        ]
    )
    assert exit_code == 1
