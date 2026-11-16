"""Tests for the shared credential-permission shell helpers."""

from __future__ import annotations

import os
import stat
import subprocess
from pathlib import Path

import pytest


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


@pytest.mark.parametrize(
    ("kind", "private_mode", "shared_mode"),
    [("file", 0o600, 0o640), ("directory", 0o700, 0o750)],
)
@pytest.mark.parametrize("shared", [False, True], ids=["private", "shared"])
def test_correct_mode_skips_chmod(
    tmp_path: Path, kind: str, private_mode: int, shared_mode: int, shared: bool
) -> None:
    path = tmp_path / "credential"
    if kind == "directory":
        path.mkdir()
    else:
        path.write_text("secret", encoding="utf-8")
    mode = shared_mode if shared else private_mode
    path.chmod(mode)

    result = _run_bash(
        "chgrp() { return 1; }\n"
        'chmod() { echo "unexpected chmod" >&2; return 1; }\n'
        f'set_private_permissions "{path}" {kind}',
        env={"CI_SHARED_WORKSPACE_GID": str(path.stat().st_gid) if shared else ""},
    )

    assert result.returncode == 0, result.stderr
    assert _mode(path) == mode


@pytest.mark.parametrize("kind", ["file", "directory"])
def test_required_chmod_failure_is_fatal(tmp_path: Path, kind: str) -> None:
    path = tmp_path / "credential"
    if kind == "directory":
        path.mkdir()
    else:
        path.write_text("secret", encoding="utf-8")
    path.chmod(0o777)

    result = _run_bash(
        f'chmod() {{ return 1; }}\nset_private_permissions "{path}" {kind}',
        env={"CI_SHARED_WORKSPACE_GID": str(path.stat().st_gid)},
    )

    assert result.returncode != 0
    assert "Failed to set mode" in result.stderr
    assert _mode(path) == 0o777


def test_mode_lookup_failure_is_fatal(tmp_path: Path) -> None:
    credential = tmp_path / "credential"
    credential.write_text("secret", encoding="utf-8")
    credential.chmod(0o640)

    result = _run_bash(
        "chgrp() { return 0; }\n"
        "stat() { return 1; }\n"
        'chmod() { echo "unexpected chmod" >&2; return 1; }\n'
        f'set_private_permissions "{credential}"',
        env={"CI_SHARED_WORKSPACE_GID": str(credential.stat().st_gid)},
    )

    assert result.returncode != 0
    assert "Failed to read the mode" in result.stderr
    assert "unexpected chmod" not in result.stderr


def test_bsd_stat_mode_fallback(tmp_path: Path) -> None:
    credential = tmp_path / "credential"
    credential.write_text("secret", encoding="utf-8")
    credential.chmod(0o600)

    result = _run_bash(
        "stat() {\n"
        '  if [[ "$1" == "-c" ]]; then return 1; fi\n'
        '  if [[ "$1" == "-f" && "$2" == "%Lp" ]]; then\n'
        '    echo "BSD stat fallback" >&2\n'
        '    command stat -c "%a" "$3"\n'
        "    return\n"
        "  fi\n"
        "  return 1\n"
        "}\n"
        'chmod() { echo "unexpected chmod" >&2; return 1; }\n'
        f'set_private_permissions "{credential}"',
        env={"CI_SHARED_WORKSPACE_GID": ""},
    )

    assert result.returncode == 0, result.stderr
    assert "BSD stat fallback" in result.stderr
    assert "unexpected chmod" not in result.stderr


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
