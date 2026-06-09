"""UI sanity tests for the RamenDR ACM console.

Run after scripts/redeploy.sh completes (timestamp writers should be recording).

Usage:
    pytest tests/ui/sanity/test_sanity.py -m smoke

    # Default: full failover → relocate cycle (RAMENDR_SANITY_FORCE_FULL=1).
    # Resume/adaptive mode (skip steps when cluster is already post-DR):
    RAMENDR_SANITY_FORCE_FULL=0 pytest tests/ui/sanity/test_sanity.py -m smoke

After each DR phase (failover to secondary, relocate back to primary), the test
collects edge VM timestamp logs and asserts sequence continuity (no data-loss gaps).
Set RAMENDR_SANITY_SKIP_DR_VALIDATION=1 or SKIP_DR_VALIDATION=1 to skip that step.
Default RTO standard is 900s (15 min); override with RAMENDR_SANITY_MAX_RTO_SECONDS.
Warn when RTO exceeds 120s (RAMENDR_SANITY_RTO_WARN_SECONDS); fail only above the 15 min limit.
DR validation subprocess timeout defaults to 600s (RAMENDR_SANITY_DR_VALIDATION_TIMEOUT_SECONDS).
"""

import json
import os
import subprocess
import time
import uuid
from datetime import datetime, timezone
from pathlib import Path

import pytest

from config.settings import (
    BASE_URL,
    HUB_KUBECONFIG,
    HUB_PASSWORD,
    HUB_USERNAME,
    PRIMARY_KUBECONFIG,
    SECONDARY_KUBECONFIG,
)
from pages.dashboard_page import DashboardPage
from pages.drpc_page import DRPCPage
from pages.login_page import LoginPage

_FORCE_FULL_SANITY = os.getenv("RAMENDR_SANITY_FORCE_FULL", "1").lower() not in {
    "0",
    "false",
    "no",
}

_SKIP_DR_TIMESTAMP_VALIDATION = (
    os.getenv("RAMENDR_SANITY_SKIP_DR_VALIDATION", "0").lower() in {"1", "true", "yes"}
    or os.getenv("SKIP_DR_VALIDATION", "0") == "1"
)

_MAX_RTO_SECONDS = float(os.getenv("RAMENDR_SANITY_MAX_RTO_SECONDS", "900"))
_RTO_WARN_SECONDS = float(os.getenv("RAMENDR_SANITY_RTO_WARN_SECONDS", "120"))
_DR_VALIDATION_TIMEOUT_SECONDS = float(
    os.getenv("RAMENDR_SANITY_DR_VALIDATION_TIMEOUT_SECONDS", "900")
)
_CLEANUP_TIMEOUT_SECONDS = float(
    os.getenv(
        "RAMENDR_SANITY_CLEANUP_TIMEOUT_SECONDS",
        os.getenv("RAMENDR_SANITY_DR_VALIDATION_TIMEOUT_SECONDS", "600"),
    )
)
# How many edge VMs the test expects (must all be SSHable for RTO to be satisfied).
_EXPECTED_VMS = int(os.getenv("RAMENDR_EXPECTED_VMS", "4"))
# Hard timeout for the SSH-reachability polling that ends the RTO clock (default 30 min).
_SSH_RTO_TIMEOUT_SECONDS = float(os.getenv("RAMENDR_SSH_RTO_TIMEOUT_SECONDS", "1800"))
# Image used for the ephemeral in-cluster SSH-probe pod.  busybox ships nc and is tiny.
# Override with RAMENDR_PROBE_IMAGE if busybox is not available on your nodes.
_PROBE_IMAGE = os.getenv("RAMENDR_PROBE_IMAGE", "busybox")
# How long to wait for DRPC to reach Healthy after a failover/relocate (default 60 min).
# Ceph RBD mirroring must re-establish at least one sync after failover before
# DataProtected=True, which can take significantly longer than the DR operation itself.
_DRPC_HEALTHY_TIMEOUT_MS = int(
    float(os.getenv("RAMENDR_SANITY_DRPC_HEALTHY_TIMEOUT_SECONDS", "1800")) * 1000
)


def _repo_root() -> Path:
    return Path(__file__).resolve().parents[3]


def _assert_rto_within_standard(*, phase: str, started_at: float | None) -> None:
    """Assert measured failover/relocate duration is within the configured RTO."""
    if started_at is None:
        print(
            f"NOTE: RTO check skipped for {phase} (operation start time not observed)"
        )
        return
    elapsed = time.monotonic() - started_at
    if elapsed > _RTO_WARN_SECONDS:
        print(
            f"WARNING: {phase} RTO exceeded {_RTO_WARN_SECONDS:.0f}s "
            f"(elapsed={elapsed:.1f}s; DRPolicy target is ~2m). "
            f"Still within {_MAX_RTO_SECONDS:.0f}s hard limit."
        )
    assert elapsed <= _MAX_RTO_SECONDS, (
        f"{phase} RTO standard breached: elapsed={elapsed:.1f}s "
        f"max={_MAX_RTO_SECONDS:.1f}s. "
        "Adjust RAMENDR_SANITY_MAX_RTO_SECONDS only if SLO changes."
    )
    print(
        f"{phase} RTO check passed: elapsed={elapsed:.1f}s <= "
        f"max={_MAX_RTO_SECONDS:.1f}s"
    )


def _wait_for_vms_running_with_ssh_service(
    kubeconfig: str,
    *,
    cluster_name: str,
    expected: int = _EXPECTED_VMS,
    timeout_s: float = _SSH_RTO_TIMEOUT_SECONDS,
    poll_interval_s: float = 15.0,
) -> list[str]:
    """Block until *expected* edge VMs on *cluster_name* are Running with SSH services.

    The edge VMs are exposed via NodePort on cluster-internal IPs only, so direct
    TCP connects from the external test runner are not possible.  Instead, we poll
    the Kubernetes API (via kubeconfig) for:
      1. *expected* VirtualMachineInstances in phase Running in gitops-vms.
      2. *expected* NodePort Services with SSH (port 22) in gitops-vms.

    Both conditions being met means the VM infrastructure is up and SSH is
    configured on the cluster side.  Actual end-to-end SSH connectivity is not
    verified here because NodePorts are on cluster-internal IPs unreachable from
    the external test runner.

    Returns the ClusterIP addresses of all discovered SSH NodePort services so
    the caller can pass them to _probe_ssh_via_pod() for in-cluster verification.

    The caller stops the RTO clock immediately after this function returns.
    """
    vm_namespace = "gitops-vms"
    deadline = time.monotonic() + timeout_s
    attempt = 0
    last_running: list[str] = []
    last_ssh_svcs: list[str] = []
    last_ssh_cluster_ips: list[str] = []

    while time.monotonic() < deadline:
        attempt += 1
        env = os.environ.copy()
        env["KUBECONFIG"] = kubeconfig

        # Count Running VMIs. KubeVirt does NOT support --field-selector status.phase,
        # so we fetch all VMIs as JSON and filter by phase in Python.
        running_names: list[str] = []
        try:
            r = subprocess.run(  # noqa: S603
                [  # noqa: S607
                    "oc",
                    "get",
                    "vmi",
                    "-n",
                    vm_namespace,
                    "-o",
                    "json",
                ],
                capture_output=True,
                text=True,
                timeout=20,
                check=False,
                env=env,
            )
            if r.returncode == 0:
                vmi_data = json.loads(r.stdout)
                running_names = [
                    item["metadata"]["name"]
                    for item in vmi_data.get("items", [])
                    if item.get("status", {}).get("phase", "").lower() == "running"
                ]
        except (subprocess.TimeoutExpired, OSError, ValueError, KeyError):
            pass

        # Count NodePort Services with an SSH (port 22) entry; collect ClusterIPs
        # so the in-cluster probe knows where to connect.
        ssh_svc_names: list[str] = []
        ssh_svc_cluster_ips: list[str] = []
        try:
            r2 = subprocess.run(  # noqa: S603
                [  # noqa: S607
                    "oc",
                    "get",
                    "svc",
                    "-n",
                    vm_namespace,
                    "-o",
                    "json",
                ],
                capture_output=True,
                text=True,
                timeout=20,
                check=False,
                env=env,
            )
            if r2.returncode == 0:
                svc_data = json.loads(r2.stdout)
                for item in svc_data.get("items", []):
                    if item.get("spec", {}).get("type") != "NodePort":
                        continue
                    ports = item.get("spec", {}).get("ports", [])
                    if any(
                        p.get("port") == 22 or p.get("name") == "ssh" for p in ports
                    ):
                        ssh_svc_names.append(item["metadata"]["name"])
                        cluster_ip = item.get("spec", {}).get("clusterIP", "")
                        if cluster_ip and cluster_ip != "None":
                            ssh_svc_cluster_ips.append(cluster_ip)
        except (subprocess.TimeoutExpired, OSError, ValueError, KeyError):
            pass

        last_running = running_names
        last_ssh_svcs = ssh_svc_names
        last_ssh_cluster_ips = ssh_svc_cluster_ips
        remaining = max(0, int(deadline - time.monotonic()))
        print(
            f"  [vm-ready attempt={attempt}] cluster={cluster_name} "
            f"running_vmis={running_names} ssh_services={ssh_svc_names} "
            f"remaining={remaining}s"
        )

        if len(running_names) >= expected and len(ssh_svc_names) >= expected:
            print(
                f"  All {expected} VM(s) are Running with SSH services on {cluster_name}."
            )
            return ssh_svc_cluster_ips

        sleep_for = min(poll_interval_s, max(0.0, deadline - time.monotonic()))
        if sleep_for > 0:
            time.sleep(sleep_for)

    pytest.fail(
        f"Timed out waiting for {expected} VM(s) Running with SSH services on "
        f"{cluster_name} (limit={timeout_s:.0f}s). "
        f"Last running VMIs: {last_running}. Last SSH services: {last_ssh_svcs}"
    )
    return last_ssh_cluster_ips  # unreachable; satisfies type checker


def _launch_ssh_probe_pod(kubeconfig: str, *, namespace: str = "gitops-vms") -> str:
    """Create an ephemeral idle pod for later in-cluster TCP probing.

    Call this at DR initiation time so pod scheduling and image pull happen in
    parallel with the DR operation, absorbing the overhead into the DR window
    rather than the RTO measurement.  The pod sleeps until _probe_ssh_via_pod()
    execs into it.  Returns the unique pod name.
    """
    pod_name = f"ramendr-ssh-probe-{uuid.uuid4().hex[:8]}"
    env = os.environ.copy()
    env["KUBECONFIG"] = kubeconfig
    try:
        subprocess.run(  # noqa: S603
            [  # noqa: S607
                "oc",
                "run",
                pod_name,
                "-n",
                namespace,
                "--restart=Never",
                f"--image={_PROBE_IMAGE}",
                "--",
                "sh",
                "-c",
                "sleep 600",
            ],
            env=env,
            capture_output=True,
            text=True,
            timeout=30,
            check=False,
        )
    except (subprocess.TimeoutExpired, OSError):
        pass
    print(
        f"  [ssh-probe] pod {pod_name!r} submitted to {namespace} (scheduling in background)"
    )
    return pod_name


def _probe_ssh_via_pod(
    kubeconfig: str,
    pod_name: str,
    cluster_ips: list[str],
    *,
    namespace: str = "gitops-vms",
    port: int = 22,
    pod_ready_timeout_s: float = 60.0,
    probe_timeout_s: float = 300.0,
    probe_interval_s: float = 10.0,
) -> None:
    """Exec a TCP SSH check from the pre-launched probe pod to each VM ClusterIP.

    The pod was launched at DR initiation, so it should already be Running by the
    time this is called (DR takes minutes; pod startup takes seconds).  Waits up
    to pod_ready_timeout_s for the pod to become Running; if it never does, logs a
    warning and skips the probe rather than failing the test.

    After the pod is Running, polls connectivity for up to probe_timeout_s.  This
    retry window is intentional: KubeVirt marks a VMI Running when the VM process
    starts, but the guest SSH daemon may take 30–60 s more to come up after OS
    boot.  Since this function is called before _assert_rto_within_standard, the
    retry time is correctly included in the RTO measurement.

    Always deletes the pod on exit.  Calls pytest.fail() only after probe_timeout_s
    is exhausted with unreachable IPs.
    """
    if not cluster_ips:
        print("  [ssh-probe] no ClusterIPs to probe — skipping in-cluster check.")
        _delete_probe_pod(kubeconfig, pod_name, namespace=namespace)
        return

    env = os.environ.copy()
    env["KUBECONFIG"] = kubeconfig

    # Wait for the probe pod to be Running.
    pod_deadline = time.monotonic() + pod_ready_timeout_s
    pod_running = False
    while time.monotonic() < pod_deadline:
        try:
            r = subprocess.run(  # noqa: S603
                [  # noqa: S607
                    "oc",
                    "get",
                    "pod",
                    pod_name,
                    "-n",
                    namespace,
                    "-o",
                    "jsonpath={.status.phase}",
                ],
                env=env,
                capture_output=True,
                text=True,
                timeout=10,
                check=False,
            )
            if r.returncode == 0 and r.stdout.strip() == "Running":
                pod_running = True
                break
        except (subprocess.TimeoutExpired, OSError):
            pass
        time.sleep(5)

    if not pod_running:
        print(
            f"WARNING: SSH probe pod {pod_name!r} not Running after "
            f"{pod_ready_timeout_s:.0f}s — skipping in-cluster connectivity check."
        )
        _delete_probe_pod(kubeconfig, pod_name, namespace=namespace)
        return

    # Poll until every ClusterIP is reachable or the deadline expires.
    # Retrying is necessary because KubeVirt marks VMIs Running before the
    # guest SSH daemon has finished starting.
    probe_deadline = time.monotonic() + probe_timeout_s
    pending = list(cluster_ips)

    while pending and time.monotonic() < probe_deadline:
        newly_ok: list[str] = []
        for ip in list(pending):
            try:
                r = subprocess.run(  # noqa: S603
                    [  # noqa: S607
                        "oc",
                        "exec",
                        pod_name,
                        "-n",
                        namespace,
                        "--",
                        "sh",
                        "-c",
                        f"nc -z -w 5 {ip} {port} && echo OK || echo FAIL",
                    ],
                    env=env,
                    capture_output=True,
                    text=True,
                    timeout=20,
                    check=False,
                )
                if r.returncode == 0 and "OK" in r.stdout:
                    print(f"  [ssh-probe] TCP {ip}:{port} — OK")
                    newly_ok.append(ip)
                else:
                    remaining_s = max(0, int(probe_deadline - time.monotonic()))
                    print(
                        f"  [ssh-probe] TCP {ip}:{port} — not yet reachable "
                        f"(retrying, {remaining_s}s left)"
                    )
            except (subprocess.TimeoutExpired, OSError) as exc:
                print(f"  [ssh-probe] TCP {ip}:{port} — exec error: {exc}")

        for ip in newly_ok:
            pending.remove(ip)

        if pending:
            sleep_for = min(
                probe_interval_s, max(0.0, probe_deadline - time.monotonic())
            )
            if sleep_for > 0:
                time.sleep(sleep_for)

    _delete_probe_pod(kubeconfig, pod_name, namespace=namespace)

    if pending:
        pytest.fail(
            f"In-cluster SSH TCP probe timed out for {len(pending)} VM service(s) "
            f"after {probe_timeout_s:.0f}s:\n"
            + "\n".join(f"  - {ip}:{port}" for ip in pending)
        )
    print(
        f"  [ssh-probe] all {len(cluster_ips)} VM SSH service(s) reachable in-cluster."
    )


def _delete_probe_pod(
    kubeconfig: str, pod_name: str, *, namespace: str = "gitops-vms"
) -> None:
    """Delete the ephemeral probe pod, ignoring all errors."""
    env = os.environ.copy()
    env["KUBECONFIG"] = kubeconfig
    try:
        subprocess.run(  # noqa: S603
            [  # noqa: S607
                "oc",
                "delete",
                "pod",
                pod_name,
                "-n",
                namespace,
                "--ignore-not-found",
                "--wait=false",
            ],
            env=env,
            capture_output=True,
            text=True,
            timeout=15,
            check=False,
        )
    except (subprocess.TimeoutExpired, OSError):
        pass


def _run_dr_timestamp_validation(
    *, phase: str, initiated_utc: datetime | None = None
) -> None:
    """Collect VM timestamp logs and assert continuity after failover or relocate.

    initiated_utc: UTC datetime of the "Initiate" UI click that started the DR
    operation.  When provided it is forwarded as DR_VALIDATION_CUTOFF_UTC so
    check-after-dr.sh can enforce the RPO relative to the exact initiation moment.
    When None (resume/adaptive mode) the cutoff-based RPO check is skipped.
    """
    if _SKIP_DR_TIMESTAMP_VALIDATION:
        print(
            f"NOTE: Skipping DR timestamp validation after {phase} "
            "(RAMENDR_SANITY_SKIP_DR_VALIDATION or SKIP_DR_VALIDATION)"
        )
        return

    script_path = _repo_root() / "scripts" / "dr-validation" / "check-after-dr.sh"
    assert script_path.exists(), f"DR validation script not found: {script_path}"

    env = os.environ.copy()
    env["KUBECONFIG"] = HUB_KUBECONFIG
    if initiated_utc is not None:
        env["DR_VALIDATION_CUTOFF_UTC"] = initiated_utc.isoformat()
    cmd = ["bash", str(script_path)]
    try:
        result = subprocess.run(  # noqa: S603
            cmd,  # noqa: S607
            cwd=_repo_root(),
            env=env,
            text=True,
            capture_output=True,
            check=False,
            timeout=_DR_VALIDATION_TIMEOUT_SECONDS,
        )
    except subprocess.TimeoutExpired as exc:
        stdout = exc.stdout or ""
        stderr = exc.stderr or ""
        if isinstance(stdout, bytes):
            stdout = stdout.decode(errors="replace")
        if isinstance(stderr, bytes):
            stderr = stderr.decode(errors="replace")
        pytest.fail(
            f"DR timestamp validation timed out after {phase} "
            f"(limit={_DR_VALIDATION_TIMEOUT_SECONDS:.0f}s; "
            "increase RAMENDR_SANITY_DR_VALIDATION_TIMEOUT_SECONDS if needed).\n"
            f"stdout:\n{stdout}\n"
            f"stderr:\n{stderr}"
        )
    assert result.returncode == 0, (
        f"DR timestamp validation failed after {phase} "
        "(sequence gaps or log collect errors — see dr-validation/README.md).\n"
        f"stdout:\n{result.stdout}\n"
        f"stderr:\n{result.stderr}"
    )


def _run_cleanup_non_primary_cluster(*, skip_pvcs: bool = False):
    """Run non-primary cleanup script (auto-confirm) after failover action-needed.

    Pass skip_pvcs=True during relocate cleanup to preserve the RBD mirror source
    images on the non-primary cluster. Deleting those PVCs while ocp-primary is
    still promoting its VolumeGroupReplication breaks the promotion path.
    """
    repo_root = _repo_root()
    script_path = repo_root / "scripts" / "cleanup-gitops-vms-non-primary.sh"
    assert script_path.exists(), f"Cleanup script not found: {script_path}"

    # --force bypasses the drpc-guard PlacementDecision check, which can block
    # during an in-flight relocate triggered by the test itself (the decision
    # is briefly empty while the relocation is progressing).
    flags = "--force"
    if skip_pvcs:
        flags += " --skip-pvcs"
    cmd = f"printf 'yes\\n' | {script_path} {flags}"
    env = os.environ.copy()
    env["KUBECONFIG"] = HUB_KUBECONFIG
    try:
        result = subprocess.run(  # noqa: S603
            ["bash", "-lc", cmd],  # noqa: S607
            cwd=repo_root,
            env=env,
            text=True,
            capture_output=True,
            check=False,
            timeout=_CLEANUP_TIMEOUT_SECONDS,
        )
    except subprocess.TimeoutExpired as exc:
        stdout = exc.stdout or ""
        stderr = exc.stderr or ""
        if isinstance(stdout, bytes):
            stdout = stdout.decode(errors="replace")
        if isinstance(stderr, bytes):
            stderr = stderr.decode(errors="replace")
        pytest.fail(
            "cleanup-gitops-vms-non-primary.sh timed out "
            f"(limit={_CLEANUP_TIMEOUT_SECONDS:.0f}s; "
            "increase RAMENDR_SANITY_CLEANUP_TIMEOUT_SECONDS if needed).\n"
            f"stdout:\n{stdout}\n"
            f"stderr:\n{stderr}"
        )
    assert result.returncode == 0, (
        "cleanup-gitops-vms-non-primary.sh failed.\n"
        f"stdout:\n{result.stdout}\n"
        f"stderr:\n{result.stderr}"
    )


def _assert_managed_clusters_available():
    """Assert ocp-primary and ocp-secondary clusters are joined and available."""
    expected = {"ocp-primary", "ocp-secondary"}
    result = subprocess.run(  # noqa: S603
        [
            "oc",
            f"--kubeconfig={HUB_KUBECONFIG}",
            "get",
            "managedclusters",
            "--output=json",
        ],
        text=True,
        capture_output=True,
        check=False,
    )
    assert result.returncode == 0, (
        f"Failed to read managedclusters from hub.\nstderr:\n{result.stderr}"
    )
    raw = result.stdout
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


def _get_drpc_protected_condition() -> dict[str, str]:
    """Read DRPC Protected / NoClusterDataConflict status from the hub API."""
    result = subprocess.run(  # noqa: S603
        [
            "oc",
            f"--kubeconfig={HUB_KUBECONFIG}",
            "get",
            "drplacementcontrol",
            "gitops-vm-protection",
            "-n",
            "openshift-dr-ops",
            "-o",
            "json",
        ],
        text=True,
        capture_output=True,
        check=False,
    )
    assert result.returncode == 0, (
        f"Failed to read DRPlacementControl status from hub.\nstderr:\n{result.stderr}"
    )
    drpc = json.loads(result.stdout)
    status = drpc.get("status", {})
    conditions = {c["type"]: c for c in status.get("conditions", [])}
    protected = conditions.get("Protected", {})
    resource_conditions = {
        c["type"]: c for c in status.get("resourceConditions", {}).get("conditions", [])
    }
    no_conflict = resource_conditions.get("NoClusterDataConflict", {})
    return {
        "phase": status.get("phase", ""),
        "progression": status.get("progression", ""),
        "protected": protected.get("status", ""),
        "protected_reason": protected.get("reason", ""),
        "protected_message": protected.get("message", ""),
        "no_cluster_data_conflict": no_conflict.get("status", ""),
        "no_cluster_data_conflict_reason": no_conflict.get("reason", ""),
    }


def _wait_for_drpc_healthy_with_recovery(
    drpc_page: DRPCPage,
    drpc_name: str,
    *,
    expected_cluster: str,
    cleanup_skip_pvcs: bool = False,
    timeout_ms: int = 1_800_000,
):
    """Wait for Healthy DR status, running cleanup when protection/action-needed appears.

    Protection error is usually transient after manual cleanup: Ramen reports
    conflicting workload data on the non-primary cluster until that spoke is
    cleaned and reconciliation completes.

    cleanup_skip_pvcs: when True, PVC/PV deletion is skipped during any recovery
    cleanup triggered inside this wait.  Must be True on the relocate path to avoid
    deleting secondary PVCs while ocp-primary is still promoting its
    VolumeGroupReplication (the same race the --skip-pvcs flag was introduced to fix).
    """
    poll_interval_ms = 30_000
    deadline = time.monotonic() + (timeout_ms / 1000)
    last_cleanup_at = 0.0

    while time.monotonic() < deadline:
        state = drpc_page.get_drpc_state(drpc_name)
        status = state["status"].strip()
        status_lower = status.lower()
        cluster = state["cluster"].strip()

        if cluster == expected_cluster and status_lower == "healthy":
            backend = _get_drpc_protected_condition()
            if backend["protected"] == "True":
                phase = backend.get("phase", "")
                # Settled phases: Relocated (after relocate) or Deployed (fresh/no action)
                # on primary; FailedOver on secondary. These are terminal until the next
                # DR action — Ramen does not auto-transition Relocated→Deployed.
                if expected_cluster == "ocp-primary":
                    if phase in {"Deployed", "Relocated"}:
                        return
                    print(
                        f"  UI Healthy + Protected=True but backend phase={phase!r}; "
                        "waiting for Deployed/Relocated on primary..."
                    )
                else:
                    if phase == "FailedOver":
                        return
                    print(
                        f"  UI Healthy + Protected=True but backend phase={phase!r}; "
                        "waiting for FailedOver on secondary..."
                    )
            if backend["protected_reason"] == "Error":
                print(
                    "WARNING: UI is Healthy but DRPC Protected=False; "
                    f"reason={backend['protected_reason']!r} "
                    f"message={backend['protected_message']!r}"
                )

        needs_cleanup = status_lower in {
            "waitonusertocleanup",
            "action needed",
            "protection error",
        } or drpc_page.is_protection_error_status(status)

        if needs_cleanup and (time.monotonic() - last_cleanup_at) > 60:
            print(f"DR status {status!r} on {cluster!r} — running non-primary cleanup")
            _run_cleanup_non_primary_cluster(skip_pvcs=cleanup_skip_pvcs)
            last_cleanup_at = time.monotonic()

        remaining_ms = int((deadline - time.monotonic()) * 1000)
        if remaining_ms <= 0:
            break
        drpc_page.page.wait_for_timeout(min(poll_interval_ms, remaining_ms))

    pytest.fail(
        f"DRPC '{drpc_name}' did not reach a settled state on cluster "
        f"'{expected_cluster}' within {timeout_ms // 1000}s. "
        "Check DRPC Protected condition and backend VRG/Ceph mirroring status."
    )


def _run_force_full_sanity_dr_flow(
    drpc_page: DRPCPage,
    drpc_name: str = "gitops-vm-protection",
):
    """Run the full failover → relocate cycle with no resume shortcuts."""
    drpc_page.assert_drpc(
        drpc_name,
        expected_policy="2m-vm",
        expected_cluster="ocp-primary",
    )
    drpc_page.assert_drpc_actions_menu(drpc_name)

    drpc_page.open_failover_dialog(drpc_name)
    drpc_page.assert_failover_dialog_contents()
    drpc_page.cancel_failover_dialog()

    drpc_page.open_failover_dialog(drpc_name)
    drpc_page.assert_failover_dialog_contents()
    # Launch probe pod before starting the clock — scheduling + image pull happen
    # in parallel with the DR operation, so the pod is idle and ready by the time
    # VMs come up on the secondary.
    failover_probe_pod = _launch_ssh_probe_pod(SECONDARY_KUBECONFIG)
    failover_started_at = time.monotonic()
    failover_initiated_utc = datetime.now(timezone.utc)
    drpc_page.initiate_failover_dialog()

    try:
        drpc_page.wait_for_failover_progress_state(drpc_name)
        drpc_page.open_failover_progress_popover(drpc_name)
        drpc_page.assert_failover_progress_popover(
            expected_target_cluster="ocp-secondary"
        )
    except AssertionError:
        pass

    post_progress_state = drpc_page.get_drpc_state(drpc_name)
    post_progress_status = post_progress_state["status"].strip().lower()
    if post_progress_status in {
        "waitonusertocleanup",
        "action needed",
        "protection error",
    }:
        _run_cleanup_non_primary_cluster()

    drpc_page.wait_for_failover_complete_state(
        drpc_name,
        expected_cluster="ocp-secondary",
        timeout_ms=900_000,
    )
    # RTO ends when all VMs are Running with SSH services on the secondary, confirmed
    # by both the Kubernetes API signal and an in-cluster TCP probe (pod pre-launched).
    failover_ssh_ips = _wait_for_vms_running_with_ssh_service(
        SECONDARY_KUBECONFIG, cluster_name="ocp-secondary"
    )
    _probe_ssh_via_pod(SECONDARY_KUBECONFIG, failover_probe_pod, failover_ssh_ips)
    _assert_rto_within_standard(phase="failover", started_at=failover_started_at)
    _wait_for_drpc_healthy_with_recovery(
        drpc_page,
        drpc_name,
        expected_cluster="ocp-secondary",
        timeout_ms=_DRPC_HEALTHY_TIMEOUT_MS,
    )
    _assert_managed_clusters_available()
    _run_dr_timestamp_validation(phase="failover", initiated_utc=failover_initiated_utc)

    state_before_relocate = drpc_page.get_drpc_state(drpc_name)
    assert state_before_relocate["cluster"] == "ocp-secondary", (
        "Expected DRPC on ocp-secondary before relocate, got "
        f"{state_before_relocate['cluster']!r}"
    )
    assert state_before_relocate["status"].strip().lower() == "healthy", (
        "Expected DR status Healthy before relocate — DRPC must be Protected=True "
        "before triggering relocate to avoid Ceph split-brain. Got "
        f"{state_before_relocate['status']!r}"
    )

    drpc_page.open_relocate_dialog(drpc_name)
    drpc_page.assert_relocate_dialog_contents()
    relocate_probe_pod = _launch_ssh_probe_pod(PRIMARY_KUBECONFIG)
    relocate_started_at = time.monotonic()
    relocate_initiated_utc = datetime.now(timezone.utc)
    drpc_page.initiate_relocate_dialog()

    try:
        drpc_page.wait_for_relocate_progress_state(drpc_name)
        drpc_page.open_failover_progress_popover(drpc_name)
        drpc_page.assert_relocate_progress_popover(
            expected_source_cluster="ocp-secondary"
        )
    except AssertionError:
        pass

    post_relocate_state = drpc_page.get_drpc_state(drpc_name)
    post_relocate_status = post_relocate_state["status"].strip().lower()
    if post_relocate_status in {
        "waitonusertocleanup",
        "action needed",
        "relocating",
    }:
        _run_cleanup_non_primary_cluster(skip_pvcs=True)

    drpc_page.wait_for_relocate_complete_state(
        drpc_name,
        expected_cluster="ocp-primary",
        timeout_ms=2_700_000,
    )
    relocate_ssh_ips = _wait_for_vms_running_with_ssh_service(
        PRIMARY_KUBECONFIG, cluster_name="ocp-primary"
    )
    _probe_ssh_via_pod(PRIMARY_KUBECONFIG, relocate_probe_pod, relocate_ssh_ips)
    _assert_rto_within_standard(phase="relocate", started_at=relocate_started_at)
    _wait_for_drpc_healthy_with_recovery(
        drpc_page,
        drpc_name,
        expected_cluster="ocp-primary",
        cleanup_skip_pvcs=True,
        timeout_ms=_DRPC_HEALTHY_TIMEOUT_MS,
    )
    _assert_managed_clusters_available()
    _run_dr_timestamp_validation(phase="relocate", initiated_utc=relocate_initiated_utc)


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
class TestUiSanity:
    """Verify the core Disaster Recovery UI flow is reachable and healthy."""

    def test_sanity_disaster_recovery_ui(self, page):
        """Sanity DR UI walkthrough after smoke: reach DR view and verify actions."""
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
        drpc_page.assert_in_disaster_recovery_view()

        # --- Policies tab ---
        drpc_page.navigate_policies_tab()
        drpc_page.assert_drpolicy(
            "2m-vm",
            expected_status="Validated",
            expected_applications="1 Application",
        )

        # --- Protected applications tab ---
        drpc_page.navigate_protected_applications_tab()
        state = drpc_page.get_drpc_state("gitops-vm-protection")
        assert state["policy"] == "2m-vm", (
            f"DRPC 'gitops-vm-protection' policy mismatch: {state['policy']!r}"
        )

        if _FORCE_FULL_SANITY:
            assert state["cluster"] == "ocp-primary", (
                "RAMENDR_SANITY_FORCE_FULL requires gitops-vm-protection on "
                f"ocp-primary before starting; got cluster={state['cluster']!r} "
                f"status={state['status']!r}"
            )
            _run_force_full_sanity_dr_flow(drpc_page)
            return

        status_lower_initial = state["status"].strip().lower()
        on_primary = state["cluster"] == "ocp-primary"
        on_secondary = state["cluster"] == "ocp-secondary"
        drpc_backend = _get_drpc_protected_condition()
        drpc_phase = (drpc_backend.get("phase") or "").strip()

        post_relocate = on_primary and drpc_phase == "Relocated"
        post_failover = on_secondary and drpc_phase == "FailedOver"
        ready_for_failover = (
            on_primary
            and status_lower_initial == "healthy"
            and drpc_phase in {"", "Deployed"}
        )
        is_already_completed = False
        failover_initiated = False
        failover_started_at: float | None = None
        failover_initiated_utc: datetime | None = None
        failover_probe_pod: str | None = None
        relocate_started_at: float | None = None
        relocate_initiated_utc: datetime | None = None
        relocate_probe_pod: str | None = None

        # Fresh flow: healthy on primary, then trigger failover.
        if ready_for_failover:
            drpc_page.assert_drpc(
                "gitops-vm-protection",
                expected_policy="2m-vm",
                expected_cluster="ocp-primary",
            )
            drpc_page.assert_drpc_actions_menu("gitops-vm-protection")

            # --- Failover popup (cancel path) ---
            drpc_page.open_failover_dialog("gitops-vm-protection")
            drpc_page.assert_failover_dialog_contents()
            drpc_page.cancel_failover_dialog()

            # --- Failover popup (initiate path) ---
            drpc_page.open_failover_dialog("gitops-vm-protection")
            drpc_page.assert_failover_dialog_contents()
            failover_probe_pod = _launch_ssh_probe_pod(SECONDARY_KUBECONFIG)
            failover_started_at = time.monotonic()
            failover_initiated_utc = datetime.now(timezone.utc)
            drpc_page.initiate_failover_dialog()
            failover_initiated = True
        elif post_failover:
            is_already_completed = status_lower_initial in {
                "failedover",
                "failover complete",
                "healthy",
                "protection error",
            }
        elif post_relocate:
            pass
        else:
            assert state["cluster"] in {"ocp-primary", "ocp-secondary"}, (
                "Unexpected DRPC cluster before DR progression checks: "
                f"{state['cluster']!r} phase={drpc_phase!r} status={state['status']!r}"
            )

        run_failover_phase = (failover_initiated or post_failover) and not post_relocate

        if run_failover_phase and (
            failover_initiated or (post_failover and not is_already_completed)
        ):
            # Best-effort failover progress path.
            try:
                drpc_page.wait_for_failover_progress_state("gitops-vm-protection")
                drpc_page.open_failover_progress_popover("gitops-vm-protection")
                drpc_page.assert_failover_progress_popover(
                    expected_target_cluster="ocp-secondary"
                )
            except AssertionError:
                pass

            # If failover is stuck in action-needed/progress states, run cleanup.
            post_progress_state = drpc_page.get_drpc_state("gitops-vm-protection")
            post_progress_status = post_progress_state["status"].strip().lower()
            if post_progress_status in {
                "waitonusertocleanup",
                "action needed",
                "protection error",
            }:
                _run_cleanup_non_primary_cluster()

        if run_failover_phase:
            # --- Wait for failover completion + healthy (up to 15 minutes) ---
            drpc_page.wait_for_failover_complete_state(
                "gitops-vm-protection",
                expected_cluster="ocp-secondary",
                timeout_ms=900_000,
            )
            # RTO ends when all VMs are Running with SSH services on the secondary,
            # confirmed by both the K8s API signal and an in-cluster TCP probe.
            if failover_probe_pod is None:
                failover_probe_pod = _launch_ssh_probe_pod(SECONDARY_KUBECONFIG)
            failover_ssh_ips = _wait_for_vms_running_with_ssh_service(
                SECONDARY_KUBECONFIG, cluster_name="ocp-secondary"
            )
            _probe_ssh_via_pod(
                SECONDARY_KUBECONFIG, failover_probe_pod, failover_ssh_ips
            )
            _assert_rto_within_standard(
                phase="failover", started_at=failover_started_at
            )
            _wait_for_drpc_healthy_with_recovery(
                drpc_page,
                "gitops-vm-protection",
                expected_cluster="ocp-secondary",
                timeout_ms=_DRPC_HEALTHY_TIMEOUT_MS,
            )

            # --- Cluster health check before relocate ---
            _assert_managed_clusters_available()
            _run_dr_timestamp_validation(
                phase="failover", initiated_utc=failover_initiated_utc
            )

            state_before_relocate = drpc_page.get_drpc_state("gitops-vm-protection")
            assert state_before_relocate["cluster"] == "ocp-secondary", (
                "Expected DRPC to be on ocp-secondary before relocate, got "
                f"{state_before_relocate['cluster']!r}"
            )
            assert state_before_relocate["status"].strip().lower() == "healthy", (
                "Expected DR status Healthy before relocate — DRPC must be Protected=True "
                "before triggering relocate to avoid Ceph split-brain. Got "
                f"{state_before_relocate['status']!r}"
            )

            # --- Relocate from secondary back to primary ---
            drpc_page.open_relocate_dialog("gitops-vm-protection")
            drpc_page.assert_relocate_dialog_contents()
            relocate_probe_pod = _launch_ssh_probe_pod(PRIMARY_KUBECONFIG)
            relocate_started_at = time.monotonic()
            relocate_initiated_utc = datetime.now(timezone.utc)
            drpc_page.initiate_relocate_dialog()

        if post_relocate or (
            drpc_page.get_drpc_state("gitops-vm-protection")["cluster"] == "ocp-primary"
            and _get_drpc_protected_condition().get("phase") == "Relocated"
        ):
            relocate_done = True
        else:
            relocate_state = drpc_page.get_drpc_state("gitops-vm-protection")
            relocate_status = relocate_state["status"].strip().lower()
            relocate_done = relocate_state[
                "cluster"
            ] == "ocp-primary" and relocate_status in {
                "relocated",
                "relocate complete",
                "healthy",
            }

        if not relocate_done:
            # Similar to failover: when Action needed appears, assert popup and run cleanup.
            try:
                drpc_page.wait_for_relocate_progress_state("gitops-vm-protection")
                drpc_page.open_failover_progress_popover("gitops-vm-protection")
                drpc_page.assert_relocate_progress_popover(
                    expected_source_cluster="ocp-secondary"
                )
            except AssertionError:
                pass

            post_relocate_state = drpc_page.get_drpc_state("gitops-vm-protection")
            post_relocate_status = post_relocate_state["status"].strip().lower()
            if post_relocate_status in {
                "waitonusertocleanup",
                "action needed",
                "relocating",
            }:
                _run_cleanup_non_primary_cluster(skip_pvcs=True)

        # --- Wait for relocate completion + healthy on primary ---
        drpc_page.wait_for_relocate_complete_state(
            "gitops-vm-protection",
            expected_cluster="ocp-primary",
            timeout_ms=2_700_000,
        )
        if relocate_probe_pod is None:
            relocate_probe_pod = _launch_ssh_probe_pod(PRIMARY_KUBECONFIG)
        relocate_ssh_ips = _wait_for_vms_running_with_ssh_service(
            PRIMARY_KUBECONFIG, cluster_name="ocp-primary"
        )
        _probe_ssh_via_pod(PRIMARY_KUBECONFIG, relocate_probe_pod, relocate_ssh_ips)
        _assert_rto_within_standard(phase="relocate", started_at=relocate_started_at)
        _wait_for_drpc_healthy_with_recovery(
            drpc_page,
            "gitops-vm-protection",
            expected_cluster="ocp-primary",
            cleanup_skip_pvcs=True,
            timeout_ms=_DRPC_HEALTHY_TIMEOUT_MS,
        )
        _assert_managed_clusters_available()
        _run_dr_timestamp_validation(
            phase="relocate", initiated_utc=relocate_initiated_utc
        )
