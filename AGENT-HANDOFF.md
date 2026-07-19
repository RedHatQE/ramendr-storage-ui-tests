# Agent handoff: RamenDR storage UI tests / pattern consumer

This document summarizes decisions and context from prior work so another agent can continue without re-reading the full thread.

## What this repository is

- **Consumer / test harness** for upstream [`elsapassaro/ramendr-starter-kit`](https://github.com/elsapassaro/ramendr-starter-kit), pinned by default to commit **`d9dcdc4c24b8a868c62d528ee74e6e2becf4fc9f`** (fork branch **`ocp-4.22`**, pin ODF 4.22 version). Hub Argo CD also tracks **`ocp-4.22`** on the same fork.
- **Does not** long-term fork upstream. Environment customizations (Windows edge VMs, BYOC, ODF pins, cost profiles) live in the **fork** on GitHub; this repo only patches upstream `pattern.sh` locally (non-TTY podman).
- **Future:** Playwright + Python UI tests (partially implemented). **Today:** deployment scripts, install-config examples, DR validation.

## Upstream pattern mechanics (high level)

- Validated Pattern uses **Helm values** (`values-*.yaml`) and **Argo CD** (`applications` in `values-hub.yaml` with sync policies, sync waves, etc.). Automation runs via `**pattern.sh`** + `**podman`** + utility container.
- User’s fork parity for **BYOC** and hub behavior is reproduced here without forking.

## Key entrypoint: `scripts/redeploy.sh`

1. Clones/fetches upstream into `**.work/upstream/ramendr-starter-kit`** (see `.gitignore`; not committed).
2. Checks out `**UPSTREAM_REF`** (default `d9dcdc4c24b8a868c62d528ee74e6e2becf4fc9f` from fork `ocp-4.22`). Override: `UPSTREAM_REPO`, `UPSTREAM_REF`, `UPSTREAM_BRANCH`, `WORK_DIR`, `UPSTREAM_DIR`.
3. Patches upstream `**pattern.sh`** **from inside `$UPSTREAM_DIR`** so `podman` uses `-i` when no TTY (upstream uses `podman run -it` which fails in CI when stdin/stdout are not a terminal) and so Darwin arm64 runs the amd64 utility container under emulation.
4. Provisions **hub + two spokes** via `openshift-install` using directories `**HUB_INSTALL_DIR`**, `**PRIMARY_INSTALL_DIR`**, `**SECONDARY_INSTALL_DIR**` (each needs `**install-config.yaml.bak**`).
5. Merges spoke kubeconfig paths into `**.work/values-secret.yaml**` (copy of `VALUES_SECRET`; source file never modified) and runs `**./pattern.sh make install-byoc**` from the upstream checkout.
6. Waits for BYOC spoke import (ExternalSecrets + `ManagedCluster` Joined), spoke resilient GitOps / ODF, golden-image fix-up, hub convergence, **Windows VM stabilization** (`REQUIRE_WINDOWS_VMS=1` by default), then DR validation bootstrap.

**Important bug fix:** any edit to upstream `pattern.sh` must run with `cd "$UPSTREAM_DIR"` so the correct file is patched.

## BYOC and fork customizations

Customizations are **not** copied from this repo into the upstream checkout. They live in the fork (`elsapassaro/ramendr-starter-kit`, branch `ocp-4.22`) under `overrides/` and values files; **hub Argo CD** reconciles from that remote branch.

- **`byoc: true`** — set in fork `overrides/values-cluster-names.yaml`; spokes are pre-provisioned with `openshift-install`.
- **`values-secret.yaml`** — user file (default `~/values-secret.yaml`); redeploy copies to `.work/values-secret.yaml` and merges fresh spoke kubeconfig paths before `install-byoc`.
- **Windows private images** — fork `externalDataSources` (e.g. `windows2k22`, `windows2k25`); requires `privatevm-credentials` (Quay robot) in `values-secret` for CDI registry import.
- **Mixed `gitops-vms` fleet** — 2× RHEL + 1× Windows Server 2022 + 1× Windows Server 2025 (DR-protected namespace).

## Install-config examples

- `**install-config-examples/`**: three `install-config.yaml.bak.example` files (placeholders for secrets). Real paths on user machine: e.g. `~/git/hub-cluster-install`, `~/git/ocp-primary-install`, `~/git/ocp-secondary-install`.

## Other scripts (this repo, not auto-injected into upstream clone)

- `scripts/cleanup-gitops-vms-non-primary.sh` — from user fork.
- `scripts/destroy-aws-resources.sh` — from user fork.
- `scripts/audit-aws-cost-and-tags.sh`, `scripts/test-rdr-install-config.sh` — utility scripts for AWS cost auditing and install-config validation.

## Security / secrets

- **Never** commit `values-secret.yaml`, kubeconfigs, pull secrets, or `.work/`.
- Upstream template link: `[values-secret.yaml.template](https://github.com/validatedpatterns/ramendr-starter-kit/blob/main/values-secret.yaml.template)`.
- Workspace rule: see repo `**CLAUDE.md`**.

## CI / QE context (discussion only; not all implemented)

- **Prow / OpenShift CI:** PR-centric; secrets via cluster profiles + Vault/bootstrap; artifacts often public for public repos; on-demand via Gangway; job types are presubmit/postsubmit/periodic even for “manual” triggers.
- **Virt QE private Jenkins:** good fit for **on-demand**, multi-hour **hub + 2 spokes**, private vendor images; must enforce teardown and artifacts discipline.
- **User direction:** second repo (this one) decouples automation from fork; **on-demand** runs preferred over PR-only CI for the heavy suite.
- **Future:** vendor **VSA** image on AWS; **non-ODF CSI** via profile-based installs.

## Project skill for Cursor

- `**.cursor/skills/ramendr-pattern-consumer/SKILL.md`** — condensed operational rules for this repo (`disable-model-invocation: true`; invoke by name when needed).

## Files to read first


| File                          | Purpose                                              |
| ----------------------------- | ---------------------------------------------------- |
| `README.md`                   | User-facing overview, install-config, fork pinning   |
| `CLAUDE.md`                   | Security + deployment contract, mixed fleet          |
| `scripts/redeploy.sh`         | Full orchestration                                   |
| `scripts/stabilize-windows-vms.sh` | Windows VM wait, stabilize, OpenSSH ensure      |
| `install-config-examples/`    | Example `install-config.yaml.bak` templates          |
