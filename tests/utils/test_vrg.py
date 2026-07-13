"""Unit tests for VolumeReplicationGroup smoke helpers."""

from __future__ import annotations

import pytest

from tests.utils.vrg import (
    active_cluster_from_drpc,
    protected_pvc_index,
    pvc_replication_issues,
    vm_os_and_data_pvc_names,
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


def test_vm_os_and_data_pvc_names_additional_disks() -> None:
    vm = {
        "metadata": {"name": "rhel9-node-001"},
        "spec": {
            "dataVolumeTemplates": [
                {"metadata": {"name": "rhel9-node-001"}},
                {"metadata": {"name": "rhel9-node-001-data"}},
            ]
        },
    }
    assert vm_os_and_data_pvc_names(vm) == ("rhel9-node-001", "rhel9-node-001-data")


def test_vm_os_and_data_pvc_names_additional_pvc_disks() -> None:
    vm = {
        "metadata": {"name": "rhel9-node-pvc-001"},
        "spec": {
            "dataVolumeTemplates": [
                {"metadata": {"name": "rhel9-node-pvc-001"}},
            ]
        },
    }
    assert vm_os_and_data_pvc_names(vm) == (
        "rhel9-node-pvc-001",
        "rhel9-node-pvc-001-data",
    )


@pytest.mark.parametrize(
    "dvts,expected_fragment",
    [
        ([], "got 0"),
        (
            [
                {"metadata": {"name": "vm-a-os1"}},
                {"metadata": {"name": "vm-a-os2"}},
            ],
            "got 2",
        ),
    ],
)
def test_vm_os_and_data_pvc_names_raises_for_invalid_os_dvt_count(
    dvts: list[dict],
    expected_fragment: str,
) -> None:
    vm = {"metadata": {"name": "vm-a"}, "spec": {"dataVolumeTemplates": dvts}}
    with pytest.raises(ValueError, match=expected_fragment):
        vm_os_and_data_pvc_names(vm)


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
