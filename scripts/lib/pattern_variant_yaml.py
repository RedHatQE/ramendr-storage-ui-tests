"""Rewrite starter-kit values files for a v1.3 PATTERN_VARIANT.

Used by scripts/lib/pattern-variant.sh (install-time) and unit tests.
"""

from __future__ import annotations

import sys
from pathlib import Path

import yaml

RHDR_CATALOG_IMAGE = (
    "quay.io/openshift-virtualization-dr/rhdr-mirror"
    "@sha256:560cd133649049ca01413aeff9bc89fea644f02a2953f632abe429ffa8e196dd"
)

RHDR_INDEX_IMAGES = {
    "rhdr-ramen": {
        "name": "ramen-catalog",
        "image": RHDR_CATALOG_IMAGE,
        "namespace": "openshift-operators",
    }
}

RHDR_HUB_MCO_SUBSCRIPTION = {
    "name": "rhdr-multicluster-operator",
    "namespace": "openshift-operators",
    "source": "ramen-catalog",
}

RHDR_SPOKE_CLUSTER_SUBSCRIPTION = {
    "name": "rhdr-cluster-operator",
    "namespace": "openshift-operators",
    "channel": "stable-4.22",
    "source": "ramen-catalog",
}


def apply_variant_to_values_global(path: Path | str, variant: str) -> None:
    """Set main.variant and drop legacy main.clusterGroupName / main.clusterGroup."""
    values_path = Path(path)
    data = yaml.safe_load(values_path.read_text()) or {}
    main = data.setdefault("main", {})
    main.pop("clusterGroupName", None)
    main.pop("clusterGroup", None)
    main["variant"] = variant
    values_path.write_text(
        yaml.safe_dump(data, sort_keys=False, default_flow_style=False)
    )


def ensure_byoc_true(path: Path | str) -> bool:
    """Force byoc: true in overrides/values-cluster-names.yaml. Return True if changed."""
    cluster_path = Path(path)
    data = yaml.safe_load(cluster_path.read_text()) or {}
    if data.get("byoc") is True:
        return False
    data["byoc"] = True
    cluster_path.write_text(
        yaml.safe_dump(data, sort_keys=False, default_flow_style=False)
    )
    return True


def _ensure_hub_rhdr(cluster_group: dict) -> bool:
    changed = False
    index_images = cluster_group.setdefault("indexImages", {})
    if index_images.get("rhdr-ramen") != RHDR_INDEX_IMAGES["rhdr-ramen"]:
        index_images["rhdr-ramen"] = dict(RHDR_INDEX_IMAGES["rhdr-ramen"])
        changed = True
    subscriptions = cluster_group.setdefault("subscriptions", {})
    if subscriptions.get("odf-multicluster-orchestrator") != RHDR_HUB_MCO_SUBSCRIPTION:
        subscriptions["odf-multicluster-orchestrator"] = dict(RHDR_HUB_MCO_SUBSCRIPTION)
        changed = True
    return changed


def _ensure_spoke_rhdr(cluster_group: dict) -> bool:
    changed = False
    index_images = cluster_group.setdefault("indexImages", {})
    if index_images.get("rhdr-ramen") != RHDR_INDEX_IMAGES["rhdr-ramen"]:
        index_images["rhdr-ramen"] = dict(RHDR_INDEX_IMAGES["rhdr-ramen"])
        changed = True
    subscriptions = cluster_group.setdefault("subscriptions", {})
    if subscriptions.get("rhdr-cluster-operator") != RHDR_SPOKE_CLUSTER_SUBSCRIPTION:
        subscriptions["rhdr-cluster-operator"] = dict(RHDR_SPOKE_CLUSTER_SUBSCRIPTION)
        changed = True
    return changed


def apply_rhdr_catalog(upstream_dir: Path | str, variant: str) -> bool:
    """Ensure hub + spoke variant values install Ramen from the RHDR catalog."""
    root = Path(upstream_dir)
    changed = False
    hub_path = root / "variants" / variant / f"values-{variant}.yaml"
    resilient_path = root / "variants" / variant / "values-resilient.yaml"

    if hub_path.is_file():
        data = yaml.safe_load(hub_path.read_text()) or {}
        cluster_group = data.setdefault("clusterGroup", {})
        if _ensure_hub_rhdr(cluster_group):
            data["clusterGroup"] = cluster_group
            hub_path.write_text(
                yaml.safe_dump(data, sort_keys=False, default_flow_style=False)
            )
            changed = True

    if resilient_path.is_file():
        data = yaml.safe_load(resilient_path.read_text()) or {}
        cluster_group = data.setdefault("clusterGroup", {})
        if _ensure_spoke_rhdr(cluster_group):
            data["clusterGroup"] = cluster_group
            resilient_path.write_text(
                yaml.safe_dump(data, sort_keys=False, default_flow_style=False)
            )
            changed = True

    return changed


def main(argv: list[str] | None = None) -> int:
    args = list(sys.argv[1:] if argv is None else argv)
    if len(args) < 2:
        print(
            "Usage: pattern_variant_yaml.py apply <values-global.yaml> <variant>\n"
            "       pattern_variant_yaml.py byoc <values-cluster-names.yaml>\n"
            "       pattern_variant_yaml.py rhdr <upstream-dir> <variant>",
            file=sys.stderr,
        )
        return 2
    command, path = args[0], args[1]
    if command == "apply":
        if len(args) < 3:
            print("apply requires <values-global.yaml> <variant>", file=sys.stderr)
            return 2
        apply_variant_to_values_global(path, args[2])
        return 0
    if command == "byoc":
        ensure_byoc_true(path)
        return 0
    if command == "rhdr":
        if len(args) < 3:
            print("rhdr requires <upstream-dir> <variant>", file=sys.stderr)
            return 2
        apply_rhdr_catalog(path, args[2])
        return 0
    print(f"Unknown command: {command}", file=sys.stderr)
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
