# Agent handoff: RamenDR storage UI tests / pattern consumer

This document summarizes decisions and context from prior work so another agent can continue without re-reading the full thread.

## What this repository is

- **Consumer / test harness** for upstream [`elsapassaro/ramendr-starter-kit`](https://github.com/elsapassaro/ramendr-starter-kit), pinned by default to the **`windows_vms`** branch at commit **`2cefc177f797e77f227fd753aaf2bd939ca34f59`** (rebased on `ocp-4.22`).
- **Does not** long-term fork upstream. Local changes are **overlays** + **root `values-hub.yaml` replacement** + a small **patch** to upstream `pattern.sh`.
- **Future:** Playwright + Python UI tests (not implemented yet). **Today:** deployment scripts, overrides, install-config examples.

## Upstream pattern mechanics (high level)

- Validated Pattern uses **Helm values** (`values-*.yaml`) and **Argo CD** (`applications` in `values-hub.yaml` with sync policies, sync waves, etc.). Automation runs via `**pattern.sh`** + `**podman`** + utility container.
- User’s fork parity for **BYOC** and hub behavior is reproduced here without forking.

## Key entrypoint: `scripts/redeploy.sh`

1. Clones/fetches upstream into `**.work/upstream/ramendr-starter-kit`** (see `.gitignore`; not committed).
2. Checks out `**UPSTREAM_REF`** (default `v1.1`). Override: `UPSTREAM_REPO`, `UPSTREAM_REF`, `WORK_DIR`, `UPSTREAM_DIR`, `UPSTREAM_OVERRIDES_DIR`.
3. Copies `**overrides/*.yaml`** → upstream `overrides/`.
4. Copies `**upstream-overrides/values-hub.yaml**` → upstream **root** `values-hub.yaml` when that file exists (fork-style hub: ODF channels `stable-4.20`, regional-dr `extraValueFiles` includes `values-aws-cost-optimized.yaml`, etc.).
5. Patches upstream `**pattern.sh`** **from inside `$UPSTREAM_DIR`** so `podman` uses `-i` when no TTY (upstream uses `podman run -it` which fails in CI when stdin/stdout are not a terminal).
6. Provisions **hub + two spokes** via `openshift-install` using directories `**HUB_INSTALL_DIR`**, `**PRIMARY_INSTALL_DIR`**, `**SECONDARY_INSTALL_DIR**` (each needs `**install-config.yaml.bak**`).
7. Runs `**./pattern.sh make install**` from the upstream checkout with `**VALUES_SECRET**` (default `~/values-secret.yaml`).

**Important bug fix:** any edit to upstream `pattern.sh` must run with `cd "$UPSTREAM_DIR"` so the correct file is patched.

## BYOC and overrides

- `**overrides/values-cluster-names.yaml`**: `byoc: true`, cluster names, regions (`eu-central-1` / `eu-west-1` for spokes), `drpc.preferredCluster`, optional `**costManagement`** placeholders (`<OWNER_TAG>`, etc.) — replace before real runs.
- `**overrides/values-aws-cost-optimized.yaml**`: currently mostly **comments** documenting that in BYOC, spoke machine types come from `**install-config.yaml.bak`**, not from Hive-driven `install_config` in that overlay. A full overlay with `clusterOverrides.install_config` can be useful for non-BYOC or for `costManagement`; merging that blindly can confuse operators who expect values to provision spokes.

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


| File                                 | Purpose                                                                 |
| ------------------------------------ | ----------------------------------------------------------------------- |
| `README.md`                          | User-facing overview, install-config copy commands, fork parity section |
| `CLAUDE.md`                          | Security + deployment contract                                          |
| `scripts/redeploy.sh`                | Full orchestration                                                      |
| `upstream-overrides/values-hub.yaml` | Fork-style hub vs upstream v1.1                                         |
| `overrides/`                         | BYOC + DR/console/ODF tuning                                            |
