# ramendr-storage-ui-tests

This repository is a **test harness** for the RamenDR validated pattern.
It deploys from a maintained fork of the upstream starter kit —
[elsapassaro/ramendr-starter-kit](https://github.com/elsapassaro/ramendr-starter-kit) (branch `v1.1`) —
which carries all environment-specific customizations (additional VM disks, BYOC cluster names,
ODF channel pins, cost-optimized instance profiles) committed directly so that ArgoCD picks them
up automatically on every sync.

It contains:

- Deployment automation (`scripts/redeploy.sh`) that pins the fork to an immutable commit SHA and executes the full deployment flow.
- UI and sanity tests using **Playwright + Python** (`tests/`).
- **RamenDR data validation** — continuous timestamp writer + post-failover log checks ([`dr-validation/README.md`](dr-validation/README.md)).

## What this repo does

`scripts/redeploy.sh` will:

1. Clone the fork `elsapassaro/ramendr-starter-kit` at a pinned commit SHA (defaulting to the tip of `v1.1`) into `.work/upstream/ramendr-starter-kit`.
2. Patch upstream `pattern.sh` to run `podman` without a TTY (required for CI — upstream uses `podman run -it` which fails when stdin/stdout are not a terminal). No local file injection into ArgoCD's sync path is needed: all customizations live in the fork.
3. Provision hub + two spokes on AWS (BYOC spokes).
4. Run the upstream pattern installation (ArgoCD/GitOps driven) via upstream `pattern.sh`. ArgoCD reads values files directly from the fork's `v1.1` branch on GitHub.

> **Why a fork?** ArgoCD fetches all values files directly from the remote GitHub repository at the pinned ref — local copies placed next to the checkout are invisible to it. Committing customizations into the fork's branch is the only way to have ArgoCD reconcile them automatically.

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
- Use the upstream template as a reference: [values-secret.yaml.template](https://github.com/elsapassaro/ramendr-starter-kit/blob/v1.1/values-secret.yaml.template)
- For regional-dr cluster private-key ExternalSecrets, ensure `~/values-secret.yaml` includes hub `privatekey` paths (compare with your team's file via private DM), for example:

```yaml
- name: privatekey
  fields:
    - name: ssh-privatekey
      path: ~/.ssh/id_ed25519
    - name: ssh-publickey
      path: ~/.ssh/id_ed25519.pub
```

## Customizing the deployment

All environment-specific values (additional VM disks, BYOC cluster names, ODF channel pins,
cost-optimized instance profiles) live in the fork's `v1.1` branch under `overrides/` and
`values-hub.yaml`. To adapt the deployment for a different AWS account or region:

1. Fork `elsapassaro/ramendr-starter-kit` (or push a new branch on the existing fork).
2. Edit the relevant `overrides/*.yaml` files in that branch.
3. Point `redeploy.sh` at your fork by setting `UPSTREAM_REPO` and `UPSTREAM_REF`:

```bash
export UPSTREAM_REPO=https://github.com/<your-org>/ramendr-starter-kit
export UPSTREAM_REF=<commit-sha-or-branch>
./scripts/redeploy.sh --pattern-only
```

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
pre-commit run --all-files
```

If a hook reformats files, stage the changes and commit again.

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
Defaults enforce a **2-minute RPO** and **20-minute RTO** (warn at 15 minutes): `DR_VALIDATION_MAX_RPO_SECONDS=120`,
`RAMENDR_SANITY_MAX_RTO_SECONDS=1200`, and `RAMENDR_SANITY_RTO_WARN_SECONDS=900` (override via env vars if your target changes).

See [`docs/QA-DR-data-validation.md`](docs/QA-DR-data-validation.md) for the Jira-ready procedure.

Set `SKIP_DR_VALIDATION=1` to skip writers and snapshots, or `REQUIRE_DR_VALIDATION=1` to fail redeploy if writers are not recording.

If pattern deploy finished but timestamp bootstrap was skipped (e.g. interrupted redeploy), recover with:

```bash
export KUBECONFIG=~/git/hub-cluster-install/auth/kubeconfig
./scripts/redeploy.sh --dr-bootstrap-only
# or: ./scripts/dr-validation/bootstrap.sh && ./scripts/dr-validation/status.sh
```

See [`dr-validation/README.md`](dr-validation/README.md) for the full workflow.
