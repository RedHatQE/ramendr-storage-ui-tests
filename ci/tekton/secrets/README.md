# Secrets contract (Vault → External Secrets → Tekton)

Never put secret values in Pipeline / PipelineRun params or git. Inject via
Kubernetes Secrets synced from Vault (or your secret store) with External
Secrets Operator (ESO), then project those Secrets into the Task `secrets`
workspace.

```text
Vault (or secret store)
        │
        ▼
ExternalSecret (management cluster, pipeline namespace)
        │
        ▼
K8s Secret(s)
        │
        ▼
PipelineRun workspaces.secrets (projected volume)
        │
        ▼
Task mounts at /workspace/secrets/...
```

## Required Secrets

| K8s Secret | Keys | Mounted as |
|---|---|---|
| `ramendr-values-secret` | `values-secret.yaml` | `/workspace/secrets/values-secret.yaml` |
| `ramendr-aws-creds` | `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_DEFAULT_REGION` | `/workspace/secrets/aws/<key>` |
| `ramendr-install-configs` | `hub-install-config.yaml.bak`, `primary-install-config.yaml.bak`, `secondary-install-config.yaml.bak` | `/workspace/secrets/install/{hub,primary,secondary}/install-config.yaml.bak` |

Optional:

| Secret | Purpose |
|---|---|
| `ramendr-pull-secret` | If you compose install-config in CI instead of storing full `.bak` files |
| `ramendr-git-auth` | Only if cloning a private fork (prefer public repo pin) |

## `values-secret.yaml` contents (ODF)

Must be a valid pattern `VALUES_SECRET` (v2). For Windows edge VMs include at least:

- `privatevm-credentials` (Quay robot `accessKeyId` / `secretKey`)
- `windows-admin` (`password`)
- optional `mssql-hammerdb` (or set `DR_VALIDATION_MSSQL_*` env in the Task)

See [dr-validation/examples/values-secret-v2-windows.fragment.yaml](../../dr-validation/examples/values-secret-v2-windows.fragment.yaml).
Spoke kubeconfig paths are **not** required in the source file — `redeploy.sh`
merges them into `$WORK_DIR/values-secret.yaml` after install.

## Projected workspace layout

PipelineRun examples project the three Secrets into one read-only workspace:

```text
/workspace/secrets/
  values-secret.yaml
  aws/
    AWS_ACCESS_KEY_ID
    AWS_SECRET_ACCESS_KEY
    AWS_DEFAULT_REGION
  install/
    hub/install-config.yaml.bak
    primary/install-config.yaml.bak
    secondary/install-config.yaml.bak
```

The `ramendr-redeploy-stage` Task copies `install/*/install-config.yaml.bak`
onto the data PVC and exports AWS credentials from `secrets/aws/`.

## Rules

1. PipelineServiceAccount may `get`/`use` these Secrets only in the pipeline namespace.
2. Prefer **file mounts** for YAML blobs; never pass tokens as Pipeline params.
3. Do not upload kubeconfigs or `values-secret.yaml` as Tekton Results or public artifacts.
4. Hub console / `kubeadmin` for Playwright comes from
   `/workspace/data/install/hub/auth/` on the PVC after `--install-only`, not from Vault.
5. Rotate in Vault; ESO refreshes K8s Secrets; new PipelineRuns pick up mounts automatically.
6. Template ExternalSecrets: [externalsecrets.example.yaml](externalsecrets.example.yaml).

## Manual bootstrap (without ESO)

```bash
kubectl -n <pipeline-ns> create secret generic ramendr-values-secret \
  --from-file=values-secret.yaml=$HOME/values-secret.yaml

kubectl -n <pipeline-ns> create secret generic ramendr-aws-creds \
  --from-literal=AWS_ACCESS_KEY_ID=... \
  --from-literal=AWS_SECRET_ACCESS_KEY=... \
  --from-literal=AWS_DEFAULT_REGION=eu-north-1

kubectl -n <pipeline-ns> create secret generic ramendr-install-configs \
  --from-file=hub-install-config.yaml.bak=$HOME/git/hub-cluster-install/install-config.yaml.bak \
  --from-file=primary-install-config.yaml.bak=$HOME/git/ocp-primary-install/install-config.yaml.bak \
  --from-file=secondary-install-config.yaml.bak=$HOME/git/ocp-secondary-install/install-config.yaml.bak
```
