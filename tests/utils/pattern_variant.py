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
    """2m-vm DRPolicy + gitops-vm-protection DRPC exist on the odf variant."""
    return PATTERN_VARIANT == "odf"


def hub_argocd_namespace() -> str:
    """Namespace that holds child Argo Applications for the installed BOM."""
    if PATTERN_VARIANT == "drpartner-minimal":
        return "ramendr-starter-kit-minimal"
    return f"ramendr-starter-kit-{PATTERN_VARIANT}"
