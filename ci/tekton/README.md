# OpenShift Pipelines (Tekton) — RamenDR ODF CI

On-demand e2e for the **ODF** variant on AWS:

**destroy → install → pattern-prepare → install-byoc → pattern-finalize → Playwright/pytest**,
with **teardown as a separate Pipeline**.

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
    ramendr-odf-e2e.yaml    # destroy → install → pattern → smoke → sanity
    ramendr-odf-deploy.yaml # same deploy stages, no pytest
    ramendr-teardown.yaml   # destroy-only
  examples/
    pvc-ramendr-ci-data.yaml     # shared RWO PVC (apply once)
    pipelinerun-odf.yaml         # full ODF e2e PipelineRun (create)
    pipelinerun-odf-deploy.yaml  # deploy-only PipelineRun
    pipelinerun-odf-reuse.yaml   # skip destroy/install on existing env
    pipelinerun-teardown.yaml    # destroy-only PipelineRun
    serviceaccount.yaml
  secrets/
    README.md               # Vault → ESO → Secret → mount contract
    externalsecrets.example.yaml
```

## Prerequisites (management cluster)

1. **OpenShift Pipelines** (Tekton) installed.
2. CI image built from [Containerfile](Containerfile) (or equivalent) containing: `oc`,
   `openshift-install`, `aws`, `podman` (optional for local nested pattern.sh), `git`,
   `python3` (+ pytest/playwright), `virtctl`, `jq`, `curl`.
3. Access to **`quay.io/validatedpatterns/utility-container`** for the `install-byoc` Task
   (no privileged SCC required for pattern install).
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

| Stage | Flag | Image | Purpose |
|---|---|---|---|
| destroy | `--destroy-only` | QE CI | Tear down AWS clusters (hosted zone kept) |
| install | `--install-only` | QE CI | Hub + 2 spokes via `openshift-install` |
| pattern-prepare | `--pattern-prepare` | QE CI | Upstream checkout, metal/workers, BYOC values-secret |
| install-byoc | `--install-byoc` | **utility-container** | `pattern.sh make install-byoc` (no nested podman) |
| pattern-finalize | `--pattern-finalize` | QE CI | GitOps follow-up + Windows + HammerDB/DR bootstrap |
| smoke-tests | `pytest tests/ui/smoke …` | QE CI | UI + infra smoke (`base-domain` required for Playwright) |
| sanity-tests | `pytest tests/ui/sanity …` | QE CI | DR UI failover/relocate (after smoke) |

`install-byoc` uses `quay.io/validatedpatterns/utility-container` so Tekton does **not**
need a privileged SCC: upstream `pattern.sh` detects Kubernetes and runs `make` in-process.

Local equivalent:

```bash
export CI=1
export WORK_DIR=/workspace/data/.work
export HUB_INSTALL_DIR=/workspace/data/install/hub
# …
./scripts/redeploy.sh --ci --destroy-only
./scripts/redeploy.sh --ci --install-only
./scripts/redeploy.sh --ci --pattern-prepare
./scripts/redeploy.sh --ci --install-byoc      # or use utility-container as the Task image
./scripts/redeploy.sh --ci --pattern-finalize
export BASE_DOMAIN=example.devcluster.openshift.com
python3 -m pytest tests/ui/smoke -v
python3 -m pytest tests/ui/sanity -v
```

`--pattern-only` still runs prepare + install-byoc + finalize in one shot (local/default).

Smoke- or sanity-only TaskRuns (reuse PVC after finalize):

```bash
kubectl apply -n "$NS" -f ci/tekton/tasks/run-pytest.yaml
kubectl create -n "$NS" -f ci/tekton/examples/taskrun-pytest-smoke.yaml
kubectl create -n "$NS" -f ci/tekton/examples/taskrun-pytest-sanity.yaml
```

## Apply

```bash
NS=ramendr-ci   # pipeline namespace

kubectl apply -n "$NS" -f ci/tekton/tasks/
kubectl apply -n "$NS" -f ci/tekton/pipelines/
kubectl apply -n "$NS" -f ci/tekton/examples/serviceaccount.yaml

# Shared PVC once, then create PipelineRuns (generateName — do not kubectl apply them).
kubectl apply -n "$NS" -f ci/tekton/examples/pvc-ramendr-ci-data.yaml
# One Secret for console Start (see secrets/externalsecrets.example.yaml)
# Edit BASE_DOMAIN / HOSTED_ZONE_ID / image in the example, then:
kubectl create -n "$NS" -f ci/tekton/examples/pipelinerun-odf.yaml

# Deploy only (no smoke/sanity):
# kubectl create -n "$NS" -f ci/tekton/examples/pipelinerun-odf-deploy.yaml
# Reuse existing clusters (skip destroy/install):
# kubectl create -n "$NS" -f ci/tekton/examples/pipelinerun-odf-reuse.yaml
```

Teardown (separate). Workspace **data** must be PVC `ramendr-ci-data` (same as e2e;
install metadata lives there). Console Start: data=`ramendr-ci-data`, secrets=`ramendr-ci-secrets`.

```bash
kubectl apply -n "$NS" -f ci/tekton/pipelines/ramendr-teardown.yaml
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
| `pytest-args-smoke` | smoke + junit path | Override smoke suite |
| `pytest-args-sanity` | sanity + junit path | Override sanity suite |
| `image` | placeholder | QE CI image (destroy/install/prepare/finalize/tests) |
| `utility-image` | `utility-container:v1.0.5` | Image for `--install-byoc` only |
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

See [examples/pipelinerun-odf-reuse.yaml](examples/pipelinerun-odf-reuse.yaml) for a
reuse-oriented PipelineRun example.

## Artifacts and secrets

- JUnit XML: `/workspace/data/artifacts/` on the PVC (copy out with a follow-up Task or `oc cp`).
- `pattern-finalize` stdout/stderr is also teed to `/workspace/data/artifacts/pattern-finalize.log`
  (survives TaskRun pod deletion / timeout when Tekton Results has no step logs).
- **Do not** archive kubeconfigs or `values-secret.yaml` to public artifact stores.
- Hub kubeconfig for tests: `/workspace/data/install/hub/auth/kubeconfig` after install.

## Timeouts

Pipeline defaults in examples: **16h** (e2e with sanity) / **12h** (deploy-only).
Per-Task timeouts are set on destroy (2h), install (4h), pattern-prepare (1h),
install-byoc (2h), pattern-finalize (4h — Windows OS-disk + HammerDB; healthy runs
finish sooner), smoke-tests (1h), sanity-tests (6h).
