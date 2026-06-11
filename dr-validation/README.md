# RamenDR data validation (continuous timestamps)

Validates that data on DR-protected VM disks stays continuous across failover by appending
sequence + UTC timestamp records to a log on each edge VM, then checking for gaps after DR.

## Log format

Each line is CSV (no header):

```text
<seq>,<iso8601-utc>,<hostname>,<pid>
```

Example:

```text
42,2026-05-17T14:03:01.123Z,edgenode-0,1842
```

The log lives on the VM root disk (`/var/lib/ramendr-dr-validation/timestamps.log`), which is
replicated with the protected KubeVirt workload.

## Workflow

1. **Deploy environment** — `./scripts/redeploy.sh` (four `edgenode` RHEL VMs in `gitops-vms`).
   When redeploy finishes, it **automatically** waits for VMs, installs the timestamp writer on
   each edge VM, and verifies recording (unless `SKIP_DR_VALIDATION=1`).
   Edge VMs need **cloud-init** from Vault: keep `disableExternalSecrets: false` in
   `overrides/values-egv-dr.yaml`, and include `ssh_pwauth: true` in `~/values-secret.yaml`
   `cloud-init` userData (see `examples/cloud-init-fragment.yaml`).
2. **Optional manual install** — if bootstrap was skipped or failed:

   ```bash
   export KUBECONFIG=~/git/hub-cluster-install/auth/kubeconfig
   ./scripts/dr-validation/bootstrap.sh
   ```

3. **Automatic baseline** — a daemon saves logs every 5 minutes to
   `.work/dr-validation-logs/auto/latest` (started by redeploy).
4. **Run DR** — failover / relocate / failback via console (DRPC `gitops-vm-protection`).
5. **After DR (one command)**:

   ```bash
   ./scripts/dr-validation/check-after-dr.sh
   ```

A **PASS** means no missing sequence numbers, no parse errors, and no RPO threshold breach.
Sequence gaps imply lost writes (RPO breach); the checker estimates an upper bound as
`gap * interval` seconds and fails when that estimate is greater than `DR_VALIDATION_MAX_RPO_SECONDS`
(default `120` seconds / 2 minutes, aligned with the `2m-vm` DRPolicy).

## Components

| Path | Purpose |
|------|---------|
| `ramendr_dr_validation/writer.py` | Append-only writer (systemd or manual) |
| `ramendr_dr_validation/validator.py` | Gap detection and optional before/after compare |
| `systemd/ramendr-dr-writer.service` | Run writer on boot |
| `examples/cloud-init-fragment.yaml` | Optional Vault `cloud-init` merge |
| `scripts/dr-validation/bootstrap.sh` | Wait for VMs, install writers, verify (also run by redeploy) |
| `scripts/dr-validation/*.sh` | Install, collect, validate, status |

## Environment variables

| Variable | Default | Description |
|----------|---------|-------------|
| `SSH_USER` | `cloud-user` | VM SSH user |
| `SSH_IDENTITY_FILE` | `~/.ssh/id_rsa` | Private key for direct/laptop SSH (`install-writer.sh`, non-in-cluster collect) |
| `DR_VALIDATION_SSH_PASSWORD` | (from Vault) | Password for in-cluster install/collect Jobs (private keys are not copied to spokes) |
| `DR_VALIDATION_INCLUSTER_COLLECT` | `1` | Use in-cluster collect Job (password required on spoke) |
| `DR_VALIDATION_STATUS_MAX_AGE_SEC` | `300` | Max log age for `status.sh` freshness check |
| `DR_VALIDATION_LOG_PATH` | `/var/lib/ramendr-dr-validation/timestamps.log` | Log on VM |
| `DR_VALIDATION_INTERVAL` | `10.0` | Seconds between records |
| `DR_VALIDATION_MAX_RPO_SECONDS` | `120` | Fail check when estimated RPO (`max_seq_gap * interval`) exceeds this threshold |
| `RAMENDR_SANITY_MAX_RTO_SECONDS` | `1200` | UI sanity test: fail when measured failover/relocate RTO exceeds this limit |
| `RAMENDR_SANITY_RTO_WARN_SECONDS` | `900` | UI sanity test: log a warning when RTO exceeds this threshold (still below hard limit) |
| `DR_VALIDATION_SNAPSHOT_KEEP` | `1` | Auto-snapshot dirs to retain (latest only; `latest` symlink always points at current baseline) |
| `SKIP_DR_VALIDATION` | `0` | Set `1` in redeploy to skip automatic writer setup |
| `REQUIRE_DR_VALIDATION` | `0` | Set `1` to fail redeploy if writers are not recording |
| `HUB_INSTALL_DIR` | `~/git/hub-cluster-install` | Hub kubeconfig for DRPC lookup |
| `PRIMARY_INSTALL_DIR` / `SECONDARY_INSTALL_DIR` | `~/git/ocp-*-install` | Spoke kubeconfigs |

## Unit tests

```bash
python3 -m pytest tests/dr_validation -q
```

No cluster required for validator unit tests.
