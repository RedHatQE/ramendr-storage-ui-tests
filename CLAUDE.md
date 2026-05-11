# Context for automation and tests

## Goal

This repository (`ramendr-storage-ui-tests`) provides:

- A reproducible way to deploy the upstream validated pattern
`validatedpatterns/ramendr-starter-kit` pinned to **v1.1**
- Local customization overlays (values under `overrides/`)
- A home for UI tests (Playwright + Python) to validate RamenDR workflows

## Non-goals

- Do not vendor or fork upstream content long-term.
- Do not commit any secrets, kubeconfigs, pull secrets, tokens, or credentials.

## Deployment contract

The entrypoint is `scripts/redeploy.sh`.

- It clones upstream at tag `v1.1` into `.work/upstream/ramendr-starter-kit`.
- It copies this repo�s `overrides/*.yaml` on top of upstream `overrides/`.
- It runs the upstream deployment via upstream `pattern.sh` (utility-container).

All sensitive inputs must be provided externally:

- `VALUES_SECRET` should point to a local file (default `~/values-secret.yaml`).
- AWS credentials are provided through the environment/standard AWS CLI configuration.

## Security requirements

- Never print secret file contents in logs.
- Never write kubeconfigs or tokens into tracked paths.
- Treat CI logs/artifacts as potentially shared; redact where necessary.

## Future (UI tests)

Plan is to add:

- `ui-tests/` (Python + Playwright)
- A minimal `pyproject.toml` with Playwright tooling
- CI entrypoints that reuse the same deployment and then run UI tests against the hub console