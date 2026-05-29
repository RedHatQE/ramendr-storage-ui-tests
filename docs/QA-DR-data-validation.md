# QA: RamenDR data validation (Jira-ready)

## What runs automatically (no manual steps)

| When | What |
|------|------|
| After `./scripts/redeploy.sh` | Timestamp writers (every **10 s**) + rolling baseline snapshot every **5 min** (latest only) |
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

1. **Cleanup** on non-primary only (with DRPC safety guards; no confirmation prompt).
2. **Wait** until edge VMs are **Running** on the new primary.
3. **Validate** timestamp logs and print **PASS/FAIL**.

You do **not** run `cleanup-gitops-vms-non-primary.sh` or `check-after-dr.sh` separately unless debugging.

### Playwright

After the UI cleanup step appears, execute:

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

After VMs and DataVolumes are removed, the script also deletes **all PVCs** in `gitops-vms` on the non-primary spoke (clearing Ramen DR finalizers if stuck in `Terminating`) and removes **orphan PVs** bound to that namespace.

---

## Optional / debugging

| Task | Command |
|------|---------|
| Cleanup only (interactive) | `./scripts/cleanup-gitops-vms-non-primary.sh` |
| Cleanup only (automation) | `./scripts/cleanup-gitops-vms-non-primary.sh --yes` |
| Data check only | `./scripts/dr-validation/check-after-dr.sh` |
| Writer status | `./scripts/dr-validation/status.sh` |

---

## Jira evidence

- Attach terminal output from `post-dr-automation.sh`, or
- Folder `.work/dr-validation-logs/checks/<timestamp>/` (created by step 3 inside the script)
- Paste into **your** test ticket manually (no automatic Jira integration)

---

## Checklist

- [ ] Redeploy done; auto snapshots running
- [ ] DR completed in UI; cleanup message shown
- [ ] Ran `./scripts/dr-validation/post-dr-automation.sh` → **PASS**
- [ ] Attached output or report folder to ticket if needed
