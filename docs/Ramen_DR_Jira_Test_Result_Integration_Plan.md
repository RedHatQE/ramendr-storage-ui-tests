# Ramen DR → Jira Test Result Integration Plan

## 1. Goal

Implement a safe integration between `ramendr-storage-ui-tests` and production Jira project `RHELTEST` so that an official pytest/Playwright execution creates a new Jira `Test Result` linked to the correct Jira `Test Case`.

Initial reportable mappings:

| Jira Test Case | Automated scenario | Coverage |
|---|---|---|
| `RHELTEST-3600` | Failover Primary → Secondary in `tests/ui/sanity/test_sanity.py::test_sanity_disaster_recovery_ui` | FULL |
| `RHELTEST-3610` | Relocate Secondary → Primary after failover in the same sanity flow | FULL |

Do **not** create automated Test Results for the other 11 cases yet. Some are partial or not automated.

Every automation-created result must eventually include:

- Issue type: `Test Result`
- Parent: matching Jira `Test Case`
- Status: `PASS`, `FAIL`, or later `BLOCKED`
- Labels: `ramen-dr`, `automation`
- Compose Version when known
- execution/run metadata
- timestamp
- failure summary when applicable

The Jira dashboard already exists and should update automatically once Test Results carry the `ramen-dr` label.

---

## 2. Critical design rule

Do not map the whole giant sanity pytest result to both Jira cases.

The current flow is:

```text
Primary
  |
  | FAILOVER
  v
Secondary
  |
  | RELOCATE
  v
Primary
```

If failover passes but relocate fails, Jira must show:

```text
RHELTEST-3600 -> PASS
RHELTEST-3610 -> FAIL
```

Therefore Jira reporting needs **independent scenario/result boundaries** inside the sanity flow.

---

## 3. Implementation phases

Implement in this order:

1. **Phase A — Discover production Jira schema**
2. **Phase B — Reusable Jira REST client**
3. **Phase C — Test Result payload builder**
4. **Phase D — Test Result creation + workflow transitions**
5. **Phase E — Scenario result abstraction**
6. **Phase F — Instrument failover and relocate**
7. **Phase G — Unit tests**
8. **Phase H — CI configuration**
9. **Phase I — controlled production pilot**

**STOP after Phase A and review the discovered schema before coding writes.**

---

## 4. Proposed repository structure

```text
reporting/
    __init__.py
    jira_client.py
    jira_models.py
    jira_results.py
    jira_test_cases.py

scripts/
    jira/
        discover_test_result_schema.py
        create_test_result_smoke.py

tests/
    reporting/
        test_jira_client.py
        test_jira_results.py

docs/
    jira-test-result-reporting.md
```

Do not put Jira REST calls directly throughout `test_sanity.py` or Playwright page objects.

---

# PHASE A — DISCOVER THE PRODUCTION JIRA SCHEMA

## 5. Why discovery comes first

We have seen a real production Jira `Test Result` in the UI, so we know the model contains fields such as:

```text
Test Result
Parent/Test Case relationship
Status
Labels
Fix versions
Compose Version
Description
Reporter
Assignee
```

However, Jira custom fields use internal IDs such as:

```text
customfield_12345
```

Do not guess those IDs.

The discovery tool must determine the real production configuration.

---

## 6. Questions Phase A must answer

The script must discover:

```text
RHELTEST project ID
Test Result issue type ID
Whether Test Result is a child/subtask type
Required create fields
Parent field behavior
Compose Version field ID
Compose Version payload schema
Labels behavior
Fix versions behavior
Initial workflow status
Available workflow transitions
Transition to PASS ID
Transition to FAIL ID
Transition to BLOCKED ID
```

---

## 7. Jira authentication

Never commit credentials.

Use environment variables:

```bash
export JIRA_BASE_URL="https://redhat.atlassian.net"
export JIRA_PROJECT_KEY="RHELTEST"
export JIRA_EMAIL="<red-hat-email>"
export JIRA_API_TOKEN="<token>"
```

The implementation should keep authentication isolated so it can later be changed if Red Hat requires another approved auth mechanism.

Never log:

```text
API token
Authorization header
password
full secret environment
```

Recommended `.gitignore` additions if relevant:

```text
.env
.env.*
jira-token.txt
.work/jira/
```

---

## 8. Use Jira Cloud REST API v3

Base path:

```text
/rest/api/3
```

Use the current project/issue-type create metadata endpoints rather than designing around the older deprecated monolithic `createmeta` endpoint.

---

## 9. Discovery step 1 — verify authentication

Call:

```http
GET /rest/api/3/myself
```

Expected:

```text
HTTP 200
```

Print only:

```text
displayName
accountId
```

Errors:

```text
401 -> authentication invalid
403 -> missing permission
```

Exit on failure.

---

## 10. Discovery step 2 — resolve project

Call:

```http
GET /rest/api/3/project/RHELTEST
```

Capture:

```python
project_key
project_id
project_name
```

Do not hardcode the numeric project ID.

---

## 11. Discovery step 3 — find `Test Result` issue type

Call:

```http
GET /rest/api/3/issue/createmeta/RHELTEST/issuetypes
```

Handle pagination.

Find:

```python
item["name"] == "Test Result"
```

Record:

```text
issue type ID
name
subtask flag
hierarchy level if present
```

Fail clearly if `Test Result` is unavailable.

---

## 12. Discovery step 4 — get create-field metadata

With the discovered issue type ID:

```http
GET /rest/api/3/issue/createmeta/RHELTEST/issuetypes/{issueTypeId}
```

Handle pagination until all fields are collected.

For every field record:

```text
field ID
display name
required
schema
allowed values
default value
operations
```

Print a readable table:

```text
FIELD NAME              FIELD ID             REQUIRED   TYPE
Summary                 summary              yes        string
Parent                  parent               ?          ?
Labels                  labels               ?          array
Compose Version         customfield_XXXXX    ?          ?
Fix versions            fixVersions           ?          array
...
```

Save sanitized metadata to:

```text
.work/jira/test-result-create-fields.json
```

---

## 13. Discovery step 5 — identify Compose Version

Search the returned create fields by display name:

```text
Compose Version
```

Record:

```text
field ID
required flag
schema.type
schema.items
schema.custom
allowedValues
```

Do **not** assume it is a plain string.

Its payload could be an option/object/custom value.

The discovery output must explicitly say what shape Jira expects.

---

## 14. Discovery step 6 — identify Parent behavior

Check whether `parent` is present in create metadata.

Record:

```text
required?
schema?
operations?
```

Also correlate with the `Test Result` issue type's `subtask`/hierarchy properties.

Candidate shape only:

```json
"parent": {
  "key": "RHELTEST-3600"
}
```

Do not treat that candidate as final until production metadata/pilot confirms it.

---

## 15. Discovery step 7 — inspect global field registry

Also call:

```http
GET /rest/api/3/field
```

Cross-check:

```text
Compose Version
Component Fix Version(s)
AssignedTeam
Test Steps
```

Important: `/field` confirms field IDs, but **create metadata is the source of truth for fields that can actually be set when creating a Test Result**.

Save:

```text
.work/jira/jira-fields.json
```

---

## 16. Discovery step 8 — inspect one existing Test Result

Support:

```bash
python scripts/jira/discover_test_result_schema.py \
  --sample-test-result RHELTEST-XXXX
```

When a sample key is supplied:

```http
GET /rest/api/3/issue/{KEY}?expand=names,schema
```

Inspect the stored shapes of:

```text
issuetype
parent
status
labels
fixVersions
Compose Version
description
reporter
assignee
```

This allows us to compare:

```text
what Jira allows at creation
vs.
how a real Test Result is stored
```

Save only sanitized useful fields.

---

## 17. Discovery step 9 — discover workflow transitions

For the sample Test Result:

```http
GET /rest/api/3/issue/{KEY}/transitions
```

Capture:

```text
transition ID
transition name
destination status name
destination status ID
```

We need actual transitions that reach:

```text
PASS
FAIL
BLOCKED
```

Do not assume transition name equals status name.

Save:

```text
.work/jira/test-result-transitions.json
```

---

## 18. Discovery script

Create:

```text
scripts/jira/discover_test_result_schema.py
```

CLI:

```bash
python scripts/jira/discover_test_result_schema.py
```

Optional:

```bash
python scripts/jira/discover_test_result_schema.py \
  --sample-test-result RHELTEST-XXXX
```

Arguments:

```text
--base-url
--project
--sample-test-result
--output-dir
--verbose
```

Defaults from:

```text
JIRA_BASE_URL
JIRA_PROJECT_KEY
JIRA_EMAIL
JIRA_API_TOKEN
```

Default output directory:

```text
.work/jira/
```

### Mandatory rule

**This script is READ ONLY.**

No POST/PUT/DELETE Jira operations.

---

## 19. Discovery outputs

Generate:

```text
.work/jira/
    project.json
    issue-types.json
    test-result-create-fields.json
    jira-fields.json
    sample-test-result.json
    test-result-transitions.json
    discovery-summary.txt
```

Do not dump comments, attachments, secrets, or unrelated user data.

---

## 20. Phase A success criteria

Do not proceed until we can fill this table with actual production values:

```text
RHELTEST project ID                  = ?
Test Result issue type ID            = ?
Test Result subtask/child            = ?
Required fields                      = ?
Parent field                         = ?
Parent required                      = ?
Compose Version field ID             = ?
Compose Version request shape        = ?
Labels field                         = ?
Fix versions field                   = ?
Initial Test Result status           = ?
Transition -> PASS                   = ?
Transition -> FAIL                   = ?
Transition -> BLOCKED                = ?
```

---

# PHASE B — REUSABLE JIRA CLIENT

## 21. `reporting/jira_client.py`

Responsibilities only:

```text
HTTP communication
authentication
timeouts
retry handling
safe error messages
Jira API calls
```

Suggested interface:

```python
class JiraClient:
    def get_current_user(self) -> dict: ...
    def get_project(self, project_key: str) -> dict: ...
    def get_create_issue_types(self, project_key: str) -> list[dict]: ...
    def get_create_fields(self, project_key: str, issue_type_id: str) -> dict: ...
    def get_fields(self) -> list[dict]: ...
    def get_issue(self, issue_key: str) -> dict: ...
    def get_transitions(self, issue_key: str) -> list[dict]: ...
    def create_issue(self, fields: dict) -> str: ...
    def transition_issue(self, issue_key: str, transition_id: str) -> None: ...
```

Use type hints and docstrings.

---

## 22. Network behavior

Use explicit timeouts, for example:

```python
timeout=(10, 30)
```

Read requests may retry:

```text
429
selected 5xx
```

Respect `Retry-After`.

Be very careful retrying issue-creation POSTs.

A POST may succeed server-side even if the response is lost; blindly retrying can create duplicate Test Results.

---

# PHASE C — MODELS AND CONFIGURATION

## 23. `reporting/jira_models.py`

```python
class TestOutcome(str, Enum):
    PASS = "PASS"
    FAIL = "FAIL"
    BLOCKED = "BLOCKED"
```

Suggested data model:

```python
@dataclass(frozen=True)
class JiraTestResult:
    test_case_key: str
    outcome: TestOutcome
    summary: str
    compose_version: str | None
    description: str | None
    labels: tuple[str, ...]
    run_url: str | None
    git_commit: str | None
    executed_at: datetime
    duration_seconds: float | None
```

Do not put custom field IDs in the domain model.

---

## 24. Runtime environment

Suggested:

```text
JIRA_REPORT_RESULTS
JIRA_REPORT_DRY_RUN
JIRA_REPORT_STRICT

JIRA_BASE_URL
JIRA_PROJECT_KEY
JIRA_EMAIL
JIRA_API_TOKEN

JIRA_TEST_RESULT_ISSUE_TYPE_ID
JIRA_COMPOSE_VERSION_FIELD_ID

JIRA_PASS_TRANSITION_ID
JIRA_FAIL_TRANSITION_ID
JIRA_BLOCKED_TRANSITION_ID

RAMENDR_COMPOSE_VERSION
JIRA_RUN_ID
CI_JOB_URL
GIT_COMMIT
```

---

## 25. Reporting must be opt-in

Default:

```text
JIRA_REPORT_RESULTS=false
```

A developer running pytest locally must not create production Jira issues.

Only official/controlled runs enable:

```bash
export JIRA_REPORT_RESULTS=true
```

---

## 26. Dry run

Support:

```text
JIRA_REPORT_DRY_RUN=true
```

Dry-run behavior:

```text
build payload
validate config
print sanitized intended action
perform ZERO Jira writes
```

Example:

```text
[Jira dry-run]
Test Case: RHELTEST-3600
Outcome: PASS
Labels: ramen-dr, automation
Compose: ...
```

---

# PHASE D — CREATE A TEST RESULT

## 27. Minimum conceptual payload

Only after discovery confirms field IDs/shapes:

```json
{
  "fields": {
    "project": {"key": "RHELTEST"},
    "issuetype": {"id": "<DISCOVERED_TEST_RESULT_ID>"},
    "summary": "Ramen DR | RHELTEST-3600 | failover | <compose> | <timestamp>",
    "parent": {"key": "RHELTEST-3600"},
    "labels": ["ramen-dr", "automation"],
    "<DISCOVERED_COMPOSE_FIELD>": "<DISCOVERED_VALUE_SHAPE>"
  }
}
```

This example is conceptual; Parent and Compose shapes must be confirmed first.

---

## 28. Description

REST API v3 descriptions should be generated in Atlassian Document Format.

Logical content:

```text
Automation: pytest + Playwright
Repository: ramendr-storage-ui-tests
Test: tests/ui/sanity/test_sanity.py::test_sanity_disaster_recovery_ui
Scenario: failover
Parent Test Case: RHELTEST-3600
Git commit: <sha>
CI run: <url>
Run ID: <id>
Executed at: <UTC timestamp>
Duration: <seconds>
Outcome: PASS
```

On failure:

```text
Failure:
<exception class>: <short sanitized message>
```

Do not put huge stack traces into Jira. Link to CI logs.

---

## 29. Labels

Every automation-created result:

```text
ramen-dr
automation
```

Do not depend on label inheritance.

This is what allows the existing saved filter/dashboard to pick the new Test Result up automatically.

---

## 30. Compose Version

Populate when known.

Do not fabricate a version.

If missing:

```text
leave unset
log warning
```

Do not equate Compose Version with Jira Fix Version.

---

## 31. Result creation workflow

Recommended:

```text
1. Validate config
2. Validate parent Test Case
3. Build fields
4. POST Test Result
5. Capture new Jira key
6. Discover/read transitions
7. Transition to PASS/FAIL/BLOCKED
8. Log new Test Result key
```

Do not assume the initial created status is PASS.

---

# PHASE E — SCENARIO RESULT BOUNDARY

## 32. `reporting/jira_results.py`

Conceptual API:

```python
with jira_test_case_result(
    test_case_key="RHELTEST-3600",
    scenario="failover",
    compose_version=compose_version,
):
    run_failover_phase()
```

Behavior:

```text
enter -> record start
normal exit -> create PASS
exception -> create FAIL, then re-raise original exception
```

Never swallow the pytest failure.

---

## 33. Jira reporting failures

Keep test failure and reporting failure separate.

If test fails and Jira also fails:

```text
preserve original test failure
log reporting error as secondary
```

Optional strict mode:

```text
JIRA_REPORT_STRICT=true
```

If test passed but reporting failed:

```text
strict=true  -> fail official reporting CI
strict=false -> warn
```

---

## 34. BLOCKED

Do not map every pytest skip to BLOCKED.

BLOCKED should mean execution was prevented by a real environment/precondition failure.

Phase 1 may implement only PASS/FAIL.

Add BLOCKED later with an explicit classification, e.g.:

```python
class TestBlockedError(RuntimeError):
    pass
```

---

# PHASE F — SANITY TEST INSTRUMENTATION

## 35. Failover → `RHELTEST-3600`

The Jira boundary must include enough checks to claim the manual scenario passed:

```text
baseline
failover dialog validation
initiate failover
wait for completion
target is ocp-secondary
VMs Running
SSH reachability
RTO validation
DR/data validation
```

Only then:

```text
RHELTEST-3600 -> PASS
```

Any failure inside boundary:

```text
RHELTEST-3600 -> FAIL
```

---

## 36. Relocate → `RHELTEST-3610`

Boundary:

```text
DRPC healthy on secondary
relocate dialog validation
baseline
initiate relocate
cleanup/wait logic
completion on ocp-primary
VMs Running
SSH reachability
RTO validation
DR/data validation
```

Then independent PASS/FAIL.

---

## 37. Resume logic warning

The existing sanity test can resume from states such as:

```text
fresh primary
post-failover
post-relocate
```

Initial policy:

**Create a Jira Test Result only for a phase this pytest invocation actually executes and validates.**

Do not infer and backfill historical PASS results simply because the environment is already post-failover.

---

# PHASE G — TESTS

## 38. Unit tests

Mock Jira completely.

Cover:

```text
authentication
pagination
Test Result type lookup
field metadata parsing
Compose field lookup
Parent parsing
transition lookup
PASS transition
FAIL transition
429 handling
5xx handling
dry-run
reporting disabled
ADF description
failure truncation
credentials not logged
original pytest exception preserved
```

Unit tests must never contact production Jira.

---

# PHASE H — CI

## 39. Enable only for official validation

Example:

```bash
JIRA_REPORT_RESULTS=true
JIRA_REPORT_DRY_RUN=false
JIRA_REPORT_STRICT=true
JIRA_BASE_URL=https://redhat.atlassian.net
JIRA_PROJECT_KEY=RHELTEST
RAMENDR_COMPOSE_VERSION=<compose>
JIRA_RUN_ID=<pipeline-run-id>
CI_JOB_URL=<run-url>
GIT_COMMIT=<sha>
```

Credentials come from CI secret storage.

Never echo them.

---

# PHASE I — CONTROLLED PILOT

## 40. Smoke creation script

Create:

```text
scripts/jira/create_test_result_smoke.py
```

Must require dry-run or explicit confirmation.

First:

```bash
python scripts/jira/create_test_result_smoke.py \
  --test-case RHELTEST-3600 \
  --outcome PASS \
  --compose "<compose>" \
  --dry-run
```

Only after payload review:

```bash
python scripts/jira/create_test_result_smoke.py \
  --test-case RHELTEST-3600 \
  --outcome PASS \
  --compose "<compose>" \
  --confirm
```

No accidental writes.

---

## 41. Validate first created Test Result manually

Check:

```text
Issue Type = Test Result
Parent = RHELTEST-3600
Status = PASS
Labels contains ramen-dr
Labels contains automation
Compose Version correct
Description/run metadata correct
```

Then dashboard:

```text
Test Results total +1
PASS +1
Results by Compose Version gets new PASS
Failed / Blocked remains unchanged
```

Then run a controlled FAIL pilot and confirm Failed/Blocked gadget behavior.

---

# 42. Duplicate protection

Include:

```text
JIRA_RUN_ID
scenario
parent Test Case
```

in metadata/summary.

Do not blindly retry ambiguous issue-creation failures.

Future duplicate check can search for the same:

```text
run ID + scenario + parent
```

before retrying.

---

# 43. Mapping registry

Add:

```text
reporting/jira_test_cases.py
```

Initial contents conceptually:

```python
RAMENDR_JIRA_TEST_CASES = {
    "failover_primary_to_secondary": "RHELTEST-3600",
    "relocate_secondary_to_primary": "RHELTEST-3610",
}
```

Do not add partial/not-automated cases as reportable mappings yet.

---

# 44. Cursor coding constraints

1. Do not alter existing DR semantics.
2. Keep Jira code isolated from Playwright page objects.
3. Reporting disabled by default.
4. No credentials in source.
5. No guessed custom field IDs.
6. No guessed transition IDs.
7. REST API v3.
8. Explicit network timeouts.
9. No blind POST retries.
10. Unit tests mock Jira.
11. Type hints required.
12. Public helpers/classes get docstrings.
13. Do not create Test Results for partial coverage.
14. Do not swallow original pytest exceptions.
15. Jira reporting errors must not replace the real DR failure.
16. Keep payload generation separately testable.
17. Keep API communication separately testable.
18. Keep mapping explicit.
19. Keep changes small/reviewable.
20. Stop after Phase A until schema review.

---

# 45. Recommended commits

### Commit 1

```text
Add read-only Jira Test Result schema discovery
```

No writes.

### Commit 2

```text
Add Test Result model, payload builder and dry-run
```

Writes still disabled by default.

### Commit 3

```text
Add controlled Test Result create and transitions
```

### Commit 4

```text
Report RHELTEST-3600 failover result
```

### Commit 5

```text
Report RHELTEST-3610 relocate result
```

---

# 46. FIRST TASK FOR CURSOR NOW

Implement only this:

```text
Create a READ-ONLY Jira Test Result schema discovery tool for production
RHELTEST.

Requirements:

1. Authenticate from environment variables.
2. GET /rest/api/3/myself.
3. Resolve RHELTEST project.
4. Discover issue types available for creation.
5. Find "Test Result".
6. Record issue type ID and child/subtask properties.
7. Fetch all Test Result create fields.
8. Print field name, ID, required, schema, allowed values.
9. Specifically identify Parent, Compose Version, Labels,
   Fix versions, Description, Test Steps.
10. GET /rest/api/3/field to cross-check field IDs.
11. Support --sample-test-result RHELTEST-XXXX.
12. When sample supplied, inspect stored field shapes.
13. When sample supplied, GET available transitions.
14. Save sanitized output to .work/jira/.
15. ZERO Jira writes.
16. Mock all Jira requests in unit tests.
17. Never log credentials.
18. Use REST API v3.
19. Use explicit HTTP timeouts.
20. STOP after discovery.
```

---

# 47. Command to run after Cursor finishes Phase A

```bash
export JIRA_BASE_URL="https://redhat.atlassian.net"
export JIRA_PROJECT_KEY="RHELTEST"
export JIRA_EMAIL="<email>"
export JIRA_API_TOKEN="<token>"

python scripts/jira/discover_test_result_schema.py
```

If we know the real sample Test Result key:

```bash
python scripts/jira/discover_test_result_schema.py \
  --sample-test-result RHELTEST-XXXX
```

Then review/paste back:

```text
.work/jira/discovery-summary.txt
.work/jira/test-result-create-fields.json
.work/jira/test-result-transitions.json
```

---

# 48. Stop point

Do not implement writes until we know:

```text
Test Result issue type ID
child/subtask behavior
required fields
Parent payload shape
Compose Version field ID
Compose Version payload shape
initial status
PASS transition ID
FAIL transition ID
BLOCKED transition ID
```

Once these production values are reviewed, proceed to Test Result creation.

---

# 49. Final target

```text
Official Ramen DR CI
        |
        +-- Failover
        |     |
        |     +-- RHELTEST-3600
        |              |
        |              +-- new Test Result -> PASS/FAIL
        |
        +-- Relocate
              |
              +-- RHELTEST-3610
                       |
                       +-- new Test Result -> PASS/FAIL
```

Each result carries:

```text
Parent Test Case
ramen-dr
automation
Compose Version
run ID / CI URL
git commit
timestamp
PASS/FAIL
```

The existing dashboard then updates automatically.
