"""Thin wrapper around the oc CLI for use in smoke tests."""

import subprocess
from pathlib import Path


def run_oc(args: list[str], kubeconfig: str | Path) -> str:
    """Run an oc command with the given kubeconfig and return stdout.

    Raises AssertionError with stderr content on non-zero exit code.
    Always passes --kubeconfig so tests never rely on ambient cluster state.
    """
    cmd = ["oc", f"--kubeconfig={kubeconfig}"] + args
    result = subprocess.run(cmd, capture_output=True, text=True)
    if result.returncode != 0:
        raise AssertionError(
            f"oc command failed (exit {result.returncode}):\n"
            f"  cmd: {' '.join(cmd)}\n"
            f"  stderr: {result.stderr.strip()}"
        )
    return result.stdout
