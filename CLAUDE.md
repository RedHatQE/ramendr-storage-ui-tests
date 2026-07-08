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
  (default `7d24917bae80392615ed4877773260a7221d8d1a` on branch `ocp-4.22`).
  Override with `UPSTREAM_REPO` / `UPSTREAM_REF`.
- **Hub Argo CD** (ongoing GitOps sync): reads values from the fork on GitHub at
  branch `ocp-4.22` (branch tip unless Applications pin a specific revision).

Customizations (Windows edge VMs, additionalPvcDisks, byoc cluster names, ODF channel pins,
cost-optimized values) live in the fork's `ocp-4.22` branch under `overrides/` and
values files. Local edits next to the checkout do not affect Argo CD.

- It runs the deployment via upstream `pattern.sh make install-byoc` (utility-container).
- After hub + spoke `openshift-install`, `redeploy.sh` copies `VALUES_SECRET` to
  `.work/values-secret.yaml`, merges spoke kubeconfig file paths, and passes that file to
  `install-byoc`. Vault + ExternalSecrets deliver kubeconfigs to ACM (no manual `oc create secret`).

**Mixed edge VM fleet (`gitops-vms`):**

- 2× RHEL — `rhel9-node-*` (DataVolume data disk) + `rhel9-node-pvc-*` (PVC data disk); HammerDB PostgreSQL on both
- 1× Windows Server 2022 (`windows2k22-server-*`) + 1× Windows Server 2025 (`windows2k25-server-*`); HammerDB SQL Server
- Windows OS disks clone from fork `externalDataSources`; registry import requires
  **`privatevm-credentials`** (Quay robot account) in `values-secret.yaml`
- **`windows-admin`** in `values-secret.yaml` — `password` for local Administrator SSH
  (images ship OpenSSH pre-configured; `ensure-windows-openssh.sh` verifies login in-cluster)
- `redeploy.sh` runs `scripts/stabilize-windows-vms.sh` and `scripts/ensure-windows-openssh.sh`
  after hub convergence; **`REQUIRE_WINDOWS_VMS=1` by default** (set `0` to allow redeploy
  when Windows stabilize/OpenSSH fails)

All sensitive inputs must be provided externally:

- `VALUES_SECRET` should point to a local file (default `~/values-secret.yaml`). Spoke kubeconfig
  paths are refreshed automatically in `.work/values-secret.yaml` each redeploy.
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

Smoke tests expect the full mixed fleet (4 edge VMs) and validate Windows OS disk size (45 Gi).

## Future

- CI entrypoints that reuse the same deployment and then run UI tests against the hub console
