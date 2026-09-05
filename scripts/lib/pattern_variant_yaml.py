"""Rewrite starter-kit values files for a v1.3 PATTERN_VARIANT.

Used by scripts/lib/pattern-variant.sh (install-time) and unit tests.

Preview RHDR (rhdr-catalog / rhdr-multicluster-operator / extraObjects IDMS) is
committed in the fork; this helper only selects main.variant and BYOC.
"""

from __future__ import annotations

import sys
from pathlib import Path

import yaml


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


def main(argv: list[str] | None = None) -> int:
    args = list(sys.argv[1:] if argv is None else argv)
    if len(args) < 2:
        print(
            "Usage: pattern_variant_yaml.py apply <values-global.yaml> <variant>\n"
            "       pattern_variant_yaml.py byoc <values-cluster-names.yaml>",
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
    print(f"Unknown command: {command}", file=sys.stderr)
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
