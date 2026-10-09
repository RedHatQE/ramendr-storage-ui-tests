# Secrets contract (Vault → External Secrets → Tekton)

Never put secret values in Pipeline / PipelineRun params or git. Inject via
Kubernetes Secrets synced from Vault with External Secrets Operator (ESO), then
mount **one** Secret as the Task `secrets` workspace (OpenShift console Start).

```text
Vault
        │
        ▼
ExternalSecret ramendr-ci-secrets
        │
        ▼
K8s Secret ramendr-ci-secrets
        │
        ▼
PipelineRun workspace secrets (type: Secret)
        │
        ▼
/workspace/secrets/<flat keys>
```

A Pipeline **cannot** attach Secrets by default. Only a PipelineRun (or console
Start / Rerun) binds workspaces. One Secret is what the Start form supports.

## Required Secret (UI)

| K8s Secret | Keys | Mounted as |
|---|---|---|
| `ramendr-ci-secrets` | `values-secret.yaml` | `/workspace/secrets/values-secret.yaml` |
| | `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` | `/workspace/secrets/<key>` |
| | optional `AWS_DEFAULT_REGION` or `credentials` | same |
| | `hub-install-config.yaml.bak`, `primary-…`, `secondary-…` | `/workspace/secrets/<key>` |

K8s Secret keys cannot contain `/`, so install-configs stay **flat** (not
`install/hub/...`). The redeploy Task copies those files onto the data PVC.

Template: [externalsecrets.example.yaml](externalsecrets.example.yaml).

The three older Secrets (`ramendr-values-secret`, `ramendr-aws-creds`,
`ramendr-install-configs`) still work if you mount them with a **projected**
volume (YAML PipelineRun). Prefer `ramendr-ci-secrets` for console Start.

## `values-secret.yaml` contents (ODF)

Must be a valid pattern `VALUES_SECRET` (v2). For Windows edge VMs include at least:

- `privatevm-credentials` (Quay robot `accessKeyId` / `secretKey`)
- `windows-admin` (`password`)
- optional `mssql-hammerdb` (or set `DR_VALIDATION_MSSQL_*` env in the Task)

See [dr-validation/examples/values-secret-v2-windows.fragment.yaml](../../dr-validation/examples/values-secret-v2-windows.fragment.yaml).
Spoke kubeconfig paths are **not** required in the source file — `redeploy.sh`
merges them into `$WORK_DIR/values-secret.yaml` after install.

## Console Start

1. Workspace **data** → PVC `ramendr-ci-data`
2. Workspace **secrets** → Secret `ramendr-ci-secrets`. Leave **Items** empty
   (mount the whole Secret). Mapping items is optional and only needed to
   rename keys; a wrong mapping hides `AWS_*` files.
3. ServiceAccount: the Start form often **omits** this. OpenShift then uses
   `pipeline`. Bind that SA (see `examples/serviceaccount.yaml`). Optional:
   expand **Show credential options** / **Advanced options** if your console
   version has it.

## Rules

1. PipelineServiceAccount may `get`/`use` these Secrets only in the pipeline namespace.
2. Prefer **file mounts** for YAML blobs; never pass tokens as Pipeline params.
3. Do not upload kubeconfigs or `values-secret.yaml` as Tekton Results or public artifacts.
4. Hub console / `kubeadmin` for Playwright comes from
   `/workspace/data/install/hub/auth/` on the PVC after `--install-only`, not from Vault.
5. Rotate in Vault; ESO refreshes the K8s Secret; new PipelineRuns pick up mounts automatically.

## Manual bootstrap (without ESO)

```bash
kubectl -n <pipeline-ns> create secret generic ramendr-ci-secrets \
  --from-file=values-secret.yaml=$HOME/values-secret.yaml \
  --from-literal=AWS_ACCESS_KEY_ID=... \
  --from-literal=AWS_SECRET_ACCESS_KEY=... \
  --from-file=hub-install-config.yaml.bak=$HOME/git/hub-cluster-install/install-config.yaml.bak \
  --from-file=primary-install-config.yaml.bak=$HOME/git/ocp-primary-install/install-config.yaml.bak \
  --from-file=secondary-install-config.yaml.bak=$HOME/git/ocp-secondary-install/install-config.yaml.bak
```
