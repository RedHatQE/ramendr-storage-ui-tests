"""Post-deployment smoke tests for the RamenDR environment.

Run after scripts/redeploy.sh completes.

TestInfraSmoke — point-in-time assertions against live cluster state via oc.
                 No polling, no Playwright.
TestUiSmoke    — Playwright tests against the ACM hub console UI.

Usage:
    pytest tests/ui/smoke/test_smoke.py -m smoke
"""

import json
import os

import pytest

from config.settings import BASE_URL, HUB_PASSWORD, HUB_USERNAME
from pages.dashboard_page import DashboardPage
from pages.drpc_page import DRPCPage
from pages.login_page import LoginPage
from utils.oc import run_oc

# ArgoCD apps that are expected to be OutOfSync due to known drift.
# These are still required to be Healthy; only the sync status is tolerated.
_KNOWN_OUTOFSYNC_APPS = {"regional-dr"}

HUB_NAMESPACE = "ramendr-starter-kit-hub"

# Minimum number of VMs expected in gitops-vms on ocp-primary after a full
# deployment. Override with RAMENDR_MIN_VM_COUNT.
_MIN_VM_COUNT = int(os.getenv("RAMENDR_MIN_VM_COUNT", "4"))


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

    # ------------------------------------------------------------------
    # ExternalSecrets on primary spoke
    # ------------------------------------------------------------------

    def test_vm_external_secrets_present(self, primary_kubeconfig):
        """At least one ExternalSecret exists in gitops-vms on ocp-primary.

        This confirms disableExternalSecrets=false is in effect and that VMs
        have cloud-init / SSH keys sourced from Vault.
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
        """DRPlacementControl gitops-vm-protection is Deployed and Available."""
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
        assert phase == "Deployed", (
            f"DRPlacementControl gitops-vm-protection phase is '{phase}', "
            "expected 'Deployed'"
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
