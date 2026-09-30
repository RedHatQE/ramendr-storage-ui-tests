# Jira Test Result reporting

**Status: Phase A, B, C, and D are all implemented.** This describes the Jira
Cloud REST API v3 integration used for RamenDR Test Result reporting: Phase A's
read-only schema discovery tool for the production `RHELTEST` project, Phase
B/C's gated write support (`create_issue`/`transition_issue`) and its
pytest/sanity wiring, and Phase D's move from opt-in pilot reporting to
**normal-default reporting** for sanity and (once a scenario is approved)
smoke. See
[`Ramen_DR_Jira_Test_Result_Integration_Plan.md`](Ramen_DR_Jira_Test_Result_Integration_Plan.md)
for the full phased plan and rationale.

**Normal usage today:** just run `pytest ...` (with real Jira credentials
supplied by your environment/CI secret store). Reporting is on by default --
you do not need to export `JIRA_REPORT_RESULTS` or `JIRA_REPORT_DRY_RUN` for
an ordinary sanity or smoke run. See
["Phase D: reporting is now the default"](#phase-d-reporting-is-now-the-default)
below.

## What exists today

- `reporting/jira_client.py` — a minimal Jira Cloud REST API v3 client.
  It only implements **GET** operations (`get_current_user`, `get_project`,
  `get_create_issue_types`, `get_create_fields`, `get_fields`, `get_issue`,
  `get_transitions`, `get_issue_type`, `get_project_issue_types`,
  `get_my_permissions`). There is no `create_issue` or `transition_issue` yet —
  those are deliberately deferred to a later phase.
- `scripts/jira/discover_test_result_schema.py` — a CLI that uses the client
  above to discover:
  - the `RHELTEST` project id
  - the `Test Result` issue type id and its subtask/hierarchy behavior
  - required create fields, and the specific shapes of `Parent`,
    `Compose Version`, `Labels`, `Fix versions`, `Description`, `Test Steps`
  - (optionally) how one real sample `Test Result` stores those fields, and
    its available workflow transitions (to find the PASS/FAIL/BLOCKED
    transition ids)

This script performs **zero** Jira writes (no POST/PUT/DELETE).

- `scripts/jira/discover_ramen_dr_test_cases.py` -- a read-only CLI that
  queries `project = RHELTEST AND labels = "ramen-dr" AND type = "Test
  Case"` (via `JiraClient.search_issues`) and prints/saves each matching
  Test Case's key, summary, labels, status, and description (converted from
  Atlassian Document Format to plain text). Used once to enumerate the 13
  Ramen DR Test Cases in RHELTEST and inform the smoke-to-Jira mapping
  below -- it imports no write methods (`create_issue`/`transition_issue`)
  at all, and never prints credentials. Output is written to
  `.work/jira/ramen-dr-test-cases.json` (gitignored).

### Fixed bug: wrong pagination key for createmeta endpoints

`GET /issue/createmeta/{project}/issuetypes` and
`GET /issue/createmeta/{project}/issuetypes/{id}` are paginated, but unlike
most Jira Cloud endpoints they do **not** wrap their page contents in the
generic `values` key -- they use `issueTypes` and `fields` respectively (per
the [official docs](https://developer.atlassian.com/cloud/jira/platform/rest/v3/api-group-issues/)).
Our client originally assumed `values` for every paginated endpoint, which
silently returned an always-empty list (HTTP 200, no error -- never an
exception) for *both* endpoints. This was the actual root cause of an
apparent "Test Result is not creatable" finding against production
`RHELTEST`: the createmeta issue-type listing was empty for every type, not
just `Test Result`, and a direct per-id probe also returned zero fields --
both symptoms of this one client bug, not a real permission or
create-screen restriction. `reporting/jira_client.py`'s `_paginate` now
takes an explicit `results_key` per endpoint, and both bugs are covered by
regression tests in `tests/reporting/test_jira_client.py`.

### Diagnosing "Test Result is not available for creation"

`GET /issue/createmeta/{project}/issuetypes` only lists issue types the
*current user* can create via the generic create screen for that project.
Its absence there does **not** prove the issue type doesn't exist -- a
project can associate an issue type via its issue-type scheme (and real
issues of that type can exist) without a Create screen being mapped for it,
or a marketplace test-management app may deliberately hide its own issue
types from the generic create screen.

When `Test Result` is missing from create metadata, discovery does **not**
abort. Given `--sample-test-result RHELTEST-XXXX`, it keeps gathering
independent, read-only evidence:

- `GET /issue/{key}?expand=names,schema` — proves the type exists and is
  viewable, and yields its real issue-type id even when createmeta lacks it.
- `GET /issuetype/{id}` — global issue-type metadata (`hierarchyLevel`,
  `scope`), independent of any project's create-screen configuration.
- `GET /issuetype/project?projectId={id}` — whether the type is associated
  with the project's issue-type scheme at all (independent of create
  permission/screen filtering).
- A direct, read-only probe of `GET /issue/createmeta/{project}/issuetypes/{id}`
  using the id discovered from the sample, to check whether the type is
  actually createable via the API despite being absent from the *listing*.
  **Important:** Jira Cloud returns HTTP 200 with an empty field list (not a
  4xx) when a type isn't createable for the current user/project, so the
  probe's *field count* is what matters, not just "no exception was raised".
  A probe returning zero fields is treated the same as a failed probe.
- `GET /mypermissions?projectKey={key}&permissions=CREATE_ISSUES` — a direct,
  authoritative permission check for the current user, saved to
  `my-permissions.json`. Overrides the weaker heuristics below when it
  reports `havePermission: false`.
- Whether `GET /issue/createmeta/{project}/issuetypes` returned an **empty
  list for every issue type**, not just `Test Result` — this is documented
  Jira Cloud behavior when the user lacks Create-issue permission on the
  whole project, and is a much stronger signal than a single type being
  missing.
- `GET /issue/{key}/transitions` — still collected regardless of createmeta.

All of this is combined into `.work/jira/test-result-diagnosis.json` and a
"Test Result availability diagnosis" section in `discovery-summary.txt`,
with a best-effort `likely_cause` (`permission`, `hierarchy_or_parent_requirement`,
`create_screen_configuration`, `discovery_code_assumption`, `none`, or
`inconclusive`) plus the supporting `reasoning` for a human to confirm.
`discovery_code_assumption` is only used when the direct probe actually
returned real field metadata (count > 0); an empty-but-200 probe result
falls through to the permission/scheme-based checks instead.

## Running discovery

Credentials are never committed. Export them as environment variables:

```bash
export JIRA_BASE_URL="https://redhat.atlassian.net"
export JIRA_PROJECT_KEY="RHELTEST"
export JIRA_EMAIL="<red-hat-email>"
export JIRA_API_TOKEN="<token>"

python scripts/jira/discover_test_result_schema.py
```

To also inspect a known sample `Test Result` (stored field shapes + real
workflow transitions):

```bash
python scripts/jira/discover_test_result_schema.py \
  --sample-test-result RHELTEST-XXXX
```

Sanitized output is written under `.work/jira/` (already `.gitignore`d):

```text
.work/jira/
    project.json
    issue-types.json
    project-issue-types.json         # GET /issuetype/project -- project issue-type scheme
    test-result-issuetype.json       # GET /issuetype/{id} -- global metadata, once an id is resolved
    test-result-create-fields.json
    my-permissions.json              # GET /mypermissions -- CREATE_ISSUES for the current user
    jira-fields.json
    sample-test-result.json          # only when --sample-test-result is given
    test-result-transitions.json     # only when --sample-test-result is given
    test-result-diagnosis.json       # likely_cause + reasoning (see below)
    discovery-summary.txt
```

Review `discovery-summary.txt` and the JSON files above before any Jira
write code is implemented (Phase B onward).

## Security

- Credentials come only from `JIRA_EMAIL` / `JIRA_API_TOKEN` env vars —
  never pass them as CLI args, never commit them.
- The client and script never print or log the API token, email, or
  `Authorization` header — only `displayName` / `accountId` from `/myself`.
- `.gitignore` covers `.env`, `.env.*`, `jira-token.txt`, and `.work/`
  (which is where discovery output and `.work/values-secret.yaml` live).

## Tests

```bash
python -m pytest tests/reporting -v
```

All Jira interaction is mocked (a fake HTTP session / fake client); no test
contacts a real Jira instance.

## Phase B/C: reporting a Test Result

Phase B/C add the ability to create and transition a real Jira Test Result.
`tests/ui/sanity/test_sanity.py` is wired up to report automatically (see
["Phase 1 pytest/sanity wiring"](#phase-1-pytestsanity-wiring) below, and
["Phase D"](#phase-d-reporting-is-now-the-default) for today's normal-default
behavior); the CLI (`scripts/jira/create_test_result_smoke.py`) is a
separate, manual entrypoint for ad hoc reporting outside of pytest that
deliberately keeps its own maximally-safe defaults regardless of Phase D.

### New modules

- `reporting/jira_client.py` -- adds `create_issue(fields)` and
  `transition_issue(issue_key, transition_id)`. Both are **write**
  operations and are **never retried automatically** (unlike GETs): a
  network error/timeout during a POST raises `JiraAmbiguousWriteError`
  (outcome unknown -- do not blindly retry), while a clear HTTP error
  response raises `JiraWriteError` with a sanitized message (only Jira's
  structured `errorMessages`/`errors` fields, truncated -- never the raw
  body).
- `reporting/jira_models.py` -- `TestOutcome` enum (`PASS`/`FAIL`/`BLOCKED`)
  and the `TestResultExecution` dataclass describing one automation run.
- `reporting/jira_test_cases.py` -- `RAMENDR_JIRA_TEST_CASES`, the
  **approved-only** scenario-id -> Jira Test Case key mapping. Of the 13
  Ramen DR Test Cases confirmed to exist in RHELTEST (via
  `scripts/jira/discover_ramen_dr_test_cases.py`), 3 are mapped:
  `failover_primary_to_secondary` (`RHELTEST-3600`),
  `relocate_secondary_to_primary` (`RHELTEST-3610`), and
  `deployment_smoke_validation` (`RHELTEST-3612`, smoke's aggregate scenario
  -- see ["Smoke wiring"](#smoke-wiring)); the other 10 are deliberately not
  mapped yet.
- `reporting/jira_config.py` -- `reporting_config_from_env()` reads all the
  env vars below into a `JiraReportingConfig` (non-credential, safe to
  log/print).
- `reporting/jira_results.py` -- `build_test_result_fields()` (the create
  payload), `build_description_adf()` (Atlassian Document Format
  description), `validate_parent_test_case()` (project/issue-type/label
  checks on a fetched parent), and `report_test_result()` (the orchestrator
  described below).
- `scripts/jira/create_test_result_smoke.py` -- the only entrypoint that
  can perform a real write.

### Safety gates

`report_test_result()` has three gates, checked in order, each stopping
strictly before any write: `config.report_results` (off = zero Jira calls,
not even a GET), `config.dry_run` (on = a read-only parent-validation GET
only, no write), then the real create/transition/re-verify write path.

**As of Phase D, `report_results` and `dry_run` default to normal-reporting
values for pytest** (`report_results=True`, `dry_run=False`) -- see
["Phase D: reporting is now the default"](#phase-d-reporting-is-now-the-default).
The CLI below deliberately keeps its own historical maximally-safe defaults
regardless of that change, since it's a manual/ad hoc tool, not "normal
automation":

- **`scripts/jira/create_test_result_smoke.py` (CLI)** still defaults to
  `report_results=False`, `dry_run=True` whenever the corresponding env var
  is not explicitly set, plus its own *third* gate: `--confirm` must also be
  passed. All three (`JIRA_REPORT_RESULTS=true`, `JIRA_REPORT_DRY_RUN=false`,
  `--confirm`) must be explicitly set/passed together before this CLI
  performs a write.
- **`tests/ui/sanity/test_sanity.py` and marker-decorated smoke tests
  (pytest)** report for real by default -- no environment variables need to
  be set. Setting `JIRA_REPORT_RESULTS=false` opts a local/dev run out of
  reporting entirely; setting `JIRA_REPORT_DRY_RUN=true` (with reporting
  still enabled) does a real credentialed read-only preview without writing.
  See ["Phase D: reporting is now the default"](#phase-d-reporting-is-now-the-default)
  and ["Phase 1 pytest/sanity wiring"](#phase-1-pytestsanity-wiring) below.

`report_test_result()` never assumes a newly created issue's initial
status: after `create_issue`, it re-fetches the issue's current status and
its *actually available* transitions, and refuses to attempt a transition
id that isn't currently offered rather than blindly calling it. After
transitioning, it re-fetches the issue **once more** to record the *final*
status and to verify -- from a fresh read, not from the payload that was
sent -- that the parent, labels, and Compose Version were actually stored
as intended (`ReportResult.final_status` / `.post_creation_verification`).

### Compose Version is optional and never fabricated

`--compose` (and `RAMENDR_COMPOSE_VERSION`) are optional. When no real
value is supplied (`None` or empty):

- `customfield_11500` is omitted entirely from the create payload -- never
  sent as an empty string or a placeholder.
- The summary uses the literal token `not-supplied` in place of a compose
  value (never the stale sample `RHEL-9.8.0`, never a `TEST-COMPOSE-*`-style
  placeholder).
- The ADF description renders `Compose Version: not supplied`.

This is fully unit-tested in `tests/reporting/test_jira_results.py` and
`tests/reporting/test_create_test_result_smoke.py`.

### Best-effort dashboard/saved-filter visibility check

After a **real** write, the CLI also runs a read-only JQL search
(`JiraClient.search_issues`, `GET /rest/api/3/search/jql?jql=key = "<new-key>"`)
to confirm the new issue is indexed/searchable. This is intentionally
best-effort and non-fatal (a failure here never fails the run -- the write
already succeeded by that point): we don't have the actual Ramen DR saved
filter's JQL, so this only proves generic search-index visibility, not that
specific dashboard/filter. Confirming the real saved filter requires either
its JQL or a manual check in the Jira UI.

`search_issues` uses Jira Cloud's current "enhanced JQL search" endpoint
(`/rest/api/3/search/jql`) -- the legacy `GET /rest/api/3/search` endpoint
was removed by Atlassian (production returned HTTP 410 Gone) and its
response shape differs: no `total`/`startAt`, cursor-based pagination via
`nextPageToken`/`isLast` instead. `search_issues` only fetches a single page
(every current caller checks for a handful of issues by key); a caller
needing more than one page would require looping on `nextPageToken` until
`isLast` -- not implemented since nothing needs it yet.

### Environment variables

```bash
# Defaults below are for reporting_config_from_env() (used by pytest --
# tests/ui/sanity/test_sanity.py and marker-decorated smoke tests). The
# scripts/jira/create_test_result_smoke.py CLI overrides the first two back
# to false/true whenever they are not explicitly set -- see "Safety gates".
JIRA_REPORT_RESULTS=true    # default: real reporting is on
JIRA_REPORT_DRY_RUN=false   # default: writes actually happen
JIRA_REPORT_STRICT=false    # reserved for future use

JIRA_BASE_URL=
JIRA_PROJECT_KEY=RHELTEST
JIRA_EMAIL=
JIRA_API_TOKEN=

JIRA_TEST_RESULT_ISSUE_TYPE_ID=10272
JIRA_COMPOSE_VERSION_FIELD_ID=customfield_11500

JIRA_PASS_TRANSITION_ID=3
JIRA_FAIL_TRANSITION_ID=4
JIRA_BLOCKED_TRANSITION_ID=5

RAMENDR_COMPOSE_VERSION=
JIRA_RUN_ID=
CI_JOB_URL=
GIT_COMMIT=
```

### Smoke-test CLI

This CLI is a manual/ad hoc debugging tool, independent of the normal-default
pytest behavior described in
["Phase D: reporting is now the default"](#phase-d-reporting-is-now-the-default) --
it always requires explicit opt-in, regardless of what's set in your shell.

```bash
# Safe preview -- no credentials required, no Jira contacted at all:
python scripts/jira/create_test_result_smoke.py \
  --test-case failover_primary_to_secondary \
  --scenario "Failover primary to secondary" \
  --outcome PASS --compose RHEL-9.8.0

# Real write -- only after explicit review/approval:
JIRA_REPORT_RESULTS=true JIRA_REPORT_DRY_RUN=false \
python scripts/jira/create_test_result_smoke.py \
  --test-case failover_primary_to_secondary \
  --scenario "Failover primary to secondary" \
  --outcome PASS --confirm
```

### Not implemented yet

Adding the remaining 10 Test Case mappings (RHELTEST-3601..3611, except the
mapped RHELTEST-3610) is future work pending real automation and review for
each -- discovery confirmed these correspond to scenarios not currently
automated in this repo (e.g. repeated failover/failback cycles, snapshots,
hotplug disks, VMware-imported/migrated Windows, static networks, dual-NIC
Windows, primary->secondary relocate as a *standalone* scenario, failed
failover cleanup/retry). Only `failover_primary_to_secondary`
(RHELTEST-3600), `relocate_secondary_to_primary` (RHELTEST-3610), and
`deployment_smoke_validation` (RHELTEST-3612) are wired up (see below).
`BLOCKED` outcomes are not produced automatically yet -- pytest skips are
never translated into a Jira `BLOCKED` result.

## Phase 1 pytest/sanity wiring

`tests/ui/sanity/test_sanity.py::test_sanity_disaster_recovery_ui` reports
independent Jira Test Results for the two scenarios above via
`reporting.jira_results.jira_test_case_result()` -- a per-scenario reporting
boundary. As of Phase D, reporting is **on by default** (see below) -- an
ordinary sanity run reports for real; set `JIRA_REPORT_RESULTS=false`
explicitly to opt a local/dev run out and make zero Jira calls.

### `jira_test_case_result()` / `JiraScenarioReporter`

```python
with jira_test_case_result(
    "failover_primary_to_secondary",
    scenario="Failover primary to secondary",
    run_id=run_id, client=jira_client, config=jira_config,
):
    ...  # the whole scenario
```

- Entering records the start time (used for the Jira `duration_seconds`).
- The block completing normally reports **PASS**.
- The block raising reports **FAIL** (using the exception's type/message as
  the failure summary) and *always* re-raises the original exception
  unmodified -- Jira reporting never swallows or replaces a real test
  failure.
- If Jira reporting **itself** fails while closing a FAIL, that's only ever
  logged (`reporting.jira_results` logger, level `WARNING`) -- never allowed
  to mask the original scenario exception, regardless of `JIRA_REPORT_STRICT`.
- If Jira reporting fails while closing a **PASS** (no competing failure to
  protect), `JIRA_REPORT_STRICT` decides: logged-only by default, or raised
  (failing the test) when `JIRA_REPORT_STRICT=true`.
- Each reporter reports **at most once**: a second `close_success()` /
  `close_failure()` call is a no-op, so an outer safety-net handler can never
  double-report a boundary that already closed successfully.

When a scenario's start and end aren't one contiguous block of code (the
adaptive/resume flow below), `.start()` / `.close_success()` /
`.close_failure(exc)` are called directly instead of using `with`.

### Where the two boundaries live in `test_sanity.py`

Both flows below use the same pattern: construct the reporter and call
`.start()` immediately, but only call `.close_failure(exc)` if the actual DR
action (`initiate_failover_dialog()` / `initiate_relocate_dialog()`) already
succeeded (tracked by a `failover_initiated` / `relocate_initiated` flag). A
precondition failure -- dialog-contents assertion, baseline-snapshot capture,
anything **before** the real action is initiated -- re-raises without
reporting anything, so it can never fabricate a scenario result. This is the
same rule the marker-based smoke wiring below enforces via pytest's own
setup/call phase split.

- **`_run_force_full_sanity_dr_flow`** (used whenever
  `RAMENDR_SANITY_FORCE_FULL=1`, the default): both scenarios always run,
  each with its own `failover_initiated` / `relocate_initiated` flag as
  described above -- failover from the "initiate" dialog validation through
  `_run_dr_data_validation(phase="failover", ...)`, then relocate from the
  pre-relocate healthy/protected-state check through
  `_run_dr_data_validation(phase="relocate", ...)`.
- **`test_sanity_disaster_recovery_ui`'s adaptive/resume branch** (used when
  `RAMENDR_SANITY_FORCE_FULL=0`): the two boundaries aren't lexically
  contiguous (dialog validation happens in one `if` branch, completion
  validation happens later, shared with other resume branches), so
  `failover_reporter` / `relocate_reporter` are created with `.start()` and
  closed explicitly with `.close_success()` right after each scenario's own
  validation finishes -- **before** the other scenario even starts, so one
  scenario's outcome can never retroactively change an already-closed one.
  A single `try/except BaseException` around the whole adaptive flow is the
  safety net: on any exception, whichever reporter is still open (not yet
  closed) and was actually initiated reports FAIL via `.close_failure(exc)`,
  then the exception is always re-raised unmodified.

### Resume behavior (adaptive flow only)

A Jira Test Result is only ever created for a scenario **this invocation**
actually initiates and completes -- resuming into an already-completed phase
never fabricates a result for the phase it's resuming *past*:

| Starting state | `failover_reporter` created? | `relocate_reporter` created? |
| --- | --- | --- |
| Fresh (`ready_for_failover`) | Yes -- failover genuinely runs | Yes -- relocate genuinely runs right after |
| Resume after failover (`post_failover`) | **No** -- failover already happened in a prior invocation | Yes -- relocate genuinely runs this invocation |
| Resume after relocate (`post_relocate`) | **No** | **No** -- nothing new executes this invocation |
| Failure during failover | Yes, closed with **FAIL** | **No** -- never reached |
| Failure during relocate (after failover PASS) | Yes, already closed with **PASS** (unaffected) | Yes, closed with **FAIL** |

### Run id and Compose Version

`reporting.jira_results.derive_run_id(config)` returns `$JIRA_RUN_ID` if set,
otherwise a fresh `sanity-<random>-<epoch>` id every time it's called --
deliberately uncached, since some callers legitimately want a new id per
call. `reporting.jira_results.get_session_run_id(config)` wraps it with a
process-wide cache: it still returns `$JIRA_RUN_ID` immediately when set,
but otherwise calls `derive_run_id()` **at most once per pytest process** and
memoizes the fallback, so every reporting call in one pytest execution --
sanity's failover and relocate boundaries, and every marker-decorated smoke
test -- shares exactly one run id without `$JIRA_RUN_ID` needing to be set
manually. `reset_session_run_id_cache()` clears the cache (used by test
isolation, and safe to ignore otherwise). Compose Version follows the
existing rule: send `customfield_11500` only when `RAMENDR_COMPOSE_VERSION`
is set; never fabricate `RHEL-9.8.0`/`unknown`/test placeholders.

### Tests

- `tests/reporting/test_jira_scenario_reporter.py` -- `JiraScenarioReporter`
  / `jira_test_case_result()` in isolation (context-manager and manual
  usage, PASS/FAIL, strict mode, double-close, disabled/dry-run, shared run
  id). All Jira calls mocked.
- `tests/ui/sanity/test_sanity_jira_wiring.py` -- calls the real
  `test_sanity_disaster_recovery_ui` method with every DR/Playwright/`oc`
  dependency monkeypatched to a no-op or scripted fake, and a fake Jira
  client, for **both** the adaptive/resume flow and (Phase D) the
  force-full flow. Covers fresh run, resume after failover, resume after
  relocate, independent failure attribution (failover PASS + relocate FAIL,
  and vice versa), a precondition failure before either scenario is
  actually initiated reporting nothing, reporting-disabled, dry-run,
  `JIRA_REPORT_STRICT`, and one shared run id across both boundaries.

## Phase D: reporting is now the default

Normal Ramen DR automation -- sanity and (once a scenario is approved)
smoke -- must always publish PASS or FAIL to Jira without the person running
`pytest` having to opt in manually. Phase D changes two defaults and adds a
fail-fast credential check; nothing about the write path itself
(three-gate `report_test_result()`, parent validation, re-verify-after-write)
changed.

### What changed

- `reporting_config_from_env()`'s defaults flipped: `report_results` is now
  `True` (was `False`) and `dry_run` is now `False` (was `True`). See
  ["Environment variables"](#environment-variables) above for the override
  variables, which still work exactly as before -- only the *default* when
  they're unset changed.
- `scripts/jira/create_test_result_smoke.py` explicitly restores its own
  historical safe defaults (`report_results=False`, `dry_run=True`)
  whenever the corresponding env var is unset, so this manual CLI's
  behavior is unaffected by the pytest-facing default change above.
- `reporting.jira_results.build_jira_client(config)` is the new single
  place that turns a `JiraReportingConfig` into a `JiraClient | None`:
  returns `None` immediately when `report_results` is `False` (no
  credentials needed at all); otherwise calls
  `reporting.jira_client.config_from_env()` and, if that raises because
  `JIRA_BASE_URL`/`JIRA_EMAIL`/`JIRA_API_TOKEN` aren't all set, re-raises as
  `JiraCredentialsUnavailableError` with a message that names which
  variables are missing and how to fix it (set them, or explicitly opt out
  with `JIRA_REPORT_RESULTS=false`) -- **never** silently skips reporting
  and never prints the token value itself. Both `test_sanity.py` and the
  smoke plugin below call this instead of constructing `JiraClient`
  directly.

### Fail-fast behavior

| Situation | Behavior |
| --- | --- |
| `JIRA_REPORT_RESULTS=false` (explicit opt-out) | No credentials required; zero Jira calls. |
| `JIRA_REPORT_RESULTS` unset (default `true`) + credentials present | Reports for real (writes, unless `JIRA_REPORT_DRY_RUN=true`). |
| `JIRA_REPORT_RESULTS` unset (default `true`) + credentials **missing** | `JiraCredentialsUnavailableError` raised immediately -- for sanity, when Jira setup runs at the start of the test; for smoke, at collection time (`pytest_collection_modifyitems`), before any test body runs, so the failure is obvious and not buried in one test's report. |

## Smoke wiring

`tests/ui/smoke/test_smoke.py` reports one aggregated Jira Test Result --
`deployment_smoke_validation` / **RHELTEST-3612** -- per invocation, covering
every applicable-for-the-active-`PATTERN_VARIANT` smoke check. Confirmed via
a real, read-only discovery pass
(`scripts/jira/discover_ramen_dr_test_cases.py`) against production
RHELTEST; RHELTEST-3612's summary is *"[Ramen Pattern] Deploy Ramen Pattern
on an Openshift Cluster and verify managed clusters status and protected
vms"*.

### Two marker shapes: one Test Result per test, or one shared by a group

`reporting/pytest_jira_plugin.py` (the only module under `reporting/` that
imports `pytest` -- kept isolated so the rest of `reporting/` stays usable
by the standalone CLI) provides two markers:

**`@pytest.mark.jira_test_case(scenario_id, *, scenario)`** -- one Jira Test
Result per marked test, reported immediately when that test's `"call"`
phase finishes (used by sanity's two independent DR scenarios -- see
["Phase 1 pytest/sanity wiring"](#phase-1-pytestsanity-wiring)):

```python
@pytest.mark.jira_test_case(
    "some_approved_scenario_id", scenario="Human-readable scenario label"
)
def test_something(...):
    ...  # no Jira code in the test body at all
```

**`@pytest.mark.jira_aggregate_test_case(scenario_id, *, scenario)`** -- one
Jira Test Result *shared* by every test carrying the same `scenario_id`,
reported exactly once at `pytest_sessionfinish` (used by smoke -- reporting
one Test Result per constituent smoke check would be noisy and wouldn't
answer "did deployment validation pass" without reading every row):

```python
@_jira_deployment_smoke  # = jira_aggregate_test_case("deployment_smoke_validation", ...)
def test_argocd_apps_synced_healthy(self, hub_kubeconfig):
    ...
```

A test must carry at most one of the two markers -- carrying both raises
`TypeError` at report time (their reporting shapes are mutually exclusive).

Both markers share the same hook infrastructure:

- `pytest_configure` registers both markers (so `--strict-markers` accepts
  them).
- `pytest_collection_modifyitems` builds (or fails fast on) the Jira client
  **once per session**, if at least one collected item carries either
  marker -- this is the "fail fast at collection time" behavior in the
  table above.
- `pytest_runtest_makereport` (a hookwrapper) only ever looks at the
  `"call"`-phase result, so a `"setup"`/`"teardown"`-phase failure (e.g. a
  fixture failure) or a skip is **never** turned into a fabricated result
  for either marker -- matching the sanity rule above.
- The run id is shared across sanity and smoke in the same pytest
  invocation via `get_session_run_id()` (see
  ["Run id and Compose Version"](#run-id-and-compose-version) above) --
  used by both markers.
- A Jira reporting failure is only ever logged
  (`reporting.pytest_jira_plugin` logger, `WARNING`) for either marker -- it
  never changes the pytest outcome that was already computed.

### Aggregate accounting (`jira_aggregate_test_case`)

For each `scenario_id`, `pytest_runtest_makereport` accumulates (never
reports directly) as each constituent test's `"call"` phase completes, and
conditionally as its `"teardown"` phase completes (see below):

- **Skipped tests are never counted** -- neither as a pass nor a failure.
  This is what makes the aggregate correctly variant-aware for free: a
  smoke check gated by an existing `@_skip_without_*` marker (e.g.
  `test_odf_storagecluster_ready` needs ODF) simply isn't counted when that
  marker skips it, with no extra logic in the plugin itself.
- If **every** test carrying a `scenario_id` is skipped this invocation
  (e.g. a hypothetical future variant where none of RHELTEST-3612's checks
  apply), **nothing is reported at all** -- same "never fabricate a result"
  rule as `jira_test_case` and as sanity's DR boundaries.
- A fixture/setup-phase failure for a constituent test is likewise never
  counted (consistent with the rule above) -- an environment/
  pre-deployment/provisioning problem that means the test body never
  started is not a *test* outcome, so it must never create a Jira Test
  Result. **Known trade-off:** if a shared fixture failure (e.g.
  `hub_kubeconfig`) causes *every* RHELTEST-3612 test to error out in
  setup, the result is silence (nothing reported), not a FAIL -- the same
  "no fabricated result for something that never really ran" principle
  applied at the group level. A future iteration could choose to treat an
  all-setup-errors group as a FAIL instead; not done here since it wasn't
  requested and would need its own review.
- A **teardown**-phase failure is only counted when that same node id's own
  `"call"` phase already passed -- i.e. the smoke check's body actually
  executed and succeeded, and cleanup belonging to *that executed check*
  then failed. This flips that one test from contributing to PASS to
  contributing to FAIL (message prefixed `(teardown)`); it does not affect
  any other constituent test. Every other teardown outcome is ignored:
  after a skip, after a setup failure (no executed check for it to reflect
  a failure of -- keeps environment/setup failures out of the dashboard,
  per the rule above), or after a `"call"`-phase failure (already counted;
  a second entry for the same node id would be redundant, not a new
  outcome).

At `pytest_sessionfinish` (after every test in the session has run), each
scenario with at least one counted test reports **exactly once**:

- **PASS** if every counted test passed.
- **FAIL** if one or more counted tests failed -- the Jira description's
  failure line lists every failing pytest node id and a concise message
  (e.g. `tests/ui/smoke/test_smoke.py::TestInfraSmoke::test_vault_running:
  AssertionError: ...`), semicolon-joined and truncated by the same
  `_sanitize_failure_summary` every other Jira description uses -- never
  one FAIL Test Result per failing test.
- `duration_seconds` is the sum of every counted test's own duration (a
  proxy for total smoke-suite execution time, not wall-clock session time).

### Smoke-to-Jira mapping (confirmed via discovery)

`reporting/jira_test_cases.py`'s `RAMENDR_JIRA_TEST_CASES` now includes:

```python
RAMENDR_JIRA_TEST_CASES = {
    "failover_primary_to_secondary": "RHELTEST-3600",
    "relocate_secondary_to_primary": "RHELTEST-3610",
    "deployment_smoke_validation": "RHELTEST-3612",
}
```

16 of the 20 `tests/ui/smoke/test_smoke.py` functions are decorated with
`@_jira_deployment_smoke` (the module-level `jira_aggregate_test_case`
marker for `deployment_smoke_validation`):

| Test | Included? |
| --- | --- |
| `test_argocd_apps_synced_healthy` | ✅ |
| `test_managed_clusters_available` | ✅ |
| `test_odf_storagecluster_ready` | ✅ |
| `test_vms_running_on_primary` | ✅ |
| `test_mixed_vm_fleet_composition` | ✅ |
| `test_windows_vms_have_minimum_os_disk` | ✅ |
| `test_vms_have_two_data_disks` | ✅ |
| `test_vm_disks_dr_protected_in_vrg` | ✅ |
| `test_vm_external_secrets_present` | ✅ |
| `test_hammerdb_schema_present_on_all_vms` | ✅ |
| `test_drpolicy_validated` | ✅ |
| `test_mirrorpeer_setup_complete` | ✅ |
| `test_drpc_deployed_available` | ✅ |
| `test_vault_running` | ✅ |
| `test_external_secrets_synced` | ✅ |
| `test_disaster_recovery_ui` (`TestUiSmoke`) | ✅ |
| `test_drpartner_s4_storage_namespace` | ❌ not included |
| `test_drpartner_s4_drpolicy` | ❌ not included |
| `test_drpartner_minimal_has_no_s4_storage` | ❌ not included |
| `test_drpartner_minimal_has_no_drpolicy` | ❌ not included |

The four `test_drpartner_*` checks validate variant-*identity* (does
`drpartner-s4`/`drpartner-minimal` deploy the right/wrong resources for
*that specific variant*), which is a different kind of assertion than
RHELTEST-3612's generic "managed clusters status and protected vms" --
they're deliberately excluded pending their own review, not merged into
this mapping.

**RHELTEST-3601 through RHELTEST-3611 (except the mapped RHELTEST-3610) are
not represented by the smoke suite and are not mapped.** Confirmed via
discovery to correspond to scenarios with no current automation in this
repo: repeated failover/failback cycles, snapshots, hotplug disks,
VMware-imported Windows, migrated Windows, static networks, dual-NIC
Windows, primary->secondary relocate (as a standalone scenario), and failed
failover cleanup/retry. `resolve_test_case_key()` deliberately raises
`KeyError` rather than guessing, so none of these are mapped until real
automation exists for them and each mapping is reviewed and approved.

### Tests

- `tests/reporting/test_pytest_jira_plugin.py` -- both markers in isolation:
  marker registration, unmarked/skipped/setup-phase tests report/count
  nothing, a passing or failing `jira_test_case`-marked test reports
  PASS/FAIL immediately, an unapproved scenario id raises, a Jira reporting
  failure is logged and never raised, collection-time fail-fast on missing
  credentials, one run id shared across tests using either marker in one
  session, and for `jira_aggregate_test_case`: skipped/setup-failed tests
  are never counted, an all-skipped group reports nothing, all-passing
  reports exactly one PASS, one or more failures report exactly one FAIL
  naming every failing node id (never one FAIL per failing test), carrying
  both markers on one test raises `TypeError`, and a missing-credentials
  error at session end is logged, not raised. Also covers teardown-phase
  handling specifically: a teardown failure after a passing call flips that
  test to FAIL (with a `(teardown)`-prefixed message); a passing teardown
  after a passing call stays PASS; a teardown failure after a skip, after a
  setup failure, or after a call failure is ignored (no duplicate/
  fabricated entry, and no effect on other constituent tests); and the
  individual `jira_test_case` marker has no teardown handling at all (a
  teardown report for it is a no-op). All Jira calls mocked; no real pytest
  session/subprocess is spawned -- both the hookwrapper and
  `pytest_sessionfinish` are driven directly.
- `tests/reporting/test_jira_test_cases.py` -- asserts the exact approved
  mapping set (guards against silently adding one of the un-reviewed Test
  Cases).
