# Context for automation and tests

## Goal

This repository (`ramendr-storage-ui-tests`) provides:

- A reproducible way to deploy the fork of the upstream validated pattern
  `elsapassaro/ramendr-starter-kit` (branch `ocp-4.22`, pinned locally by commit SHA)
- A home for UI tests (Playwright + Python) to validate RamenDR workflows

## Non-goals

- Do not vendor or fork upstream content long-term.
- Do not commit any secrets, kubeconfigs, pull secrets, tokens, or credentials.

## Deployment contract

The entrypoint is `scripts/redeploy.sh`.

**Upstream pinning (two references):**

- **Local checkout** (`pattern.sh`, utility container): cloned into
  `.work/upstream/ramendr-starter-kit` at the immutable commit in `UPSTREAM_REF`
  (default `04b9d2f29d2d3844294ec957bd679bd2ba7452ac` on branch `ocp-4.22`).
  Override with `UPSTREAM_REPO` / `UPSTREAM_REF`.
- **Hub Argo CD** (ongoing GitOps sync): reads values from the fork on GitHub at
  branch `ocp-4.22` (branch tip unless Applications pin a specific revision).

Customizations (additionalDisks, chartVersion, byoc cluster names, ODF channel pins,
cost-optimized values) live in the fork's `ocp-4.22` branch under `overrides/` and
values files. Local edits next to the checkout do not affect Argo CD.

- It runs the deployment via upstream `pattern.sh` (utility-container).

All sensitive inputs must be provided externally:

- `VALUES_SECRET` should point to a local file (default `~/values-secret.yaml`).
- AWS credentials are provided through the environment/standard AWS CLI configuration.

## Security requirements

- Never print secret file contents in logs.
- Never write kubeconfigs or tokens into tracked paths.
- Treat CI logs/artifacts as potentially shared; redact where necessary.

## UI tests

Currently implemented in `tests/ui/`:

- `tests/ui/smoke/test_smoke.py` — infrastructure checks (`oc` CLI) and a Playwright UI walkthrough
- Page objects for login, dashboard, and ACM disaster recovery navigation (`pages/`)
- `utils/oc.py` — subprocess wrapper for `oc` CLI calls
- `conftest.py` — session-scoped fixtures for kubeconfigs and browser context
- `pyproject.toml` + `pytest.ini` — test runner configuration with Playwright

## Future

- CI entrypoints that reuse the same deployment and then run UI tests against the hub console
