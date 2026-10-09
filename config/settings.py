"""Project settings loaded from environment variables."""

import os
from pathlib import Path


def _default_base_url() -> str:
    base_domain = os.getenv("BASE_DOMAIN", "")
    if base_domain:
        return f"https://console-openshift-console.apps.hub.{base_domain}"
    return ""


BASE_URL = os.getenv("RAMENDR_BASE_URL") or _default_base_url()
# OpenShift self-signed certs trigger ERR_CERT_AUTHORITY_INVALID; ignore by default.
IGNORE_HTTPS_ERRORS = os.getenv("RAMENDR_IGNORE_HTTPS_ERRORS", "true").lower() == "true"

HUB_USERNAME = os.getenv("RAMENDR_HUB_USERNAME", "kubeadmin")


def _expand(path: str) -> str:
    """Expand ~ in a path string."""
    return str(Path(path).expanduser())


def _kubeconfig(explicit_env: str, install_dir_env: str, default_rel: str) -> str:
    """Resolve a kubeconfig path (CI + local).

    Precedence matches scripts/redeploy.sh and scripts/dr-validation/lib.sh:
    RAMENDR_*_KUBECONFIG → $INSTALL_DIR/auth/kubeconfig → ~/git/... default.
    """
    explicit = os.getenv(explicit_env, "").strip()
    if explicit:
        return _expand(explicit)
    install_dir = os.getenv(install_dir_env, "").strip()
    if install_dir:
        return _expand(str(Path(install_dir) / "auth" / "kubeconfig"))
    return _expand(default_rel)


HUB_KUBECONFIG = _kubeconfig(
    "RAMENDR_HUB_KUBECONFIG",
    "HUB_INSTALL_DIR",
    "~/git/hub-cluster-install/auth/kubeconfig",
)
PRIMARY_KUBECONFIG = _kubeconfig(
    "RAMENDR_PRIMARY_KUBECONFIG",
    "PRIMARY_INSTALL_DIR",
    "~/git/ocp-primary-install/auth/kubeconfig",
)
SECONDARY_KUBECONFIG = _kubeconfig(
    "RAMENDR_SECONDARY_KUBECONFIG",
    "SECONDARY_INSTALL_DIR",
    "~/git/ocp-secondary-install/auth/kubeconfig",
)


def _read_kubeadmin_password() -> str:
    """Read the kubeadmin password written by openshift-install into the hub auth dir."""
    pw_file = Path(HUB_KUBECONFIG).parent / "kubeadmin-password"
    try:
        return pw_file.read_text().strip()
    except OSError:
        return ""


HUB_PASSWORD = os.getenv("RAMENDR_HUB_PASSWORD") or _read_kubeadmin_password()

# Edge VMs in gitops-vms: 2 Linux + 1 Windows 2022 + 1 Windows 2025.
EXPECTED_EDGE_VM_COUNT = int(
    os.getenv("RAMENDR_EXPECTED_VMS", os.getenv("RAMENDR_MIN_VM_COUNT", "4"))
)
