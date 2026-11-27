"""Starter-kit install variant helpers for tests and skip conditions.

PATTERN_VARIANT selects the install BOM (main.variant): odf (default),
drpartner-s4, or drpartner-minimal.
"""

from __future__ import annotations

import os

DEFAULT_PATTERN_VARIANT = "odf"
PATTERN_VARIANT = (
    os.getenv("PATTERN_VARIANT", DEFAULT_PATTERN_VARIANT).strip()
    or DEFAULT_PATTERN_VARIANT
)

PARTNER_VARIANTS = frozenset({"drpartner-s4", "drpartner-minimal"})
ALL_VARIANTS = frozenset({"odf", "drpartner-s4", "drpartner-minimal"})

# DRPolicy names on the pinned fork branch (regional-dr chart). The VM policy
# backs the gitops-vm-protection DRPC; override for a fork with other RPO names.
VM_DRPOLICY = os.getenv("RAMENDR_VM_DRPOLICY", "5m-vm").strip() or "5m-vm"
NOVM_DRPOLICY = os.getenv("RAMENDR_NOVM_DRPOLICY", "5m-novm").strip() or "5m-novm"


def is_qe_mixed_fleet() -> bool:
    """True when tests should expect the QE 4-VM Windows+Linux gitops-vms fleet."""
    return PATTERN_VARIANT == "odf"


def is_v13_variant() -> bool:
    return PATTERN_VARIANT in ALL_VARIANTS


def is_partner_variant() -> bool:
    return PATTERN_VARIANT in PARTNER_VARIANTS


def is_minimal_variant() -> bool:
    return PATTERN_VARIANT == "drpartner-minimal"


def has_s4_storage() -> bool:
    """drpartner-s4 deploys hub vp-s4-storage (S3 buckets + credentials)."""
    return PATTERN_VARIANT == "drpartner-s4"


def has_odf_mirrorpeer() -> bool:
    """ODF StorageCluster + MirrorPeer exist on the odf variant."""
    return PATTERN_VARIANT == "odf"


def has_edge_vms() -> bool:
    """gitops-vms edge VMs are disabled on partner variants."""
    return PATTERN_VARIANT == "odf"


def has_vm_drpc() -> bool:
    """The VM DRPolicy + gitops-vm-protection DRPC exist on the odf variant."""
    return PATTERN_VARIANT == "odf"


def vm_drpolicy_name() -> str:
    """DRPolicy with vmSupport, referenced by gitops-vm-protection."""
    return VM_DRPOLICY


def novm_drpolicy_name() -> str:
    """DRPolicy without vmSupport (odf secondary; drpartner-s4 only policy)."""
    return NOVM_DRPOLICY


def hub_argocd_namespace() -> str:
    """Namespace that holds hub Argo Applications (Validated Patterns GitOps)."""
    return "vp-gitops"


def hub_pattern_app_name() -> str:
    """Parent Pattern Application name in hub_argocd_namespace()."""
    if PATTERN_VARIANT == "drpartner-minimal":
        return "ramendr-starter-kit-minimal"
    return f"ramendr-starter-kit-{PATTERN_VARIANT}"
