"""Unit tests for VolumeReplicationGroup smoke helpers."""

from __future__ import annotations

import pytest

from tests.utils.vrg import (
    active_cluster_from_drpc,
    drpc_condition,
    drpc_is_protected,
    protected_pvc_index,
    pvc_replication_issues,
    vm_pvc_names,
    wait_for_drpc_protected,
)


def test_drpc_is_protected() -> None:
    protected = {
        "status": {
            "conditions": [
                {"type": "Protected", "status": "True", "reason": "Protected"}
            ]
        }
    }
    uploading = {
        "status": {
            "conditions": [
                {
                    "type": "Protected",
                    "status": "False",
                    "reason": "Uploading",
                    "message": "ClusterDataProtected Uploading",
                }
            ]
        }
    }
    assert drpc_is_protected(protected)
    assert not drpc_is_protected(uploading)
    assert drpc_condition(uploading, "Protected")["reason"] == "Uploading"


def test_wait_for_drpc_protected_returns_when_true() -> None:
    drpc = {
        "status": {
            "phase": "Deployed",
            "conditions": [{"type": "Protected", "status": "True"}],
        }
    }
    assert (
        wait_for_drpc_protected(
            "kc",
            timeout_seconds=1,
            poll_seconds=0,
            load_fn=lambda *_args: drpc,
        )
        == drpc
    )


def test_wait_for_drpc_protected_times_out_while_uploading() -> None:
    drpc = {
        "status": {
            "phase": "Deployed",
            "conditions": [
                {
                    "type": "Protected",
                    "status": "False",
                    "reason": "Uploading",
                    "message": "ClusterDataProtected",
                }
            ],
        }
    }
    with pytest.raises(TimeoutError, match="Uploading"):
        wait_for_drpc_protected(
            "kc",
            timeout_seconds=0.02,
            poll_seconds=0.01,
            load_fn=lambda *_args: drpc,
        )


def test_active_cluster_from_drpc_failed_over() -> None:
    drpc = {
        "spec": {"preferredCluster": "ocp-primary"},
        "status": {"phase": "FailedOver"},
    }
    assert active_cluster_from_drpc(drpc) == "ocp-secondary"


@pytest.mark.parametrize(
    "phase",
    ["Deployed", "Relocated", ""],
)
def test_active_cluster_from_drpc_returns_preferred_when_not_failed_over(
    phase: str,
) -> None:
    drpc = {
        "spec": {"preferredCluster": "ocp-primary"},
        "status": {"phase": phase},
    }
    assert active_cluster_from_drpc(drpc) == "ocp-primary"


def test_vm_pvc_names_os_and_data_dvts() -> None:
    vm = {
        "metadata": {"name": "rhel9-node-001"},
        "spec": {
            "dataVolumeTemplates": [
                {"metadata": {"name": "rhel9-node-001"}},
                {"metadata": {"name": "rhel9-node-001-data"}},
            ]
        },
    }
    assert vm_pvc_names(vm) == ["rhel9-node-001", "rhel9-node-001-data"]


def test_vm_pvc_names_os_disk_only() -> None:
    vm = {
        "metadata": {"name": "rhel9-node-001"},
        "spec": {
            "dataVolumeTemplates": [
                {"metadata": {"name": "rhel9-node-001"}},
            ]
        },
    }
    assert vm_pvc_names(vm) == ["rhel9-node-001"]


def test_vm_pvc_names_standalone_data_pvc_volume() -> None:
    vm = {
        "metadata": {"name": "rhel9-node-pvc-001"},
        "spec": {
            "dataVolumeTemplates": [
                {"metadata": {"name": "rhel9-node-pvc-001"}},
            ],
            "template": {
                "spec": {
                    "volumes": [
                        {"dataVolume": {"name": "rhel9-node-pvc-001"}},
                        {
                            "persistentVolumeClaim": {
                                "claimName": "rhel9-node-pvc-001-data"
                            }
                        },
                        {"cloudInitNoCloud": {}},
                    ]
                }
            },
        },
    }
    assert vm_pvc_names(vm) == [
        "rhel9-node-pvc-001",
        "rhel9-node-pvc-001-data",
    ]


def test_vm_pvc_names_raises_when_no_disks() -> None:
    vm = {"metadata": {"name": "vm-a"}, "spec": {"dataVolumeTemplates": []}}
    with pytest.raises(ValueError, match="no PVC or DataVolume disks"):
        vm_pvc_names(vm)


def test_protected_pvc_index_filters_namespace() -> None:
    vrg = {
        "status": {
            "protectedPVCs": [
                {"namespace": "gitops-vms", "name": "vm-a"},
                {"namespace": "other", "name": "vm-b"},
            ]
        }
    }
    assert protected_pvc_index(vrg) == {"vm-a": vrg["status"]["protectedPVCs"][0]}


def test_pvc_replication_issues_reports_missing_data_ready() -> None:
    entry = {
        "conditions": [
            {
                "type": "DataReady",
                "status": "False",
                "reason": "NotReady",
            }
        ]
    }
    issues = pvc_replication_issues("vm-a", entry)
    assert issues
    assert "DataReady not True" in issues[0]


def test_pvc_replication_issues_accepts_replicating() -> None:
    entry = {
        "conditions": [
            {"type": "DataReady", "status": "True", "reason": "Ready"},
            {
                "type": "DataProtected",
                "status": "False",
                "reason": "Replicating",
            },
        ]
    }
    assert pvc_replication_issues("vm-a", entry) == []


def test_pvc_replication_issues_accepts_cluster_data_protected() -> None:
    entry = {
        "conditions": [
            {"type": "DataReady", "status": "True", "reason": "Ready"},
            {
                "type": "ClusterDataProtected",
                "status": "True",
                "reason": "Uploaded",
            },
        ]
    }
    assert pvc_replication_issues("vm-a", entry) == []
