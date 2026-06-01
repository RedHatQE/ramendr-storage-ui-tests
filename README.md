# ramendr-storage-ui-tests

This repository is a **consumer test harness** for the upstream validated pattern
[validatedpatterns/ramendr-starter-kit](https://github.com/validatedpatterns/ramendr-starter-kit).

It contains:

- Deployment automation (`scripts/redeploy.sh`) that **pins upstream to `v1.1`**, applies the local customization overlays, and executes the same deployment flow currently used in the `redeploy.sh` from the forked starter-kit.
- Override values under `overrides/` that are copied on top of the upstream `overrides/` directory before installing the pattern.
- (Planned) UI tests using **Playwright + Python** (to be added later).
- **RamenDR data validation** — continuous timestamp writer + post-failover log checks ([`dr-validation/README.md`](dr-validation/README.md)).

## What this repo does

`scripts/redeploy.sh` will:

1. Clone upstream `validatedpatterns/ramendr-starter-kit` and check out ref `v1.1` (branch in upstream)
2. Copy this repo's `overrides/*.yaml` into the cloned upstream `overrides/`, apply `upstream-overrides/values-hub.patch` on top of upstream `values-hub.yaml`, and patch upstream `pattern.sh` to run `podman` without a TTY (required for CI — upstream uses `podman run -it` which fails when stdin/stdout are not a terminal)
3. Provision hub + two spokes on AWS (BYOC spokes)
4. Run the upstream pattern installation (ArgoCD/GitOps driven) via upstream `pattern.sh`

## Prerequisites

The deployment script expects tools similar to the original flow:

- `oc`
- `openshift-install`
- `aws`
- `podman` — must be **running** when the pattern deploy starts (`pattern.sh` uses a utility container). On macOS, start the VM before a long redeploy or rely on `redeploy.sh` to auto-start it: `podman machine start`
- `git`
- `python3`

You will also need AWS credentials configured for the AWS account used for cluster installs and Route53 operations (the script uses the AWS CLI).

## install-config files (examples)

The redeploy flow requires **three** `openshift-install` directories containing `install-config.yaml.bak`:

- `~/git/hub-cluster-install/install-config.yaml.bak`
- `~/git/ocp-primary-install/install-config.yaml.bak`
- `~/git/ocp-secondary-install/install-config.yaml.bak`

This repo provides **examples with placeholders only** under `install-config-examples/`.
Copy them into your install dirs and replace placeholders:

```bash
cp install-config-examples/hub/install-config.yaml.bak.example ~/git/hub-cluster-install/install-config.yaml.bak
cp install-config-examples/ocp-primary/install-config.yaml.bak.example ~/git/ocp-primary-install/install-config.yaml.bak
cp install-config-examples/ocp-secondary/install-config.yaml.bak.example ~/git/ocp-secondary-install/install-config.yaml.bak
```

Do **not** commit real `pullSecret` or `sshKey` values.

## Secrets policy

Do not commit secrets to this repository.

- Provide `VALUES_SECRET` (default: `~/values-secret.yaml`) locally/through CI secret injection.
- Keep kubeconfigs and install dirs out of git (see `.gitignore`).
- Use the upstream template as a reference: [values-secret.yaml.template](https://github.com/validatedpatterns/ramendr-starter-kit/blob/main/values-secret.yaml.template)
- For regional-dr cluster private-key ExternalSecrets, ensure `~/values-secret.yaml` includes hub `privatekey` paths (compare with your team's file via private DM), for example:

```yaml
- name: privatekey
  fields:
    - name: ssh-privatekey
      path: ~/.ssh/id_ed25519
    - name: ssh-publickey
      path: ~/.ssh/id_ed25519.pub
```

## Fork parity: BYOC and `values-hub.yaml`

Upstream v1.1 ships a stock [values-hub.yaml](https://github.com/validatedpatterns/ramendr-starter-kit/blob/v1.1/values-hub.yaml). Your fork changes that file (for example **ODF subscription channels** `stable-4.21`, and **including** `/overrides/values-aws-cost-optimized.yaml` in the regional-dr app's `extraValueFiles`).

This repo reproduces that without forking upstream:

- `upstream-overrides/values-hub.patch` — applied with `git apply` to the upstream checkout's root `values-hub.yaml` during `prepare_upstream` (if the patch no longer applies after an upstream bump, regenerate it from a clean checkout as described in `scripts/redeploy.sh` error messages).
- `overrides/values-cluster-names.yaml` — `byoc: true` and spoke metadata (same role as your fork's overrides for BYOC).

Replace placeholders in `overrides/values-cluster-names.yaml` under `costManagement:` (`<OWNER_TAG>`, etc.) with real tag values for your account policy.

## Usage

Two environment variables are **required** and have no default values:


| Variable         | Description                                                                     |
| ---------------- | ------------------------------------------------------------------------------- |
| `BASE_DOMAIN`    | Base DNS domain for the clusters (must be delegated to Route53 in your account) |
| `HOSTED_ZONE_ID` | Route53 hosted zone ID for that domain                                          |


Export them before running the script:

```bash
export BASE_DOMAIN=your-domain.example.com
export HOSTED_ZONE_ID=Z0123456789ABCDEFGHIJ
```

Then from the repo root:

```bash
./scripts/redeploy.sh --help
```

Run either a full redeploy or pattern-only on an existing hub, depending on your workflow.

## Customization overlays

Local overlays live under `overrides/` and are copied into the upstream checkout before install.
This keeps your changes reviewable and avoids long-lived forks of upstream.

## Code quality (pre-commit)

This repo uses [pre-commit](https://pre-commit.com/) to enforce linting and formatting on every commit (Python via ruff, shell via shellcheck, YAML via yamllint, plus general hygiene hooks).

### Install

```bash
pip install pre-commit
```

Or, using the repo's virtual environment:

```bash
python3 -m venv .venv
source .venv/bin/activate
pip install pre-commit
```

### Activate the hooks

Run once after cloning to install the git hook:

```bash
pre-commit install
```

After this, hooks run automatically on every `git commit`.

### Run manually before pushing

```bash
pre-commit run
```

This checks only the files you have staged. Pass `--all-files` if you want to scan the entire repository at once.

### CI enforcement

The same checks run automatically on every pull request via `.github/workflows/pre-commit.yaml`.
PRs that fail the checks cannot be merged.

## RamenDR data validation

A full `./scripts/redeploy.sh` run ends with timestamp writers **running on all edge VMs** (one
record every **10 seconds**) and a **rolling baseline snapshot** refreshed every 5 minutes (only the
latest snapshot is kept as the pre-failover baseline). After failover/relocate and the UI cleanup step, run:

```bash
./scripts/dr-validation/post-dr-automation.sh
```

That single command runs cleanup (with safety guards), waits for healthy VMs, and validates data — no other manual steps.

See [`docs/QA-DR-data-validation.md`](docs/QA-DR-data-validation.md) for the Jira-ready procedure.

Set `SKIP_DR_VALIDATION=1` to skip writers and snapshots, or `REQUIRE_DR_VALIDATION=1` to fail redeploy if writers are not recording.

If pattern deploy finished but timestamp bootstrap was skipped (e.g. interrupted redeploy), recover with:

```bash
export KUBECONFIG=~/git/hub-cluster-install/auth/kubeconfig
./scripts/redeploy.sh --dr-bootstrap-only
# or: ./scripts/dr-validation/bootstrap.sh && ./scripts/dr-validation/status.sh
```

See [`dr-validation/README.md`](dr-validation/README.md) for the full workflow.
