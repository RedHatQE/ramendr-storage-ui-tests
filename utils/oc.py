"""Thin wrapper around the oc CLI for use in smoke tests."""

import subprocess
from pathlib import Path


def run_oc(args: list[str], kubeconfig: str | Path, timeout_seconds: int = 60) -> str:
    """Run an oc command with the given kubeconfig and return stdout.

    Raises AssertionError with stderr content on non-zero exit code or timeout.
    Always passes --kubeconfig so tests never rely on ambient cluster state.
    """
    cmd = ["oc", f"--kubeconfig={kubeconfig}"] + args
    try:
        result = subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            timeout=timeout_seconds,
        )
    except subprocess.TimeoutExpired as exc:
        raise AssertionError(
            f"oc command timed out after {timeout_seconds}s:\n"
            f"  cmd: {' '.join(cmd)}\n"
            f"  stderr: {(exc.stderr or '').strip()}"
        ) from exc
    if result.returncode != 0:
        raise AssertionError(
            f"oc command failed (exit {result.returncode}):\n"
            f"  cmd: {' '.join(cmd)}\n"
            f"  stderr: {result.stderr.strip()}"
        )
    return result.stdout
