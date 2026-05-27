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


def _expand(env_var: str, default: str) -> str:
    """Read an env var and expand ~ in the result (or the default)."""
    return str(Path(os.getenv(env_var, default)).expanduser())


def _read_kubeadmin_password() -> str:
    """Read the kubeadmin password written by openshift-install into the hub auth dir."""
    pw_file = (
        Path(
            _expand(
                "RAMENDR_HUB_KUBECONFIG", "~/git/hub-cluster-install/auth/kubeconfig"
            )
        ).parent
        / "kubeadmin-password"
    )
    try:
        return pw_file.read_text().strip()
    except OSError:
        return ""


HUB_PASSWORD = os.getenv("RAMENDR_HUB_PASSWORD") or _read_kubeadmin_password()

HUB_KUBECONFIG = _expand(
    "RAMENDR_HUB_KUBECONFIG", "~/git/hub-cluster-install/auth/kubeconfig"
)
PRIMARY_KUBECONFIG = _expand(
    "RAMENDR_PRIMARY_KUBECONFIG", "~/git/ocp-primary-install/auth/kubeconfig"
)
SECONDARY_KUBECONFIG = _expand(
    "RAMENDR_SECONDARY_KUBECONFIG", "~/git/ocp-secondary-install/auth/kubeconfig"
)
