import importlib.util
from pathlib import Path

_HELPER = (
    Path(__file__).resolve().parents[2] / "scripts" / "lib" / "pattern_variant_yaml.py"
)
_spec = importlib.util.spec_from_file_location("pattern_variant_yaml", _HELPER)
assert _spec is not None and _spec.loader is not None
_mod = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_mod)
apply_variant_to_values_global = _mod.apply_variant_to_values_global
ensure_byoc_true = _mod.ensure_byoc_true


def test_apply_variant_replaces_cluster_group_name(tmp_path: Path):
    values = tmp_path / "values-global.yaml"
    values.write_text(
        "global:\n  pattern: ramendr-starter-kit\nmain:\n  clusterGroupName: hub\n"
    )
    apply_variant_to_values_global(values, "drpartner-s4")
    text = values.read_text()
    assert "variant: drpartner-s4" in text
    assert "clusterGroupName" not in text


def test_apply_variant_replaces_legacy_cluster_group_key(tmp_path: Path):
    values = tmp_path / "values-global.yaml"
    values.write_text("main:\n  clusterGroup: hub\n")
    apply_variant_to_values_global(values, "drpartner-minimal")
    text = values.read_text()
    assert "variant: drpartner-minimal" in text
    assert "clusterGroup:" not in text


def test_ensure_byoc_true_flips_false(tmp_path: Path):
    names = tmp_path / "values-cluster-names.yaml"
    names.write_text("byoc: false\nclusterOverrides: {}\n")
    assert ensure_byoc_true(names) is True
    assert "byoc: true" in names.read_text()
    assert ensure_byoc_true(names) is False
