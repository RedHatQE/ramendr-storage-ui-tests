# OpenShift Pipelines (Tekton) — RamenDR ODF CI

On-demand e2e for the **ODF** variant on AWS:

**destroy → install → pattern → Playwright/pytest**, with **teardown as a separate Pipeline**.

Future vendor / partner pipelines reuse the same Tasks with `skip-destroy=true` and
`skip-install=true` against an existing environment.

## Layout

```text
ci/tekton/
  README.md                 # this file
  Containerfile             # QE CI image (oc, install, aws, podman, pytest, virtctl)
  tasks/
    redeploy-stage.yaml     # scripts/redeploy.sh --ci <stage>
    run-pytest.yaml         # pytest / Playwright
  pipelines/
    ramendr-odf-e2e.yaml    # destroy → install → pattern → tests
    ramendr-teardown.yaml   # destroy-only
  examples/
    pipelinerun-odf.yaml    # PVC + full ODF PipelineRun
    pipelinerun-teardown.yaml
    serviceaccount.yaml
  secrets/
    README.md               # Vault → ESO → Secret → mount contract
    externalsecrets.example.yaml
```

## Prerequisites (management cluster)

1. **OpenShift Pipelines** (Tekton) installed.
2. A **privileged-capable** Task image (or SCC) so `pattern.sh` / **podman** can run
   (nested containers). Confirm with your platform team before first run.
3. CI image built from [Containerfile](Containerfile) (or equivalent) containing: `oc`,
   `openshift-install`, `aws`, `podman`, `git`, `python3` (+ pytest/playwright),
   `virtctl`, `jq`, `curl`.
4. RWO PVC large enough for three install dirs + upstream clone (example: 100Gi).
5. Secrets synced from Vault via External Secrets — see [secrets/README.md](secrets/README.md).

## Build the CI image

From the **repository root** (context must include `requirements.txt`):

```bash
IMAGE=quay.io/<org>/ramendr-ci:$(date +%Y-%m-%d)

podman build -f ci/tekton/Containerfile -t "$IMAGE" .
podman push "$IMAGE"
```

Optional build-args: `OCP_VERSION` (default `4.22.1`), `VIRTCTL_VERSION` (default
`v1.5.0`), `PYTHON_PKG` (default `python3.12`; UBI’s system `python3` is 3.9 and
cannot install `pytest>=9`), `BASE_IMAGE`. Point PipelineRun `params.image` at the
pushed tag. If the registry is private, link a pull secret to `ramendr-ci-pipeline`.

## Redeploy stages used by Tasks

| Stage | Flag | Purpose |
|---|---|---|
| destroy | `--destroy-only` | Tear down AWS clusters (hosted zone kept) |
| install | `--install-only` | Hub + 2 spokes via `openshift-install` |
| pattern | `--pattern-only` | BYOC pattern + DR bootstrap + Windows + HammerDB schema |
| tests | `pytest …` | UI smoke (sanity optional via `pytest-args`) |

Local equivalent:

```bash
export CI=1
export WORK_DIR=/workspace/data/.work
export HUB_INSTALL_DIR=/workspace/data/install/hub
# …
./scripts/redeploy.sh --ci --destroy-only
./scripts/redeploy.sh --ci --install-only
./scripts/redeploy.sh --ci --pattern-only
python3 -m pytest tests/ui/smoke -v
```

## Apply

```bash
NS=ramendr-ci   # pipeline namespace

kubectl apply -n "$NS" -f ci/tekton/tasks/
kubectl apply -n "$NS" -f ci/tekton/pipelines/
kubectl apply -n "$NS" -f ci/tekton/examples/serviceaccount.yaml

# Create Secrets (or apply ExternalSecrets from secrets/externalsecrets.example.yaml)
# then:
kubectl apply -n "$NS" -f ci/tekton/examples/pipelinerun-odf.yaml
# Edit BASE_DOMAIN / HOSTED_ZONE_ID / image first — or use:
# kubectl create -n "$NS" -f ci/tekton/examples/pipelinerun-odf.yaml
```

Teardown (separate):

```bash
kubectl create -n "$NS" -f ci/tekton/examples/pipelinerun-teardown.yaml
```

## Params

| Param | Default | Notes |
|---|---|---|
| `pattern-variant` | `odf` | Also `drpartner-s4` / `drpartner-minimal` later |
| `skip-destroy` | `false` | `true` to reuse clusters |
| `skip-install` | `false` | `true` to reuse clusters |
| `base-domain` | (required) | Cluster base domain |
| `hosted-zone-id` | (required) | Route53 zone (never deleted by redeploy) |
| `pytest-args` | smoke + junit path | Override for sanity |
| `image` | placeholder | Your QE CI image |
| `git-revision` | `main` | Branch or tag of this repo |

## Reuse existing env (future vendors)

```yaml
params:
  - name: skip-destroy
    value: "true"
  - name: skip-install
    value: "true"
  - name: pattern-variant
    value: drpartner-s4   # example
```

See [examples/pipelinerun-teardown.yaml](examples/pipelinerun-teardown.yaml) for a
reuse-oriented PipelineRun stub.

## Artifacts and secrets

- JUnit XML: `/workspace/data/artifacts/` on the PVC (copy out with a follow-up Task or `oc cp`).
- **Do not** archive kubeconfigs or `values-secret.yaml` to public artifact stores.
- Hub kubeconfig for tests: `/workspace/data/install/hub/auth/kubeconfig` after install.

## Timeouts

Pipeline default in examples: **12h** (install + pattern dominate). Per-Task timeouts are
set on destroy (2h), install (4h), pattern (4h), tests (2h).
