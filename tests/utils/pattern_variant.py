"""Starter-kit install variant helpers for tests and skip conditions.

PATTERN_VARIANT maps to ramendr-starter-kit v1.3 ``main.variant``:
odf, drpartner-s4, drpartner-minimal. Unset means the QE mixed-fleet fork
(``main.clusterGroupName: hub``).
"""

from __future__ import annotations

import os

PATTERN_VARIANT = os.getenv("PATTERN_VARIANT", "").strip()

PARTNER_VARIANTS = frozenset({"drpartner-s4", "drpartner-minimal"})
V13_VARIANTS = frozenset({"odf", "drpartner-s4", "drpartner-minimal"})


def is_qe_mixed_fleet() -> bool:
    """True when tests should expect the QE 4-VM Windows+Linux gitops-vms fleet."""
    return PATTERN_VARIANT == ""


def is_v13_variant() -> bool:
    return PATTERN_VARIANT in V13_VARIANTS


def is_partner_variant() -> bool:
    return PATTERN_VARIANT in PARTNER_VARIANTS


def is_minimal_variant() -> bool:
    return PATTERN_VARIANT == "drpartner-minimal"


def has_s4_storage() -> bool:
    """Dell partner BOM deploys hub vp-s4-storage (S3 buckets + credentials)."""
    return PATTERN_VARIANT == "drpartner-s4"


def has_odf_mirrorpeer() -> bool:
    """ODF StorageCluster + MirrorPeer exist on the QE fork and the odf variant."""
    return PATTERN_VARIANT not in PARTNER_VARIANTS


def has_edge_vms() -> bool:
    """gitops-vms edge VMs are disabled on partner variants."""
    return PATTERN_VARIANT not in PARTNER_VARIANTS


def has_vm_drpc() -> bool:
    """2m-vm DRPolicy + gitops-vm-protection DRPC exist on QE fork and odf."""
    return PATTERN_VARIANT not in PARTNER_VARIANTS
