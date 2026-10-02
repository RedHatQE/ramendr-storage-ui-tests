# Jira Test Result reporting

Automated reporting of PASS/FAIL outcomes for a small, fixed set of Ramen DR
scenarios to Jira (`RHELTEST` project, `Test Result` issue type), from the
sanity and smoke UI test suites.

The design is deliberately minimal for the current scale (three known
scenarios, two outcomes): a thin write-only Jira client, a static
scenario -> Jira Test Case key map, and one shared "report this scenario
outcome" function used from both sanity and smoke. There is no schema
discovery, no generic marker framework, no parent re-validation, and no
post-write verification -- the project id, issue type id, and transition
ids are already known and hardcoded in `jira_config.py`.

## Reporting is opt-in

**An ordinary `pytest` run makes zero Jira calls and needs zero
credentials.** `JIRA_REPORT_RESULTS` defaults to `false`. Set it (plus real
credentials) explicitly to report for real, e.g. in CI:

```bash
export JIRA_REPORT_RESULTS=true
export JIRA_BASE_URL="https://redhat.atlassian.net"
export JIRA_EMAIL="<red-hat-email>"
export JIRA_API_TOKEN="<token>"
```

`JIRA_REPORT_DRY_RUN` defaults to `true` whenever reporting is enabled, so
turning reporting on still makes zero Jira calls until you also set
`JIRA_REPORT_DRY_RUN=false`. Credentials are only required for that last,
real-write combination (`report_results=true` **and** `dry_run=false`).

| `JIRA_REPORT_RESULTS` | `JIRA_REPORT_DRY_RUN` | Behavior |
| --- | --- | --- |
| `false` (default) | n/a | Zero Jira calls; no credentials needed. |
| `true` | `true` (default) | Zero Jira calls (dry run); no credentials needed. |
| `true` | `false` | Real `create_issue` + `transition_issue`; credentials required, fails fast if missing. |

## What exists

- **`reporting/jira_client.py`** -- a thin Jira Cloud REST API v3 client
  with exactly two write operations: `create_issue(fields)` and
  `transition_issue(issue_key, transition_id)`. No discovery/GET/search
  machinery. Write errors are never retried automatically: a clear HTTP
  error raises `JiraWriteError` with a sanitized message (only Jira's
  structured `errorMessages`/`errors`, truncated, never the raw body or
  credentials); a network error/timeout during a POST raises
  `JiraAmbiguousWriteError` (outcome unknown -- do not blindly retry).
- **`reporting/jira_config.py`** -- `reporting_config_from_env()` reads the
  env vars below (including the known project/issue-type/transition ids)
  into a `JiraReportingConfig` (non-credential, safe to log/print).
- **`reporting/jira_models.py`** -- `TestOutcome` (`PASS`/`FAIL`/`BLOCKED`)
  and `TestResultExecution`, the small dataclass describing one scenario
  execution to report.
- **`reporting/jira_test_cases.py`** -- `RAMENDR_JIRA_TEST_CASES`, the
  static, approved-only scenario-id -> Jira Test Case key map:

  ```python
  RAMENDR_JIRA_TEST_CASES = {
      "failover_primary_to_secondary": "RHELTEST-3600",
      "relocate_secondary_to_primary": "RHELTEST-3610",
      "deployment_smoke_validation": "RHELTEST-3612",
  }
  ```

  `resolve_test_case_key()` raises `KeyError` (never guesses) for any
  scenario id not in this map. Adding a new mapping is a one-line,
  reviewed change here.
- **`reporting/jira_results.py`** -- the core reporting logic:
  - `build_jira_client(config)` -- returns `None` immediately unless a real
    write is about to happen (`report_results=True and dry_run=False`); only
    then does it build a client (and require credentials).
  - `build_test_result_fields()` / `build_description_adf()` -- the create
    payload and a short, fact-only description (scenario, test function,
    run id, executed-at, duration, outcome, failure summary).
  - `report_test_result(execution, client, config)` -- the three safety
    gates (`report_results`, `dry_run`, then a real `create_issue` ->
    `transition_issue`) for one execution.
  - **`report_scenario_outcome(...)`** -- the single shared entry point
    used by both sanity and smoke: resolves the Test Case key, builds the
    `TestResultExecution`, calls `report_test_result()`, and logs the
    outcome. A reporting failure (bad scenario id, Jira error) is logged
    and swallowed by default; pass `raise_on_error=True` to propagate it
    instead (used for PASS results under `JIRA_REPORT_STRICT`).
  - `JiraScenarioReporter` / `jira_test_case_result()` -- a small
    context-manager/manual-start-close wrapper around
    `report_scenario_outcome()` for a single scenario boundary (used by
    sanity).
  - `get_session_run_id(config)` -- `$JIRA_RUN_ID` if set, otherwise one
    fresh id memoized for the life of the pytest process
    (`functools.lru_cache`), so sanity and smoke share one run id per
    invocation.
- **`reporting/pytest_jira_plugin.py`** -- the `jira_aggregate_test_case`
  pytest marker: one Jira Test Result shared by every test carrying the
  same `scenario_id`, reported once at `pytest_sessionfinish` via
  `report_scenario_outcome()` (used by smoke -- see below).

## Sanity wiring

`tests/ui/sanity/test_sanity.py::test_sanity_disaster_recovery_ui` reports
two independent scenarios -- `failover_primary_to_secondary`
(RHELTEST-3600) and `relocate_secondary_to_primary` (RHELTEST-3610) -- via
`jira_test_case_result()`:

```python
with jira_test_case_result(
    "failover_primary_to_secondary",
    scenario="Failover primary to secondary",
    run_id=run_id, client=jira_client, config=jira_config,
):
    ...  # the whole scenario
```

- The block completing normally reports **PASS**; raising reports **FAIL**
  (using the exception as the failure summary) and always re-raises the
  original exception unmodified.
- **A Jira result is only ever created once the real DR action has been
  initiated.** Both the adaptive/resume flow and the force-full flow
  (`RAMENDR_SANITY_FORCE_FULL=1`, the default) track a
  `failover_initiated` / `relocate_initiated` flag and only call
  `.close_failure(exc)` when that flag is set; a precondition failure
  (dialog-contents assertion, baseline-snapshot capture) before the action
  starts re-raises without reporting anything. This is the one rule both
  flows share, so pre-initiation failures can never fabricate a FAIL.
- Each reporter reports at most once (a second close is a no-op), so an
  outer safety-net handler can never double-report a boundary that already
  closed.

Resuming into an already-completed phase never fabricates a result for the
phase it's resuming past -- see
`tests/ui/sanity/test_sanity_jira_wiring.py` for the full fresh/resume/
failure matrix.

## Smoke wiring

`tests/ui/smoke/test_smoke.py` reports one aggregated Jira Test Result --
`deployment_smoke_validation` / **RHELTEST-3612** -- per invocation, via the
`@pytest.mark.jira_aggregate_test_case("deployment_smoke_validation", ...)`
marker on each applicable test:

```python
@_jira_deployment_smoke
def test_argocd_apps_synced_healthy(self, hub_kubeconfig):
    ...  # no Jira code in the test body at all
```

- Skipped tests and setup-phase (fixture) failures are never counted --
  same "never fabricate a result for something that didn't really run"
  rule as sanity. If every constituent test is skipped, nothing is
  reported.
- A teardown-phase failure is only counted when that same node id's own
  `"call"` phase already passed (cleanup for a check that actually ran and
  passed); it flips that one test's contribution to FAIL. Every other
  teardown outcome is ignored.
- At `pytest_sessionfinish`, the scenario reports exactly once: PASS if
  every counted test passed, FAIL (naming every failing node id) otherwise
  -- never one result per failing test.
- `pytest_collection_modifyitems` builds (or fails fast on) the Jira client
  once per session if any collected item carries the marker, so missing
  credentials are reported before any test runs, not buried in one test's
  result.

## Environment variables

```bash
JIRA_REPORT_RESULTS=false   # default: opt-in; set true to report at all
JIRA_REPORT_DRY_RUN=true    # default when reporting is enabled: no writes
JIRA_REPORT_STRICT=false    # raise (fail the test) if a PASS result fails to report

JIRA_BASE_URL=
JIRA_PROJECT_KEY=RHELTEST
JIRA_EMAIL=
JIRA_API_TOKEN=

JIRA_TEST_RESULT_ISSUE_TYPE_ID=10272
JIRA_COMPOSE_VERSION_FIELD_ID=customfield_11500

JIRA_PASS_TRANSITION_ID=3
JIRA_FAIL_TRANSITION_ID=4
JIRA_BLOCKED_TRANSITION_ID=5

RAMENDR_COMPOSE_VERSION=    # optional; omitted from the payload if unset
JIRA_RUN_ID=                # optional; otherwise one id is generated per pytest process
```

Compose Version is never fabricated: `customfield_11500` is only sent when
`RAMENDR_COMPOSE_VERSION` is set.

## Security

- Credentials come only from `JIRA_EMAIL` / `JIRA_API_TOKEN` env vars --
  never pass them as CLI args, never commit them.
- The client never logs or raises the token, email, or `Authorization`
  header -- including inside sanitized error messages.

## Tests

```bash
python -m pytest tests/reporting tests/ui/sanity/test_sanity_jira_wiring.py -v
```

All Jira interaction is mocked (a fake client); no test contacts a real
Jira instance. Coverage is focused on the contract that actually matters at
this scale:

- `reporting/jira_test_cases.py`'s exact approved mapping (3 scenarios).
- `jira_client.py`'s create/transition happy path and error handling
  (401/403/400, credential-leak prevention, truncation, no retry).
- `report_test_result()`'s safety gates and `report_scenario_outcome()`'s
  shared policy (resolve key, build execution, log, swallow-or-raise).
- `JiraScenarioReporter` (sanity): PASS/FAIL, strict mode, double-close,
  disabled/dry-run, independent two-scenario reporting.
- `pytest_jira_plugin` (smoke aggregate): skip/setup/teardown accounting,
  one-PASS/one-FAIL-naming-every-failure, missing-credentials fail-fast.
- `tests/ui/sanity/test_sanity_jira_wiring.py`: the real
  `test_sanity_disaster_recovery_ui` method with every DR/Playwright/`oc`
  dependency faked, covering fresh run, resume after failover, resume
  after relocate, independent failure attribution, and -- the one rule
  both flows share -- no Jira result for a failure before the DR action is
  actually initiated.
