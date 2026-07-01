#!/usr/bin/env python3
"""Run PowerShell in a Windows VMI via qemu-guest-agent (virt-launcher + virsh)."""

from __future__ import annotations

import argparse
import base64
import json
import os
import subprocess
import sys
import time


def _run_oc(kubeconfig: str, args: list[str]) -> str:
    env = os.environ.copy()
    env["KUBECONFIG"] = kubeconfig
    return subprocess.check_output(["oc", *args], env=env, text=True).strip()


def launcher_pod(kubeconfig: str, namespace: str, vm: str) -> str:
    name = _run_oc(
        kubeconfig,
        [
            "get",
            "pods",
            "-n",
            namespace,
            "-l",
            f"kubevirt.io/domain={vm}",
            "-o",
            "jsonpath={.items[0].metadata.name}",
        ],
    )
    if not name:
        raise GuestAgentNotReadyError(
            f"no launcher pod found for VM {vm!r} in {namespace!r}"
        )
    return name


class GuestAgentError(Exception):
    """Guest-agent call failed after connectivity was expected."""


class GuestAgentNotReadyError(GuestAgentError):
    """Guest-agent is unavailable or the VM is not ready for exec."""


def _parse_qga_response(out: str) -> dict:
    try:
        data = json.loads(out)
    except json.JSONDecodeError as exc:
        raise GuestAgentError(f"invalid guest-agent JSON: {out[:200]}") from exc
    if "error" in data:
        err = data["error"]
        desc = err.get("desc", err) if isinstance(err, dict) else err
        raise GuestAgentError(f"guest-agent error: {desc}")
    if "return" not in data:
        raise GuestAgentError(
            f"guest-agent response missing return payload: {out[:200]}"
        )
    return data


def _virsh_qga(
    kubeconfig: str, namespace: str, launcher: str, domain: str, payload: dict
) -> dict:
    try:
        out = _run_oc(
            kubeconfig,
            [
                "exec",
                "-n",
                namespace,
                launcher,
                "-c",
                "compute",
                "--",
                "virsh",
                "qemu-agent-command",
                domain,
                json.dumps(payload),
            ],
        )
    except subprocess.CalledProcessError as exc:
        detail = (exc.stderr or exc.stdout or str(exc)).strip()
        raise GuestAgentError(f"virsh qemu-agent-command failed: {detail}") from exc
    return _parse_qga_response(out)


def guest_agent_connected(kubeconfig: str, namespace: str, vm: str) -> bool:
    status = _run_oc(
        kubeconfig,
        [
            "get",
            "vmi",
            vm,
            "-n",
            namespace,
            "-o",
            "jsonpath={.status.conditions[?(@.type=='AgentConnected')].status}",
        ],
    )
    return status == "True"


def libvirt_domain(namespace: str, vm: str) -> str:
    return f"{namespace}_{vm}"


def guest_powershell(
    kubeconfig: str,
    namespace: str,
    vm: str,
    script: str,
    *,
    timeout_s: float = 60,
) -> tuple[int | None, str, str]:
    try:
        launcher = launcher_pod(kubeconfig, namespace, vm)
        domain = libvirt_domain(namespace, vm)
        resp = _virsh_qga(
            kubeconfig,
            namespace,
            launcher,
            domain,
            {
                "execute": "guest-exec",
                "arguments": {
                    "path": "powershell.exe",
                    "arg": ["-NoProfile", "-NonInteractive", "-Command", script],
                    "capture-output": True,
                },
            },
        )
        pid = resp["return"]["pid"]
        deadline = time.monotonic() + timeout_s
        while time.monotonic() < deadline:
            time.sleep(1)
            st = _virsh_qga(
                kubeconfig,
                namespace,
                launcher,
                domain,
                {"execute": "guest-exec-status", "arguments": {"pid": pid}},
            )
            ret = st.get("return") or {}
            if ret.get("exited"):
                out = base64.b64decode(ret.get("out-data") or b"").decode(
                    "utf-8", "replace"
                )
                err = base64.b64decode(ret.get("err-data") or b"").decode(
                    "utf-8", "replace"
                )
                return ret.get("exitcode"), out, err
        return None, "", "guest-exec-status timeout"
    except GuestAgentNotReadyError:
        raise
    except GuestAgentError as exc:
        return None, "", str(exc)


SSHD_STATUS_PS = (
    "$s = Get-Service -Name sshd -ErrorAction SilentlyContinue; "
    "if (-not $s) { Write-Output 'missing'; exit 2 }; "
    "Write-Output $s.Status"
)

REMEDIATE_FIREWALL_PS = r"""
$ErrorActionPreference = 'Stop'
$svc = Get-Service -Name sshd -ErrorAction SilentlyContinue
if (-not $svc) {
  Write-Output 'sshd service not installed'
  exit 2
}
if ($svc.Status -ne 'Running') {
  Set-Service -Name sshd -StartupType Automatic
  Start-Service sshd
}
$rules = Get-NetFirewallRule -DisplayGroup 'OpenSSH Server (sshd)' -ErrorAction SilentlyContinue
if ($rules) {
  $rules | Set-NetFirewallRule -Enabled True -Profile Any
  Write-Output 'updated OpenSSH Server (sshd) firewall rules to Profile Any'
} else {
  New-NetFirewallRule -Name 'Ramendr-OpenSSH-In-TCP-22' `
    -DisplayName 'Ramendr OpenSSH inbound 22' `
    -Enabled True -Direction Inbound -Protocol TCP -LocalPort 22 -Action Allow -Profile Any | Out-Null
  Write-Output 'created Ramendr-OpenSSH-In-TCP-22 firewall rule'
}
Get-NetFirewallRule -DisplayGroup 'OpenSSH Server (sshd)' -ErrorAction SilentlyContinue |
  Select-Object DisplayName, Enabled, Profile | Format-Table -Auto | Out-String -Width 200
Write-Output 'remediation complete'
"""


def remediate_openssh_firewall(
    kubeconfig: str, namespace: str, vm: str
) -> tuple[int, str]:
    """Return (code, message). code: 0=applied, 2=not ready to fix yet, 1=failed."""
    try:
        if not guest_agent_connected(kubeconfig, namespace, vm):
            return 2, "guest agent not connected"

        code, out, err = guest_powershell(kubeconfig, namespace, vm, SSHD_STATUS_PS)
        if code is None:
            return 1, err or out or "guest-agent sshd status check failed"
        status = (out or err).strip().splitlines()[-1] if (out or err).strip() else ""
        if code != 0 or status != "Running":
            return 2, f"sshd not running inside guest (status={status or 'unknown'})"

        code, out, err = guest_powershell(
            kubeconfig, namespace, vm, REMEDIATE_FIREWALL_PS
        )
        if code is None:
            return 1, err or out or "guest-agent firewall remediation failed"
        detail = (out or err).strip()
        if code != 0:
            return 1, detail or "firewall remediation failed"
        return 0, detail
    except GuestAgentNotReadyError as exc:
        return 2, str(exc)
    except GuestAgentError as exc:
        return 1, str(exc)


def main() -> int:
    parser = argparse.ArgumentParser(description="Windows guest-agent helpers")
    sub = parser.add_subparsers(dest="cmd", required=True)

    p_rem = sub.add_parser("remediate-firewall")
    p_rem.add_argument("--kubeconfig", required=True)
    p_rem.add_argument("--namespace", required=True)
    p_rem.add_argument("--vm", required=True)

    args = parser.parse_args()
    if args.cmd == "remediate-firewall":
        code, msg = remediate_openssh_firewall(args.kubeconfig, args.namespace, args.vm)
        if msg:
            print(msg)
        return code
    return 1


if __name__ == "__main__":
    sys.exit(main())
