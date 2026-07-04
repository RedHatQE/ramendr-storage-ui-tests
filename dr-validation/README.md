# RamenDR data validation

Default mode (`DR_VALIDATION_MODE=hammerdb`) runs **HammerDB TPC-C** against
**PostgreSQL** on one DR-protected edge VM (`DR_VALIDATION_HAMMERDB_VM`, default
`rhel9-node-001`). Data files live under `/var/lib/ramendr-dr-validation/` on the
replicated VM disk. A continuous audit table (`dr_validation_audit`) plus TPC-C
row-count checks replace the legacy timestamp log for post-DR validation.

Set `DR_VALIDATION_MODE=timestamp` to use the original per-VM timestamp writer
(described below).

## HammerDB workflow (default)

1. **Deploy environment** — `./scripts/redeploy.sh` automatically installs PostgreSQL +
   HammerDB on `rhel9-node-001`, verifies TPC-C tables are populated, and saves an initial
   baseline snapshot to `.work/dr-validation-db/auto/latest` (unless `SKIP_DR_VALIDATION=1`).
2. **Before DR** — capture a fresh baseline immediately before Initiate (sanity test does
   this automatically; for manual runs use `./scripts/dr-validation/save-db-baseline-snapshot.sh`).
3. **Run DR** — failover / relocate on DRPC `gitops-vm-protection`.
4. **After DR** — sanity test or `./scripts/dr-validation/post-dr-automation.sh` validates
   PostgreSQL table data automatically.

A **PASS** means audit sequence continuity, no TPC-C row-count regression vs baseline,
and RPO within `DR_VALIDATION_MAX_RPO_SECONDS` (default `120` s).

| Path | Purpose |
|------|---------|
| `hammerdb/install-on-vm.sh` | PostgreSQL + HammerDB install on edge VM |
| `ramendr_dr_validation/db_audit.py` | Continuous audit inserts (systemd) |
| `ramendr_dr_validation/db_snapshot.py` | Export DB snapshot JSON |
| `ramendr_dr_validation/db_validator.py` | Gap/RPO/TPC-C validation |
| `scripts/dr-validation/install-hammerdb-incluster.sh` | In-cluster SSH install job |
| `scripts/dr-validation/collect-db-snapshot-incluster.sh` | In-cluster snapshot collect |
| `scripts/dr-validation/save-db-baseline-snapshot.sh` | Capture pre-DR DB baseline (updates `auto/latest`) |
| `scripts/dr-validation/check-after-dr-hammerdb.sh` | Post-DR HammerDB validation |

Future backends (e.g. SQL Server on Windows VMs) plug in under
`ramendr_dr_validation/backends/`.

Table reference: [`DATABASE-SCHEMA.md`](DATABASE-SCHEMA.md).

### In-cluster utility container (amd64)

DR validation Jobs (`install-hammerdb-incluster.sh`, `collect-db-snapshot-incluster.sh`,
etc.) use `DR_VALIDATION_UTILITY_CONTAINER_IMAGE` from `scripts/dr-validation/lib.sh`.
The default is the semver tag **`quay.io/validatedpatterns/utility-container:v1.0.4`** (amd64).

This test harness targets **amd64** hub and spoke workers (AWS `openshift-install` in
`eu-north-1` / `eu-central-1` / `eu-west-1`). Do not schedule these Jobs on arm64 nodes
unless you override the image to a multi-arch tag or add explicit `nodeSelector` for
`kubernetes.io/arch: amd64`.

---

## Legacy timestamp mode (`DR_VALIDATION_MODE=timestamp`)

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

1. **Deploy environment** — `./scripts/redeploy.sh` (four edge VMs in `gitops-vms`: 2 Linux + 1 Windows Server 2022 + 1 Windows Server 2025).
   Add `privatevm-credentials` (Quay robot) and `windows-admin` (`password` for local
   `Administrator` SSH on pre-configured Windows images) to `~/values-secret.yaml`.
   When redeploy finishes, it **automatically** waits for VMs, installs timestamp writers on
   each edge VM, verifies recording, and saves the first baseline snapshot
   (unless `SKIP_DR_VALIDATION=1`).
   Edge VMs need **cloud-init** from Vault: keep `disableExternalSecrets: false` in
   `overrides/values-egv-dr.yaml`, and include `ssh_pwauth: true` in `~/values-secret.yaml`
   `cloud-init` userData (see `examples/cloud-init-fragment.yaml`).
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
| `SSH_USER` | `cloud-user` | Linux VM SSH user (HammerDB / writer install); Windows guests use OpenSSH on port 22 |
| `DR_VALIDATION_EXPECTED_VMS` | `4` | Full fleet in gitops-vms for post-DR automation |
| `DR_VALIDATION_BOOTSTRAP_VM_COUNT` | `2` | Running Linux VMs required before HammerDB bootstrap |
| `DR_VALIDATION_BOOTSTRAP_VM_PATTERN` | `rhel` | Regular expression matched against bootstrap VM / SSH endpoint names during bootstrap wait |
| `DR_VALIDATION_UTILITY_CONTAINER_IMAGE` | `v1.0.4` in `lib.sh` | Utility container for in-cluster SSH Jobs; **amd64 only** on default AWS workers |
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
