# ramendr-storage-ui-tests

This repository is a **test harness** for the RamenDR validated pattern.
It deploys from a maintained fork of the upstream starter kit —
[elsapassaro/ramendr-starter-kit](https://github.com/elsapassaro/ramendr-starter-kit) (branch `ocp-4.22`) —
which carries all environment-specific customizations (Windows edge VMs, additional VM disks, BYOC cluster names,
ODF channel pins, cost-optimized instance profiles). **`redeploy.sh` pins a fixed commit SHA**
for the local pattern install; **hub Argo CD** reconciles from the fork's remote branch on GitHub
(see [Upstream pinning](#upstream-pinning) below).

It contains:

- Deployment automation (`scripts/redeploy.sh`) that pins the fork to an immutable commit SHA and executes the full deployment flow.
- UI and sanity tests using **Playwright + Python** (`tests/`).
- **RamenDR data validation** — HammerDB PostgreSQL TPC-C by default ([`dr-validation/README.md`](dr-validation/README.md), [`dr-validation/DATABASE-SCHEMA.md`](dr-validation/DATABASE-SCHEMA.md)).

## What this repo does

`scripts/redeploy.sh` will:

1. Clone the fork `elsapassaro/ramendr-starter-kit` at the pinned commit SHA `7d24917bae80392615ed4877773260a7221d8d1a` from the `ocp-4.22` branch into `.work/upstream/ramendr-starter-kit`.
2. Patch upstream `pattern.sh` to run `podman` without a TTY (required for CI — upstream uses `podman run -it` which fails when stdin/stdout are not a terminal). No local file injection into ArgoCD's sync path is needed: all customizations live in the fork.
3. Provision hub + two spokes on AWS (BYOC spokes).
4. Copy your `VALUES_SECRET` into `.work/values-secret.yaml`, merge fresh spoke kubeconfig
   paths (`ocp-primary_cluster_kubeconfig`, `ocp-secondary_cluster_kubeconfig`), and run
   upstream `pattern.sh make install-byoc` (loads secrets to Vault, validates BYOC, deploys pattern).
5. Wait for ExternalSecrets to create `auto-import-secret` and `admin-kubeconfig` on the hub; ACM
   imports the spokes.

> **BYOC:** The fork sets `byoc: true`. Your `~/values-secret.yaml` may omit spoke kubeconfigs or
> contain stale paths from a previous deploy — `redeploy.sh` always refreshes them in
> `.work/values-secret.yaml` (gitignored) before `install-byoc`. Your source file is never modified.
>
> **Why a fork?** Hub Argo CD fetches values from the remote GitHub repository — local copies placed next to the checkout are invisible to it. Both `redeploy.sh` and hub Applications should track fork branch `ocp-4.22` so GitOps matches the local pin.

### Upstream pinning

Two different upstream references are in play:

| Consumer | Source | Default |
|----------|--------|---------|
| `redeploy.sh` local checkout | `UPSTREAM_REF` commit SHA checked out into `.work/upstream/` | `7d24917bae80392615ed4877773260a7221d8d1a` (on branch `ocp-4.22`) |
| Hub Argo CD Applications | Remote fork on GitHub | Branch `ocp-4.22` (tip unless an Application pins `targetRevision`) |

To test a different fork commit locally, set `UPSTREAM_REPO` and `UPSTREAM_REF` before running
`redeploy.sh`. For Argo CD to match that commit, push it to the tracked branch or pin
`targetRevision` on the hub Applications.

## Prerequisites

The deployment script expects tools similar to the original flow:

- `oc`
- `openshift-install`
- `aws`
- `podman` — must be **running** when the pattern deploy starts (`pattern.sh` uses a utility container). On macOS, start the VM before a long redeploy or rely on `redeploy.sh` to auto-start it: `podman machine start`
- `git`
- `python3` with **PyYAML** (`python3 -m pip install pyyaml`) — merges spoke kubeconfig paths into `.work/values-secret.yaml` before `install-byoc`
- `jq` — used by the golden-image Ansible playbook and several redeploy helpers
- `ansible-playbook` — runs `scripts/ansible/odf_fix_dataimportcrons.yml` during spoke golden-image fix-up (optional; redeploy falls back to `oc` if this step fails)

You will also need AWS credentials configured for the AWS account used for cluster installs and Route53 operations (the script uses the AWS CLI).

### Ansible golden-image playbook

During redeploy, `redeploy.sh` may run `scripts/ansible/odf_fix_dataimportcrons.yml` **on the host
machine where you launch redeploy** (`connection: local`, `hosts: localhost`). It uses `oc` with
spoke `KUBECONFIG` to clean up CDI `DataImportCron` objects when the virtualization default storage
class differs from the cluster default.

That playbook needs:

- Ansible collection **`kubernetes.core`** — provides the `k8s_info` and `k8s` modules used to list and
  delete CDI objects
- Python package **`kubernetes`** — required by those modules at runtime

Install the collection with `ansible-galaxy collection install kubernetes.core`. Install the Python
package for the **same interpreter Ansible uses for `localhost`** (not necessarily the interpreter
in an activated virtualenv). On Fedora, `dnf install python3-kubernetes` may target a different
Python than Ansible auto-discovers (e.g. package on 3.14 while Ansible picks 3.12).

`redeploy.sh` auto-selects the first interpreter that can `import kubernetes` (default
`/usr/bin/python3`, then 3.14/3.13/3.12) and sets `ANSIBLE_PYTHON_INTERPRETER` for the playbook.
Override with `export ANSIBLE_PYTHON_INTERPRETER=/usr/bin/python3.14` if needed. If no suitable
interpreter is found, the playbook is skipped and `redeploy.sh` continues with direct `oc`
golden-image cleanup instead.

`requirements.txt` covers UI tests (Playwright/pytest) only; it does **not** install these Ansible
dependencies.

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
- Use the upstream template as a reference: [values-secret.yaml.template](https://github.com/elsapassaro/ramendr-starter-kit/blob/ocp-4.22/values-secret.yaml.template)
- For regional-dr cluster private-key ExternalSecrets, ensure `~/values-secret.yaml` includes hub `privatekey` paths (compare with your team's file via private DM), for example:

```yaml
- name: privatekey
  fields:
    - name: ssh-privatekey
      path: ~/.ssh/id_ed25519
    - name: ssh-publickey
      path: ~/.ssh/id_ed25519.pub
```

- For **Windows edge VMs** (private `quay.io/martjack/*` images), add `privatevm-credentials`
  (Quay robot `accessKeyId` / `secretKey`) and `windows-admin` (`password` for local
  `Administrator` SSH). See
  [`dr-validation/examples/values-secret-v2-windows.fragment.yaml`](dr-validation/examples/values-secret-v2-windows.fragment.yaml).
  For HammerDB on Windows SQL Server, also add `mssql-hammerdb` (`sa_password`, `user`,
  `password`) or export `DR_VALIDATION_MSSQL_*` before redeploy.

## Customizing the deployment

All environment-specific values (additional VM disks, BYOC cluster names, ODF channel pins,
cost-optimized instance profiles) live in the fork's `ocp-4.22` branch under `overrides/` and
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

Default mode is **HammerDB TPC-C on PostgreSQL** (`DR_VALIDATION_MODE=hammerdb`) on
`rhel9-node-001` (one of two Linux edge VMs). The default fleet is **four VMs** in
`gitops-vms`: 2 Linux + 1 Windows Server 2022 + 1 Windows Server 2025. Add
`privatevm-credentials` (Quay robot for `quay.io/martjack/*` images) and
`windows-admin` (local Administrator password for Windows SSH verification) to
`~/values-secret.yaml` before redeploy. A full `./scripts/redeploy.sh` run **automatically** bootstraps PostgreSQL,
builds populated TPC-C tables (customers with IDs, orders, stock, …), verifies recording,
and saves an initial baseline snapshot to `.work/dr-validation-db/auto/latest`.

For DR validation, capture a fresh baseline immediately before Initiate (the sanity test
does this automatically; for manual runs use `./scripts/dr-validation/save-db-baseline-snapshot.sh`).

Smoke tests assert the database tables are populated after redeploy; sanity tests validate
table data continuity after failover/relocate via `check-after-dr.sh`.

After DR in the UI, run:

```bash
./scripts/dr-validation/post-dr-automation.sh
```

Defaults enforce a **2-minute RPO** and **20-minute RTO** (warn at 15 minutes):
`DR_VALIDATION_MAX_RPO_SECONDS=120`, `RAMENDR_SANITY_MAX_RTO_SECONDS=1200`, and
`RAMENDR_SANITY_RTO_WARN_SECONDS=900`.

See [`dr-validation/DATABASE-SCHEMA.md`](dr-validation/DATABASE-SCHEMA.md) for table details.

Set `SKIP_DR_VALIDATION=1` only to intentionally skip automatic DR validation.
Set `DR_VALIDATION_MODE=timestamp` for the legacy per-VM timestamp log mode.

If redeploy was interrupted, re-run automatic bootstrap on an existing environment:

```bash
export KUBECONFIG=~/git/hub-cluster-install/auth/kubeconfig
./scripts/redeploy.sh --dr-bootstrap-only
```

See [`dr-validation/README.md`](dr-validation/README.md) and [`docs/QA-DR-data-validation.md`](docs/QA-DR-data-validation.md).
