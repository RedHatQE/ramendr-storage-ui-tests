"""Helpers for VolumeReplicationGroup checks in smoke tests."""

from __future__ import annotations

import json
import os
import time
from typing import Any, Callable

GITOPS_VM_NAMESPACE = "gitops-vms"
DR_OPS_NAMESPACE = "openshift-dr-ops"
GITOPS_VM_DRPC = "gitops-vm-protection"


def active_cluster_from_drpc(drpc: dict) -> str:
    """Return the spoke cluster name that currently hosts gitops-vms VMs."""
    preferred = drpc.get("spec", {}).get("preferredCluster", "ocp-primary")
    drpc_phase = drpc.get("status", {}).get("phase", "")
    if drpc_phase == "FailedOver":
        return "ocp-secondary" if preferred == "ocp-primary" else "ocp-primary"
    return preferred


def spoke_kubeconfig(
    active_cluster: str,
    *,
    primary_kubeconfig: str,
    secondary_kubeconfig: str,
) -> str:
    if active_cluster == "ocp-primary":
        return primary_kubeconfig
    return secondary_kubeconfig


def load_drpc(hub_kubeconfig: str, drpc_name: str = GITOPS_VM_DRPC) -> dict:
    from utils.oc import run_oc

    raw = run_oc(
        [
            "get",
            "drplacementcontrol",
            drpc_name,
            "-n",
            DR_OPS_NAMESPACE,
            "--output=json",
        ],
        hub_kubeconfig,
    )
    return json.loads(raw)


def drpc_condition(drpc: dict, cond_type: str) -> dict[str, Any]:
    """Return a DRPC status condition by type, or an empty dict."""
    for cond in drpc.get("status", {}).get("conditions") or []:
        if cond.get("type") == cond_type:
            return cond
    return {}


def drpc_is_protected(drpc: dict) -> bool:
    return drpc_condition(drpc, "Protected").get("status") == "True"


def wait_for_drpc_protected(
    hub_kubeconfig: str,
    drpc_name: str = GITOPS_VM_DRPC,
    *,
    timeout_seconds: float | None = None,
    poll_seconds: float | None = None,
    load_fn: Callable[[str, str], dict] | None = None,
) -> dict:
    """Poll until DRPC Protected=True (cluster-data upload finished).

    Fresh deploys often show UI Critical while ClusterDataProtected is still
    Uploading. Callers should wait here instead of asserting Healthy immediately.
    """
    timeout = timeout_seconds
    if timeout is None:
        timeout = float(
            os.getenv("RAMENDR_SMOKE_DRPC_PROTECTED_TIMEOUT_SECONDS", "1800")
        )
    poll = poll_seconds
    if poll is None:
        poll = float(os.getenv("RAMENDR_SMOKE_DRPC_PROTECTED_POLL_SECONDS", "15"))
    loader = load_fn or load_drpc
    deadline = time.monotonic() + timeout
    last: dict = {}
    while time.monotonic() < deadline:
        last = loader(hub_kubeconfig, drpc_name)
        if drpc_is_protected(last):
            return last
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            break
        time.sleep(min(poll, remaining))

    cond = drpc_condition(last, "Protected")
    phase = (last.get("status") or {}).get("phase", "")
    raise TimeoutError(
        f"DRPlacementControl {drpc_name} Protected!=True after {timeout:.0f}s "
        f"(phase={phase!r} status={cond.get('status')!r} "
        f"reason={cond.get('reason')!r} message={cond.get('message')!r}). "
        "Cluster-data protection may still be uploading, or recipe reconcile failed."
    )


def vm_os_and_data_pvc_names(vm: dict) -> tuple[str, str]:
    """Return (os_pvc_name, data_pvc_name) for a gitops-vms VirtualMachine."""
    name = vm["metadata"]["name"]
    dvts = vm.get("spec", {}).get("dataVolumeTemplates", [])
    os_dvts = [
        d for d in dvts if not d.get("metadata", {}).get("name", "").endswith("-data")
    ]
    if len(os_dvts) != 1:
        raise ValueError(
            f"{name}: expected exactly one OS DataVolumeTemplate, got {len(os_dvts)}"
        )
    os_pvc = os_dvts[0]["metadata"]["name"]
    return os_pvc, f"{name}-data"


def protected_pvc_index(vrg: dict) -> dict[str, dict[str, Any]]:
    """Map PVC name -> protectedPVC entry for gitops-vms in a VRG status."""
    index: dict[str, dict[str, Any]] = {}
    for entry in vrg.get("status", {}).get("protectedPVCs") or []:
        if entry.get("namespace") == GITOPS_VM_NAMESPACE and entry.get("name"):
            index[str(entry["name"])] = entry
    return index


def _pvc_condition(entry: dict, cond_type: str) -> dict | None:
    for cond in entry.get("conditions") or []:
        if cond.get("type") == cond_type:
            return cond
    return None


def pvc_replication_issues(pvc_name: str, entry: dict) -> list[str]:
    """Return human-readable issues when a VRG protectedPVC is not replication-healthy."""
    issues: list[str] = []
    data_ready = _pvc_condition(entry, "DataReady")
    if not data_ready or data_ready.get("status") != "True":
        reason = (data_ready or {}).get("reason", "missing")
        issues.append(f"DataReady not True (reason={reason!r})")

    cluster_prot = _pvc_condition(entry, "ClusterDataProtected")
    data_prot = _pvc_condition(entry, "DataProtected")
    cluster_ok = cluster_prot and cluster_prot.get("status") == "True"
    data_ok = data_prot and (
        data_prot.get("status") == "True"
        or data_prot.get("reason") in {"Replicating", "Uploaded"}
    )
    if not cluster_ok and not data_ok:
        cluster_reason = (cluster_prot or {}).get("reason", "missing")
        data_reason = (data_prot or {}).get("reason", "missing")
        issues.append(
            "replication not healthy "
            f"(ClusterDataProtected reason={cluster_reason!r}, "
            f"DataProtected reason={data_reason!r})"
        )
    return [f"{pvc_name}: {issue}" for issue in issues]


def load_vrg(kubeconfig: str, drpc_name: str = GITOPS_VM_DRPC) -> dict:
    from utils.oc import run_oc

    raw = run_oc(
        [
            "get",
            "volumereplicationgroup",
            drpc_name,
            "-n",
            DR_OPS_NAMESPACE,
            "--output=json",
        ],
        kubeconfig,
    )
    return json.loads(raw)
