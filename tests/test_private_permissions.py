"""Tests for the shared credential-permission shell helpers."""

from __future__ import annotations

import os
import stat
import subprocess
from pathlib import Path


HELPER = Path(__file__).parents[1] / "scripts/lib/private-permissions.sh"


def _run_bash(
    script: str, *, env: dict[str, str] | None = None
) -> subprocess.CompletedProcess[str]:
    command_env = os.environ.copy()
    if env:
        command_env.update(env)
    return subprocess.run(
        ["bash", "-c", f'source "{HELPER}"\n{script}'],
        check=False,
        capture_output=True,
        env=command_env,
        text=True,
    )


def _mode(path: Path) -> int:
    return stat.S_IMODE(path.stat().st_mode)


def test_owner_private_modes_without_shared_gid(tmp_path: Path) -> None:
    directory = tmp_path / "private"
    credential = directory / "credential"
    directory.mkdir(mode=0o755)
    credential.write_text("secret", encoding="utf-8")
    credential.chmod(0o644)

    result = _run_bash(
        f'set_private_permissions "{directory}" directory\n'
        f'set_private_permissions "{credential}"',
        env={"CI_SHARED_WORKSPACE_GID": ""},
    )

    assert result.returncode == 0, result.stderr
    assert _mode(directory) == 0o700
    assert _mode(credential) == 0o600


def test_shared_group_modes(tmp_path: Path) -> None:
    directory = tmp_path / "shared"
    credential = directory / "credential"
    directory.mkdir()
    credential.write_text("secret", encoding="utf-8")

    result = _run_bash(
        f'set_private_permissions "{directory}" directory\n'
        f'set_private_permissions "{credential}"',
        env={"CI_SHARED_WORKSPACE_GID": str(os.getgid())},
    )

    assert result.returncode == 0, result.stderr
    assert _mode(directory) == 0o750
    assert _mode(credential) == 0o640


def test_redundant_chgrp_failure_is_accepted(tmp_path: Path) -> None:
    credential = tmp_path / "credential"
    credential.write_text("secret", encoding="utf-8")

    result = _run_bash(
        f'chgrp() {{ return 1; }}\nset_private_permissions "{credential}"',
        env={"CI_SHARED_WORKSPACE_GID": str(credential.stat().st_gid)},
    )

    assert result.returncode == 0, result.stderr
    assert _mode(credential) == 0o640


def test_chgrp_failure_for_wrong_group_is_fatal(tmp_path: Path) -> None:
    credential = tmp_path / "credential"
    credential.write_text("secret", encoding="utf-8")

    result = _run_bash(
        "chgrp() { return 1; }\n"
        "_private_permissions_gid() { echo 999999; }\n"
        f'set_private_permissions "{credential}"',
        env={"CI_SHARED_WORKSPACE_GID": str(os.getgid())},
    )

    assert result.returncode != 0
    assert "Failed to assign shared group" in result.stderr


def test_cluster_credentials_are_all_restricted(tmp_path: Path) -> None:
    install_dir = tmp_path / "install"
    auth_dir = install_dir / "auth"
    auth_dir.mkdir(parents=True)
    kubeconfig = auth_dir / "kubeconfig"
    password = auth_dir / "kubeadmin-password"
    kubeconfig.write_text("kubeconfig", encoding="utf-8")
    password.write_text("password", encoding="utf-8")

    result = _run_bash(
        f'set_cluster_credentials_permissions "{install_dir}"',
        env={"CI_SHARED_WORKSPACE_GID": ""},
    )

    assert result.returncode == 0, result.stderr
    assert _mode(install_dir) == 0o700
    assert _mode(auth_dir) == 0o700
    assert _mode(kubeconfig) == 0o600
    assert _mode(password) == 0o600


def test_invalid_shared_gid_is_rejected(tmp_path: Path) -> None:
    credential = tmp_path / "credential"
    credential.write_text("secret", encoding="utf-8")

    result = _run_bash(
        f'set_private_permissions "{credential}"',
        env={"CI_SHARED_WORKSPACE_GID": "not-a-gid"},
    )

    assert result.returncode != 0
    assert "must be a numeric group ID" in result.stderr
