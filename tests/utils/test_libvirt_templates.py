"""Placeholder checks for libvirt agent-based install-config examples."""

from pathlib import Path

import yaml

EXAMPLES = Path(__file__).resolve().parents[2] / "install-config-examples" / "libvirt"


def test_install_config_example_has_compact_platform_none():
    text = (EXAMPLES / "install-config.yaml.example").read_text()
    assert "replicas: 0" in text
    assert "none: {}" in text
    assert "<CLUSTER_NAME>" in text
    assert "<PULL_SECRET_JSON>" in text
    assert "aws:" not in text


def test_agent_config_example_has_rendezvous_placeholder():
    text = (EXAMPLES / "agent-config.yaml.example").read_text()
    assert "<RENDEZVOUS_IP>" in text
    assert "<CLUSTER_NAME>" in text
    assert "rootDeviceHints" in text
    assert "deviceName: /dev/vda" in text
    assert "<MAC_0>" in text
    assert "<MAC_2>" in text


def test_libvirt_odf_overlays_use_localblock_not_gp3():
    overlay_dir = Path(__file__).resolve().parents[2] / "overrides" / "libvirt"
    for name in ("values-None.yaml", "values-BareMetal.yaml"):
        data = yaml.safe_load((overlay_dir / name).read_text())
        pvc = data["odf"]["osd"]["pvc"]
        assert pvc["storageClassName"] == "localblock"
        assert pvc["storage"] == "100Gi"


def test_libvirt_default_install_dirs_use_hypervisor_hostname(tmp_path):
    import os
    import subprocess

    repo = Path(__file__).resolve().parents[2]
    env = os.environ.copy()
    env["LIBVIRT_HOST"] = "ocp-edge111.example.com"
    env["HOME"] = str(tmp_path)
    for key in (
        "HUB_INSTALL_DIR",
        "PRIMARY_INSTALL_DIR",
        "SECONDARY_INSTALL_DIR",
        "LIBVIRT_INSTALL_ROOT",
    ):
        env.pop(key, None)
    script = f"""
set -euo pipefail
source {repo}/scripts/lib/libvirt-common.sh
libvirt_apply_default_install_dirs
printf '%s\\n' "$(libvirt_hypervisor_label)"
printf '%s\\n' "$HUB_INSTALL_DIR"
printf '%s\\n' "$PRIMARY_INSTALL_DIR"
printf '%s\\n' "$SECONDARY_INSTALL_DIR"
"""
    out = (
        subprocess.check_output(["bash", "-c", script], env=env, text=True)
        .strip()
        .splitlines()
    )
    assert out[0] == "ocp-edge111"
    assert out[1] == str(tmp_path / "git/libvirt/ocp-edge111/hub-cluster-install")
    assert out[2] == str(tmp_path / "git/libvirt/ocp-edge111/ocp-primary-install")
    assert out[3] == str(tmp_path / "git/libvirt/ocp-edge111/ocp-secondary-install")
