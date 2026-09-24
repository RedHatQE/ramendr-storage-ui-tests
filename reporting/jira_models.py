"""Typed models for a single Jira Test Result execution.

Phase B/C: these are plain data containers with no I/O of their own. See
``reporting/jira_client.py`` for the Jira Cloud REST calls,
``reporting/jira_results.py`` for building a Jira payload from a
:class:`TestResultExecution`, and ``reporting/jira_test_cases.py`` for the
approved scenario -> Jira Test Case key mapping.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from datetime import datetime, timezone
from enum import Enum


class TestOutcome(str, Enum):
    """The three possible outcomes of one Ramen DR UI test execution.

    Values match the Jira transition *names* discovered in Phase A
    (``PASS`` / ``FAIL`` / ``Blocked``'s canonical outcome), and the string
    values are used verbatim in the Jira summary/description.
    """

    #: Not a pytest test class despite the name -- silence collection warnings.
    __test__ = False

    PASS = "PASS"
    FAIL = "FAIL"
    BLOCKED = "BLOCKED"


@dataclass(frozen=True)
class TestResultExecution:
    """Everything needed to report one Ramen DR automation run as a Jira Test Result.

    ``test_case_key`` must be a real Jira Test Case key (e.g. ``RHELTEST-3600``)
    -- resolve it from an approved scenario id via
    ``reporting.jira_test_cases.resolve_test_case_key`` before constructing
    this; this class does not validate that the key is approved or that the
    parent actually exists/qualifies (see
    ``reporting.jira_results.validate_parent_test_case`` for that, which
    requires a live Jira read).

    ``scenario`` is a short human-readable label (e.g. the pytest scenario
    name) used in the Jira summary/description -- distinct from
    ``test_case_key``.
    """

    #: Not a pytest test class despite the name -- silence collection warnings.
    __test__ = False

    test_case_key: str
    scenario: str
    outcome: TestOutcome
    run_id: str
    executed_at: datetime = field(default_factory=lambda: datetime.now(timezone.utc))
    compose_version: str | None = None
    git_commit: str | None = None
    ci_job_url: str | None = None
    duration_seconds: float | None = None
    failure_summary: str | None = None

    def __post_init__(self) -> None:
        missing = [
            name
            for name, value in (
                ("test_case_key", self.test_case_key),
                ("scenario", self.scenario),
                ("run_id", self.run_id),
            )
            if not value
        ]
        if missing:
            raise ValueError(
                "TestResultExecution missing required field(s): " + ", ".join(missing)
            )
        if not isinstance(self.outcome, TestOutcome):
            raise ValueError(
                f"outcome must be a TestOutcome, got {type(self.outcome).__name__}"
            )
