# Jira Test Result reporting

**Status: Phase A, B, and C are all implemented.** This describes the Jira
Cloud REST API v3 integration used for RamenDR Test Result reporting: Phase A's
read-only schema discovery tool for the production `RHELTEST` project, plus
Phase B/C's gated write support (`create_issue`/`transition_issue`) and its
pytest/sanity wiring. See
[`Ramen_DR_Jira_Test_Result_Integration_Plan.md`](Ramen_DR_Jira_Test_Result_Integration_Plan.md)
for the full phased plan and rationale.

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

## Phase B/C: reporting a Test Result (implemented, gated off by default)

Phase B/C add the ability to create and transition a real Jira Test Result,
but every default is the safest option and a real write requires **three**
independent, explicit opt-ins at once. `tests/ui/sanity/test_sanity.py` is
wired up to report automatically (see "Phase 1 pytest/sanity wiring" below);
the CLI (`scripts/jira/create_test_result_smoke.py`) is a separate, manual
entrypoint for ad hoc/smoke reporting outside of pytest.

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
  **approved-only** scenario-id -> Jira Test Case key mapping. Currently
  just `failover_primary_to_secondary` (`RHELTEST-3600`) and
  `relocate_secondary_to_primary` (`RHELTEST-3610`); the other 11 Test
  Cases are deliberately not mapped yet.
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

A real Jira write requires two independent, explicit environment opt-ins in
every caller: `JIRA_REPORT_RESULTS=true` **and** `JIRA_REPORT_DRY_RUN=false`.
Any other combination is either a pure offline payload build (reporting
disabled -- zero Jira calls, not even a GET) or a safe preview that validates
the parent Test Case with a read-only GET but performs no writes.

- **`scripts/jira/create_test_result_smoke.py` (CLI)** adds a *third*,
  CLI-specific gate on top of the two env vars: `--confirm` must also be
  passed. All three (`JIRA_REPORT_RESULTS=true`, `JIRA_REPORT_DRY_RUN=false`,
  `--confirm`) must be true together before this CLI performs a write.
- **`tests/ui/sanity/test_sanity.py` (pytest)** has no `--confirm`-equivalent
  flag -- it is gated purely by the two environment variables above. Setting
  `JIRA_REPORT_RESULTS=true` and `JIRA_REPORT_DRY_RUN=false` before running
  pytest is sufficient (and necessary) to enable real Jira writes from the
  sanity flow; see "Phase 1 pytest/sanity wiring" below.

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
JIRA_REPORT_RESULTS=false   # default: reporting fully off
JIRA_REPORT_DRY_RUN=true    # default: even if enabled, no write happens
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

Adding the remaining 11 Test Case mappings is future work pending review of
each parent Test Case. Only `failover_primary_to_secondary` (RHELTEST-3600)
and `relocate_secondary_to_primary` (RHELTEST-3610) are wired up (see below).
`BLOCKED` outcomes are not produced automatically yet -- pytest skips are
never translated into a Jira `BLOCKED` result.

## Phase 1 pytest/sanity wiring

`tests/ui/sanity/test_sanity.py::test_sanity_disaster_recovery_ui` reports
independent Jira Test Results for the two scenarios above via
`reporting.jira_results.jira_test_case_result()` -- a per-scenario reporting
boundary. `JIRA_REPORT_RESULTS=false` (the default) means an ordinary
developer/CI run of this test makes **zero** Jira calls.

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

- **`_run_force_full_sanity_dr_flow`** (used whenever
  `RAMENDR_SANITY_FORCE_FULL=1`, the default): both scenarios are always
  executed and are each a single contiguous `with jira_test_case_result(...):`
  block -- failover from the "initiate" dialog validation through
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
  closed) reports FAIL via `.close_failure(exc)`, then the exception is
  always re-raised unmodified.

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
otherwise a fresh `sanity-<random>-<epoch>` id -- called **once** per
`test_sanity_disaster_recovery_ui` invocation, so failover and relocate
always share one run id. Compose Version follows the existing rule: send
`customfield_11500` only when `RAMENDR_COMPOSE_VERSION` is set; never
fabricate `RHEL-9.8.0`/`unknown`/test placeholders.

### Tests

- `tests/reporting/test_jira_scenario_reporter.py` -- `JiraScenarioReporter`
  / `jira_test_case_result()` in isolation (context-manager and manual
  usage, PASS/FAIL, strict mode, double-close, disabled/dry-run, shared run
  id). All Jira calls mocked.
- `tests/ui/sanity/test_sanity_jira_wiring.py` -- calls the real
  `test_sanity_disaster_recovery_ui` method with every DR/Playwright/`oc`
  dependency monkeypatched to a no-op or scripted fake, and a fake Jira
  client. Covers fresh run, resume after failover, resume after relocate,
  independent failure attribution (failover PASS + relocate FAIL, and vice
  versa), reporting-disabled, dry-run, and `JIRA_REPORT_STRICT`.
