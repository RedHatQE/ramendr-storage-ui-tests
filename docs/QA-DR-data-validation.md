# QA: RamenDR data validation (Jira-ready)

## What runs automatically (no manual steps)

| When | What |
|------|------|
| After `./scripts/redeploy.sh` | **HammerDB** (default): TPC-C **schema** on every edge VM; writers stay stopped. Sanity starts OLTP after DRPC Healthy and stops it on teardown. For manual DR: `start-hammerdb-load-incluster.sh`, then `status-hammerdb.sh` (fresh audit on every VM), then `save-db-baseline-snapshot.sh` (sanity does this automatically). Legacy: timestamp writers every **10 s** + rolling log snapshots every **5 min** when `DR_VALIDATION_MODE=timestamp`. |
| After DR + UI cleanup message | Run **one** automation script (see below) |

---

## DR test in the console

1. Open the hub console URL from redeploy output.
2. Run **Failover** or **Relocate** on **gitops-vm-protection** (`openshift-dr-ops`).
3. Wait until the UI shows the **cleanup** message / step.

---

## After DR — one command (Playwright / CI / anyone)

From repo root (hub `KUBECONFIG`, SSH key for VMs):

```bash
cd ramendr-storage-ui-tests
export KUBECONFIG=~/git/hub-cluster-install/auth/kubeconfig

./scripts/dr-validation/post-dr-automation.sh
```

This runs **automatically**, in order:

1. **Workload cleanup** on the non-primary (failed-over-from) cluster only, with DRPC
   safety guards and no confirmation prompt. It runs with `--skip-pvcs`, so the VMs/VMIs
   are removed while the demoted DataVolumes/PVCs stay in place for a fast relocate.
   Set `CLEANUP_STUCK_PVCS=1` to also delete PVCs left stuck by the failover
   (`--cleanup-stuck-pvcs`). A full wipe is a teardown action, not a post-DR one.
2. **Wait** until edge VMs are **Running** on the new primary.
3. **Validate** HammerDB PostgreSQL data (default) or timestamp logs (`DR_VALIDATION_MODE=timestamp`) and print **PASS/FAIL**.

You do **not** run `cleanup-gitops-vms-non-primary.sh` or `check-after-dr.sh` separately unless debugging.

### Playwright / sanity test

The UI sanity test (`tests/ui/sanity/test_sanity.py`) starts HammerDB writers after
DRPC is Healthy, then runs DR validation automatically after each DR phase (healthy on
the new primary):

1. After **failover** to `ocp-secondary` — `./scripts/dr-validation/check-after-dr.sh`
2. After **relocate** back to `ocp-primary` — same check again

Set `RAMENDR_SANITY_SKIP_DR_VALIDATION=1` (or `SKIP_DR_VALIDATION=1`) to skip.

The failover wait is DRPC-aware: after the UI reads `FailedOver` the test polls the
DRPC progression and runs the non-primary cleanup **once**, when Ramen first reports
`WaitOnUserToCleanUp` (the source workload must be released before the target VMs can
start — otherwise the old 30-minute VM wait deadlocked). No new volumes are created
during a failover, so the cleanup is not repeated on a timer. If Ramen is still in
that state `RAMENDR_SANITY_STUCK_PVC_NO_PROGRESS_SECONDS` (default 300) later, the
test checks the script's stuck-PVC classification once and, when it returns claims,
runs the cleanup a second time with `--cleanup-stuck-pvcs`. It stops after
`RAMENDR_SANITY_FAILOVER_CLEANUP_TIMEOUT_SECONDS` (default 900) and fails with the
progression plus the source-VM list.

During the post-failover/relocate healthy wait the test also runs the one-shot
stuck-PVC escalation: if the failed-over-from spoke has **no VMs and no
virt-launcher pods**, the DRPC has shown no progress for
`RAMENDR_SANITY_STUCK_PVC_NO_PROGRESS_SECONDS` (default 300), and
`cleanup-gitops-vms-non-primary.sh --list-stuck-pvcs` classifies at least one claim
as stuck, the test logs those PVC names and runs the cleanup once with
`--skip-pvcs --cleanup-stuck-pvcs`, then keeps waiting. The classification is the
script's own (Terminating claims, or unprotected group members whose
`VolumeGroupReplication` is gone, never a pod-mounted claim). Disable with
`RAMENDR_SANITY_STUCK_PVC_FALLBACK=0`.

RTO is measured from the UI Initiate click until all edge VMs pass an in-cluster SSH probe.
Defaults: warn at `RAMENDR_SANITY_RTO_WARN_SECONDS=900`, fail above `RAMENDR_SANITY_MAX_RTO_SECONDS=1200`.

For manual or one-off runs after the UI cleanup step:

```bash
./scripts/dr-validation/post-dr-automation.sh
```

Assert exit code `0` for PASS.

---

## Cleanup safety (built-in)

`cleanup-gitops-vms-non-primary.sh` now checks before deleting:

- DRPC exists
- DR progression is not mid-failover (e.g. not `FailingOver` / `Relocating`)
- **PlacementDecision** shows the current primary (unless `--force`)

Safe progressions include: `Completed`, `Deployed`, `Cleaning Up`, `WaitForUserToCleanUp`, etc.

**Timestamp logs on the live primary are not affected** when guards pass.

The script has two modes, and they differ in what they do with storage:

| Mode | Use | Deletes | Preserves |
|------|-----|---------|-----------|
| default | post-DR / teardown | VMs, VMIs, Services, Routes, ExternalSecrets, DataVolumes, **all PVCs**, orphan PVs | nothing in `gitops-vms` |
| `--skip-pvcs` | in-flight failover/relocate | VMs (`--cascade=orphan`), VMIs, Services, Routes, ExternalSecrets; unmanaged leftover PVCs + their PVs | **DataVolumes and PVCs** (orphaned by the VM delete) |

During a failover the user is expected to remove the **workload** from the cluster
being failed over from — for KubeVirt, the VM/VMIs must stop so the PVC is released
(`Secondary transition failed as PVC is potentially in use by a pod` clears, and the
DRPC leaves `WaitOnUserToCleanUp`). The PVCs/DataVolumes are protected data, not
garbage: Ramen demotes them to secondary, so the script must not delete them.

Kubernetes GC cascades `VirtualMachine -> DataVolume -> PVC` through
`ownerReferences`, so a plain VM delete destroys the protected replica. With
`--skip-pvcs` the script deletes each VM with **`--cascade=orphan`** — GC drops the
`ownerReferences` on the VMI and the `dataVolumeTemplates` DataVolumes in the same
operation — and then deletes the VMI explicitly so the virt-launcher pod stops and
the PVC is released. (Patching the DataVolume `ownerReferences` beforehand is not
used: the VM controller re-applies them, which is a race we have lost in practice.)
It also clears unmanaged leftovers — `additionalPvcDisks` PVCs that no
DataVolume/VirtualMachine owns, no pod mounts and no VGR/Ramen/CDI finalizer
protects — which can otherwise hold `WaitOnUserToCleanUp`.

### PVCs left on the failed-over-from cluster (ODF known issue)

Some PVCs can remain on the primary cluster after a failover and block the next DR
action (`oc delete pvc <name> -n gitops-vms` in the ODF documentation). Add
`--cleanup-stuck-pvcs` to `--skip-pvcs` to delete them:

- claims already stuck in `Terminating` **that are no longer members of a live
  `VolumeGroupReplication`**, and
- DR group claims (`ramendr.openshift.io/consistency-group` label) whose
  `VolumeGroupReplication` no longer exists and that no pod mounts.

A `Terminating` claim that still belongs to a live VGR is mid-demotion, not stuck,
and is never selected.

Ramen/CDI finalizers are cleared when needed. The script never touches claims that
a pod still mounts, or live members of an existing `VolumeGroupReplication`; do not
run this while a demotion is still settling.

```bash
# in-flight failover/relocate cleanup (workload only, storage preserved)
./scripts/cleanup-gitops-vms-non-primary.sh --yes --skip-pvcs

# same, plus delete PVCs left stuck by a completed failover
./scripts/cleanup-gitops-vms-non-primary.sh --yes --skip-pvcs --cleanup-stuck-pvcs

# full wipe after the DR action is complete (VMs + DataVolumes + all PVCs + PVs)
./scripts/cleanup-gitops-vms-non-primary.sh --yes
```

---

## Optional / debugging

| Task | Command |
|------|---------|
| Cleanup only (interactive, full wipe) | `./scripts/cleanup-gitops-vms-non-primary.sh` |
| Cleanup only (automation, full wipe) | `./scripts/cleanup-gitops-vms-non-primary.sh --yes` |
| Cleanup during failover/relocate | `./scripts/cleanup-gitops-vms-non-primary.sh --yes --skip-pvcs` |
| Cleanup stuck PVCs after failover | `./scripts/cleanup-gitops-vms-non-primary.sh --yes --skip-pvcs --cleanup-stuck-pvcs` |
| Data check only | `./scripts/dr-validation/check-after-dr.sh` |
| Writer status (schema present) | `./scripts/dr-validation/status.sh` |
| OLTP recording (audit fresh) | `./scripts/dr-validation/status-hammerdb.sh` |
| Start HammerDB writers | `./scripts/dr-validation/start-hammerdb-load-incluster.sh` |
| Stop HammerDB writers | `./scripts/dr-validation/stop-hammerdb-load-incluster.sh` |

---

## Jira evidence

- Attach terminal output from `post-dr-automation.sh`, or
- Folder `.work/dr-validation-logs/checks/<timestamp>/` (created by step 3 inside the script)
- Paste into **your** test ticket manually (no automatic Jira integration)

---

## Checklist

- [ ] Redeploy done; HammerDB schema present (writers stopped until sanity / start-load)
- [ ] Sanity started OLTP after Healthy (or ran `start-hammerdb-load-incluster.sh`)
- [ ] DR completed in UI; cleanup message shown
- [ ] Ran `./scripts/dr-validation/post-dr-automation.sh` → **PASS**
- [ ] Attached output or report folder to ticket if needed
