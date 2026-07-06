"""Post-deployment smoke tests for the RamenDR environment.

Run after scripts/redeploy.sh completes (HammerDB PostgreSQL should be populated).

TestInfraSmoke — point-in-time assertions against live cluster state via oc,
                 plus HammerDB PostgreSQL table checks after automatic redeploy bootstrap.
                 No polling, no Playwright.
TestUiSmoke    — Playwright tests against the ACM hub console UI.

Usage:
    pytest tests/ui/smoke/test_smoke.py -m smoke
"""

import json
import os

import pytest

from config.settings import BASE_URL, EXPECTED_EDGE_VM_COUNT, HUB_PASSWORD, HUB_USERNAME
from pages.dashboard_page import DashboardPage
from pages.drpc_page import DRPCPage
from pages.login_page import LoginPage
from utils.oc import run_oc
from tests.utils.dr_validation import (
    assert_hammerdb_snapshot_ready,
    collect_db_snapshot,
    hammerdb_mode_active,
    load_hammerdb_snapshot,
    run_status_hammerdb,
)

# ArgoCD apps that are expected to be OutOfSync due to known drift.
# These are still required to be Healthy; only the sync status is tolerated.
_KNOWN_OUTOFSYNC_APPS = {"regional-dr"}

HUB_NAMESPACE = "ramendr-starter-kit-hub"

# Minimum VMs in gitops-vms after a full deployment (2 Linux + 1 Windows 2022 + 1 Windows 2025).
# Override with RAMENDR_MIN_VM_COUNT or RAMENDR_EXPECTED_VMS.
_MIN_VM_COUNT = int(os.getenv("RAMENDR_MIN_VM_COUNT", str(EXPECTED_EDGE_VM_COUNT)))


@pytest.mark.smoke
@pytest.mark.requires_stage
class TestInfraSmoke:
    """Verify the full RamenDR environment is operational post-deployment."""

    # ------------------------------------------------------------------
    # ArgoCD
    # ------------------------------------------------------------------

    def test_argocd_apps_synced_healthy(self, hub_kubeconfig):
        """All ArgoCD Applications in the hub namespace are Synced/Healthy.

        regional-dr may be OutOfSync (known disableExternalSecrets drift) but
        must still be Healthy. Any non-Healthy app is a hard failure.
        """
        raw = run_oc(
            [
                "get",
                "applications.argoproj.io",
                "-n",
                HUB_NAMESPACE,
                "--output=json",
            ],
            hub_kubeconfig,
        )
        apps = json.loads(raw)["items"]
        assert apps, f"No ArgoCD applications found in namespace {HUB_NAMESPACE}"

        failures = []
        for app in apps:
            name = app["metadata"]["name"]
            health = app.get("status", {}).get("health", {}).get("status", "Unknown")
            sync = app.get("status", {}).get("sync", {}).get("status", "Unknown")

            if health != "Healthy":
                failures.append(f"{name}: health={health} sync={sync}")
                continue

            if sync != "Synced" and name not in _KNOWN_OUTOFSYNC_APPS:
                failures.append(
                    f"{name}: health={health} sync={sync} (unexpected OutOfSync)"
                )

        assert not failures, (
            "ArgoCD application(s) not in expected state:\n"
            + "\n".join(f"  - {f}" for f in failures)
        )

    # ------------------------------------------------------------------
    # ACM ManagedClusters
    # ------------------------------------------------------------------

    def test_managed_clusters_available(self, hub_kubeconfig):
        """ocp-primary and ocp-secondary ManagedClusters are joined and available."""
        expected = {"ocp-primary", "ocp-secondary"}
        raw = run_oc(
            ["get", "managedclusters", "--output=json"],
            hub_kubeconfig,
        )
        clusters = {
            item["metadata"]["name"]: item
            for item in json.loads(raw)["items"]
            if item["metadata"]["name"] in expected
        }

        missing = expected - clusters.keys()
        assert not missing, f"ManagedCluster(s) not found: {missing}"

        failures = []
        for name, cluster in clusters.items():
            conditions = {
                c["type"]: c["status"]
                for c in cluster.get("status", {}).get("conditions", [])
            }
            joined = conditions.get("ManagedClusterJoined", "False")
            available = conditions.get("ManagedClusterConditionAvailable", "False")
            if joined != "True" or available != "True":
                failures.append(
                    f"{name}: ManagedClusterJoined={joined} "
                    f"ManagedClusterConditionAvailable={available}"
                )

        assert not failures, "ManagedCluster(s) not joined/available:\n" + "\n".join(
            f"  - {f}" for f in failures
        )

    # ------------------------------------------------------------------
    # ODF StorageCluster
    # ------------------------------------------------------------------

    def test_odf_storagecluster_ready(self, hub_kubeconfig):
        """ocs-storagecluster in openshift-storage on the hub is Ready."""
        raw = run_oc(
            [
                "get",
                "storagecluster",
                "ocs-storagecluster",
                "-n",
                "openshift-storage",
                "--output=json",
            ],
            hub_kubeconfig,
        )
        cluster = json.loads(raw)
        phase = cluster.get("status", {}).get("phase", "")
        assert phase == "Ready", (
            f"ocs-storagecluster phase is '{phase}', expected 'Ready'"
        )

    # ------------------------------------------------------------------
    # VirtualMachines on primary spoke
    # ------------------------------------------------------------------

    def test_vms_running_on_primary(self, primary_kubeconfig):
        """All VMs in gitops-vms on ocp-primary are Running and ready."""
        raw = run_oc(
            [
                "get",
                "virtualmachines",
                "-n",
                "gitops-vms",
                "--output=json",
            ],
            primary_kubeconfig,
        )
        vms = json.loads(raw)["items"]
        assert len(vms) >= _MIN_VM_COUNT, (
            f"Expected at least {_MIN_VM_COUNT} VirtualMachines in gitops-vms on ocp-primary, "
            f"found {len(vms)}. Partial deploy? Override with RAMENDR_MIN_VM_COUNT."
        )

        failures = []
        for vm in vms:
            name = vm["metadata"]["name"]
            status = vm.get("status", {})
            printable = status.get("printableStatus", "")
            ready = status.get("ready", False)
            if printable != "Running" or not ready:
                failures.append(f"{name}: printableStatus={printable!r} ready={ready}")

        assert not failures, (
            "VirtualMachine(s) not Running/ready on ocp-primary:\n"
            + "\n".join(f"  - {f}" for f in failures)
        )

    def test_mixed_vm_fleet_composition(self, primary_kubeconfig):
        """gitops-vms has 2 Linux + 1 Windows 2022 + 1 Windows 2025 edge VMs."""
        raw = run_oc(
            [
                "get",
                "virtualmachines",
                "-n",
                "gitops-vms",
                "--output=json",
            ],
            primary_kubeconfig,
        )
        names = [vm["metadata"]["name"] for vm in json.loads(raw)["items"]]

        linux = sorted(n for n in names if n.startswith("rhel9-node-"))
        win2022 = sorted(n for n in names if n.startswith("windows2k22-server-"))
        win2025 = sorted(n for n in names if n.startswith("windows2k25-server-"))

        assert len(linux) >= 2, (
            f"Expected at least 2 Linux VMs (rhel9-node-*), found {len(linux)}: {linux}"
        )
        assert len(win2022) >= 1, (
            f"Expected at least 1 Windows 2022 VM (windows2k22-server-*), "
            f"found {len(win2022)}: {win2022}"
        )
        assert len(win2025) >= 1, (
            f"Expected at least 1 Windows 2025 VM (windows2k25-server-*), "
            f"found {len(win2025)}: {win2025}"
        )
        assert len(names) >= _MIN_VM_COUNT, (
            f"Expected at least {_MIN_VM_COUNT} VMs total, found {len(names)}: {sorted(names)}"
        )

    def test_windows_vms_have_minimum_os_disk(self, primary_kubeconfig):
        """Windows VM OS disks are at least 45 Gi (fork chart default)."""
        raw = run_oc(
            [
                "get",
                "virtualmachines",
                "-n",
                "gitops-vms",
                "--output=json",
            ],
            primary_kubeconfig,
        )
        failures: list[str] = []
        min_gib = 45
        windows_vms = [
            vm
            for vm in json.loads(raw)["items"]
            if vm["metadata"]["name"].startswith("windows2k22-server-")
            or vm["metadata"]["name"].startswith("windows2k25-server-")
        ]
        assert windows_vms, "No Windows VMs found in gitops-vms on ocp-primary"

        for vm in windows_vms:
            name = vm["metadata"]["name"]

            dvts = vm.get("spec", {}).get("dataVolumeTemplates", [])
            os_dvt = next(
                (
                    d
                    for d in dvts
                    if not d.get("metadata", {}).get("name", "").endswith("-data")
                ),
                None,
            )
            if os_dvt is None:
                failures.append(f"{name}: no OS DataVolumeTemplate found")
                continue

            pvc_spec = os_dvt.get("spec", {}).get("pvc") or os_dvt.get("spec", {}).get(
                "storage", {}
            )
            size = (
                (pvc_spec or {})
                .get("resources", {})
                .get("requests", {})
                .get("storage", "")
            )
            if not size.endswith("Gi"):
                failures.append(f"{name}: OS disk size {size!r} is not in Gi units")
                continue
            gib = float(size[:-2])
            if gib < min_gib:
                failures.append(
                    f"{name}: OS disk {size!r} is below minimum {min_gib}Gi"
                )

        assert not failures, "Windows VM OS disk size issues:\n" + "\n".join(
            f"  - {f}" for f in failures
        )

    def test_vms_have_two_data_disks(
        self, hub_kubeconfig, primary_kubeconfig, secondary_kubeconfig
    ):
        """Every VM in gitops-vms has exactly 2 DataVolume-backed disks.

        Linux layout:
          dataVolumeTemplates[0] — 30 Gi OS root disk  (e.g. rhel9-node-001)
          dataVolumeTemplates[1] — 10 Gi blank data disk (e.g. rhel9-node-001-data)

        Windows layout (same DR eligibility pattern):
          dataVolumeTemplates[0] — 45 Gi OS disk (e.g. windows2k22-server-001)
          dataVolumeTemplates[1] — 10 Gi blank data disk (e.g. windows2k22-server-001-data)

        The cloud-init disk is ephemeral and is intentionally excluded from
        this count because it is not backed by a DataVolume.

        The second disk must have the properties required for RamenDR
        replication eligibility:
          - name ending in '-data'
          - storage: 10Gi
          - volumeMode: Block
          - accessModes: [ReadWriteMany]
          - storageClassName: ocs-storagecluster-ceph-rbd-virtualization

        The test is cluster-aware: it follows the DRPC placement to check VMs
        on whichever spoke currently hosts them (primary after Deployed/Relocated,
        secondary after FailedOver).
        """
        _EXPECTED_DATA_STORAGE = "10Gi"
        _EXPECTED_STORAGE_CLASS = "ocs-storagecluster-ceph-rbd-virtualization"

        # Determine which cluster currently hosts the VMs from the DRPC.
        raw_drpc = run_oc(
            [
                "get",
                "drplacementcontrol",
                "gitops-vm-protection",
                "-n",
                "openshift-dr-ops",
                "--output=json",
            ],
            hub_kubeconfig,
        )
        drpc = json.loads(raw_drpc)
        preferred = drpc.get("spec", {}).get("preferredCluster", "ocp-primary")
        drpc_phase = drpc.get("status", {}).get("phase", "")

        # FailedOver → VMs are on the non-preferred cluster; any other phase → preferred.
        if drpc_phase == "FailedOver":
            active_cluster = (
                "ocp-secondary" if preferred == "ocp-primary" else "ocp-primary"
            )
        else:
            active_cluster = preferred

        kubeconfig = (
            primary_kubeconfig
            if active_cluster == "ocp-primary"
            else secondary_kubeconfig
        )

        raw = run_oc(
            [
                "get",
                "virtualmachines",
                "-n",
                "gitops-vms",
                "--output=json",
            ],
            kubeconfig,
        )
        vms = json.loads(raw)["items"]
        assert vms, f"No VirtualMachines found in gitops-vms on {active_cluster}"

        failures: list[str] = []
        data_pvc_names: set[str] = set()

        for vm in vms:
            name = vm["metadata"]["name"]
            dvts = vm.get("spec", {}).get("dataVolumeTemplates", [])

            if len(dvts) != 2:
                dv_names = [d.get("metadata", {}).get("name", "?") for d in dvts]
                failures.append(
                    f"{name}: expected 2 DataVolumeTemplates, got {len(dvts)} {dv_names}"
                )
                continue

            # Identify the data disk by its '-data' name suffix.
            data_dvt = next(
                (
                    d
                    for d in dvts
                    if d.get("metadata", {}).get("name", "").endswith("-data")
                ),
                None,
            )
            if data_dvt is None:
                dv_names = [d.get("metadata", {}).get("name", "?") for d in dvts]
                failures.append(
                    f"{name}: no DataVolumeTemplate with '-data' suffix found in {dv_names}"
                )
                continue

            data_pvc_name = data_dvt["metadata"]["name"]
            data_pvc_names.add(data_pvc_name)

            # Check declared storage size in the DVT spec (supports both pvc and storage API).
            pvc_spec = data_dvt.get("spec", {}).get("pvc") or data_dvt.get(
                "spec", {}
            ).get("storage", {})
            size = (
                (pvc_spec or {})
                .get("resources", {})
                .get("requests", {})
                .get("storage", "")
            )
            if size != _EXPECTED_DATA_STORAGE:
                failures.append(
                    f"{name} data disk: declared storage={size!r}, expected {_EXPECTED_DATA_STORAGE!r}"
                )

        assert not failures, (
            "VirtualMachine(s) data disk structure issues:\n"
            + "\n".join(f"  - {f}" for f in failures)
        )

        # Verify PVC properties for all data disks.
        raw_pvcs = run_oc(
            [
                "get",
                "persistentvolumeclaims",
                "-n",
                "gitops-vms",
                "--output=json",
            ],
            kubeconfig,
        )
        pvcs_by_name = {
            item["metadata"]["name"]: item for item in json.loads(raw_pvcs)["items"]
        }

        pvc_failures: list[str] = []
        for pvc_name in sorted(data_pvc_names):
            pvc = pvcs_by_name.get(pvc_name)
            if pvc is None:
                pvc_failures.append(f"{pvc_name}: <missing>")
                continue

            spec = pvc.get("spec", {})
            pvc_phase = pvc.get("status", {}).get("phase", "")
            volume_mode = spec.get("volumeMode", "")
            access_modes = spec.get("accessModes", [])
            storage_class = spec.get("storageClassName", "")
            size = spec.get("resources", {}).get("requests", {}).get("storage", "")

            issues = []
            if pvc_phase != "Bound":
                issues.append(f"phase={pvc_phase!r} (expected 'Bound')")
            if volume_mode != "Block":
                issues.append(f"volumeMode={volume_mode!r} (expected 'Block')")
            if "ReadWriteMany" not in access_modes:
                issues.append(f"accessModes={access_modes} (expected ReadWriteMany)")
            if storage_class != _EXPECTED_STORAGE_CLASS:
                issues.append(
                    f"storageClassName={storage_class!r} (expected {_EXPECTED_STORAGE_CLASS!r})"
                )
            if size != _EXPECTED_DATA_STORAGE:
                issues.append(f"storage={size!r} (expected {_EXPECTED_DATA_STORAGE!r})")

            if issues:
                pvc_failures.append(f"{pvc_name}: " + "; ".join(issues))

        assert not pvc_failures, (
            f"PVC(s) for VM data disks have unexpected properties on {active_cluster}:\n"
            + "\n".join(f"  - {f}" for f in pvc_failures)
        )

    # ------------------------------------------------------------------
    # ExternalSecrets on primary spoke
    # ------------------------------------------------------------------

    def test_vm_external_secrets_present(self, primary_kubeconfig):
        """At least one ExternalSecret exists in gitops-vms on ocp-primary.

        Confirms disableExternalSecrets=false: Linux VMs get cloud-init / SSH keys
        from Vault; Windows VMs get registry pull credentials for CDI image import.
        """
        raw = run_oc(
            [
                "get",
                "externalsecrets",
                "-n",
                "gitops-vms",
                "--output=json",
            ],
            primary_kubeconfig,
        )
        secrets = json.loads(raw)["items"]
        assert secrets, (
            "VMs were deployed without ExternalSecrets — "
            "cloud-init and SSH login will not work"
        )

    # ------------------------------------------------------------------
    # HammerDB PostgreSQL DR validation workload
    # ------------------------------------------------------------------

    def test_hammerdb_postgres_tables_populated(self, hub_kubeconfig, tmp_path):
        """HammerDB TPC-C database is deployed with populated tables after redeploy.

        Validates the production-like schema (customer IDs, orders, stock, …) and
        the dr_validation_audit trail on the DR-protected PostgreSQL instance.
        """
        if not hammerdb_mode_active():
            pytest.skip("HammerDB DR validation is disabled")

        status = run_status_hammerdb(kubeconfig=hub_kubeconfig)
        assert status.returncode == 0, (
            "HammerDB PostgreSQL workload is not healthy after redeploy.\n"
            f"stdout:\n{status.stdout}\n"
            f"stderr:\n{status.stderr}"
        )

        snapshot_dir = tmp_path / "hammerdb-smoke"
        collected = collect_db_snapshot(
            kubeconfig=hub_kubeconfig,
            out_dir=snapshot_dir,
        )
        assert collected.returncode == 0, (
            "Could not collect HammerDB DB snapshot during smoke test.\n"
            f"stdout:\n{collected.stdout}\n"
            f"stderr:\n{collected.stderr}"
        )

        snapshot = load_hammerdb_snapshot(snapshot_dir)
        assert_hammerdb_snapshot_ready(snapshot)

        tpcc = snapshot["tpcc"]
        assert tpcc["customer"] >= 3000, (
            "customer table must contain 3000 rows per warehouse"
        )
        assert tpcc["warehouse"] >= 1
        assert tpcc["item"] >= 100_000

    # ------------------------------------------------------------------
    # DRPolicy
    # ------------------------------------------------------------------

    def test_drpolicy_validated(self, hub_kubeconfig):
        """Both DRPolicies (2m-novm, 2m-vm) have Validated=True."""
        expected = {"2m-novm", "2m-vm"}
        raw = run_oc(
            ["get", "drpolicies", "--output=json"],
            hub_kubeconfig,
        )
        policies = {
            item["metadata"]["name"]: item
            for item in json.loads(raw)["items"]
            if item["metadata"]["name"] in expected
        }

        missing = expected - policies.keys()
        assert not missing, f"DRPolicy resource(s) not found: {missing}"

        failures = []
        for name, policy in policies.items():
            conditions = {
                c["type"]: c["status"]
                for c in policy.get("status", {}).get("conditions", [])
            }
            validated = conditions.get("Validated", "False")
            if validated != "True":
                failures.append(f"{name}: Validated={validated}")

        assert not failures, "DRPolicy resource(s) not validated:\n" + "\n".join(
            f"  - {f}" for f in failures
        )

    # ------------------------------------------------------------------
    # MirrorPeer
    # ------------------------------------------------------------------

    def test_mirrorpeer_exchanged_secret(self, hub_kubeconfig):
        """MirrorPeer mirrorpeer-resilient has phase ExchangedSecret."""
        raw = run_oc(
            [
                "get",
                "mirrorpeer",
                "mirrorpeer-resilient",
                "--output=json",
            ],
            hub_kubeconfig,
        )
        peer = json.loads(raw)
        phase = peer.get("status", {}).get("phase", "")
        assert phase == "ExchangedSecret", (
            f"MirrorPeer mirrorpeer-resilient phase is '{phase}', "
            "expected 'ExchangedSecret'"
        )

    # ------------------------------------------------------------------
    # DRPlacementControl
    # ------------------------------------------------------------------

    def test_drpc_deployed_available(self, hub_kubeconfig):
        """DRPlacementControl gitops-vm-protection is Deployed (or Relocated) and Available."""
        raw = run_oc(
            [
                "get",
                "drplacementcontrol",
                "gitops-vm-protection",
                "-n",
                "openshift-dr-ops",
                "--output=json",
            ],
            hub_kubeconfig,
        )
        drpc = json.loads(raw)
        status = drpc.get("status", {})
        phase = status.get("phase", "")
        # "Relocated" is a valid steady-state after a completed DR cycle.
        assert phase in {"Deployed", "Relocated"}, (
            f"DRPlacementControl gitops-vm-protection phase is '{phase}', "
            "expected 'Deployed' or 'Relocated'"
        )

        conditions = {c["type"]: c["status"] for c in status.get("conditions", [])}
        available = conditions.get("Available", "False")
        assert available == "True", (
            f"DRPlacementControl gitops-vm-protection condition Available={available}"
        )

    # ------------------------------------------------------------------
    # Vault
    # ------------------------------------------------------------------

    def test_vault_running(self, hub_kubeconfig):
        """Pod vault-0 in namespace vault on the hub is Running."""
        raw = run_oc(
            [
                "get",
                "pod",
                "vault-0",
                "-n",
                "vault",
                "--output=json",
            ],
            hub_kubeconfig,
        )
        pod = json.loads(raw)
        phase = pod.get("status", {}).get("phase", "")
        assert phase == "Running", f"Pod vault-0 phase is '{phase}', expected 'Running'"

    # ------------------------------------------------------------------
    # ExternalSecrets across all hub namespaces
    # ------------------------------------------------------------------

    def test_external_secrets_synced(self, hub_kubeconfig):
        """No ExternalSecret on the hub has a Degraded / non-SecretSynced condition."""
        raw = run_oc(
            [
                "get",
                "externalsecrets",
                "--all-namespaces",
                "--output=json",
            ],
            hub_kubeconfig,
        )
        secrets = json.loads(raw)["items"]
        failures = []
        for es in secrets:
            name = es["metadata"]["name"]
            ns = es["metadata"]["namespace"]
            conditions = es.get("status", {}).get("conditions", [])
            for cond in conditions:
                if cond.get("type") == "Ready" and cond.get("status") != "True":
                    reason = cond.get("reason", "")
                    message = cond.get("message", "")
                    if reason != "SecretSynced":
                        failures.append(
                            f"{ns}/{name}: reason={reason!r} message={message!r}"
                        )

        assert not failures, (
            "ExternalSecret(s) on the hub are not synced:\n"
            + "\n".join(f"  - {f}" for f in failures)
        )


# ---------------------------------------------------------------------------
# UI smoke tests (Playwright)
# ---------------------------------------------------------------------------


def _require_ui_credentials():
    """Skip the calling test if BASE_URL, HUB_USERNAME, or HUB_PASSWORD are unset."""
    if not BASE_URL:
        pytest.skip(
            "BASE_URL is empty — set BASE_DOMAIN or RAMENDR_BASE_URL before running UI tests"
        )
    missing = [
        name
        for name, val in [
            ("RAMENDR_HUB_USERNAME", HUB_USERNAME),
            ("RAMENDR_HUB_PASSWORD", HUB_PASSWORD),
        ]
        if not val
    ]
    if missing:
        pytest.skip(f"Required env var(s) not set: {', '.join(missing)}")


@pytest.mark.smoke
@pytest.mark.requires_stage
class TestUiSmoke:
    """Verify the RamenDR ACM hub console UI after deployment."""

    def test_disaster_recovery_ui(self, page):
        """Full DR UI walkthrough: login → policy validated → DRPC healthy.

        Flow:
          1. Log in to the ACM hub console.
          2. Dismiss the welcome modal if present.
          3. Switch to Fleet Management perspective and open Data Services →
             Disaster recovery via the left nav.
          4. Policies tab: assert 2m-vm is Validated with 1 Application.
          5. Protected applications tab: assert gitops-vm-protection is Healthy,
             using policy 2m-vm, placed on cluster ocp-primary.
        """
        _require_ui_credentials()

        login_page = LoginPage(page)
        login_page.open(BASE_URL)
        login_page.assert_page_loaded()
        login_page.login(HUB_USERNAME, HUB_PASSWORD)

        dashboard = DashboardPage(page)
        dashboard.assert_page_loaded()
        dashboard.dismiss_welcome_if_present()

        drpc_page = DRPCPage(page)
        drpc_page.navigate(BASE_URL)

        # --- Policies tab ---
        drpc_page.navigate_policies_tab()
        drpc_page.assert_drpolicy(
            "2m-vm",
            expected_status="Validated",
            expected_applications="1 Application",
        )

        # --- Protected applications tab ---
        drpc_page.navigate_protected_applications_tab()
        drpc_page.assert_drpc(
            "gitops-vm-protection",
            expected_policy="2m-vm",
            expected_cluster="ocp-primary",
        )
