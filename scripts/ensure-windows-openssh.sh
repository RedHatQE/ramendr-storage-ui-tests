#!/usr/bin/env bash
# Ensure OpenSSH is reachable on Windows edge VMs (sshd running + inbound firewall on all profiles).
#
# The Win2025 container image (quay.io/martjack/windows-server-2025-standard) ships sshd but
# often lacks the "OpenSSH SSH Server (sshd)" firewall rule on Profile=Any after DR restore.
# Win2022 image includes that rule; without it masquerade/Pod traffic is blocked when the
# NIC is classified as Public.
set -euo pipefail

VM_NAMESPACE="${VM_NAMESPACE:-gitops-vms}"
WINDOWS_VM_PATTERN="${WINDOWS_VM_PATTERN:-windows}"
PRIMARY_INSTALL_DIR="${PRIMARY_INSTALL_DIR:-$HOME/git/ocp-primary-install}"
SECONDARY_INSTALL_DIR="${SECONDARY_INSTALL_DIR:-$HOME/git/ocp-secondary-install}"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log() { echo -e "${GREEN}[windows-openssh]${NC} $*"; }
warn() { echo -e "${YELLOW}[windows-openssh] WARNING:${NC} $*"; }
err() { echo -e "${RED}[windows-openssh] ERROR:${NC} $*" >&2; }

# Idempotent guest-side fix (PowerShell, UTF-16LE for -EncodedCommand).
read -r -d '' OPENSSH_PS <<'PS' || true
$ErrorActionPreference = 'Stop'
if (-not (Get-WindowsCapability -Online | Where-Object { $_.Name -eq 'OpenSSH.Server~~~~0.0.1.0' -and $_.State -eq 'Installed' })) {
  Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0 | Out-Null
}
if (-not (Get-Service sshd -ErrorAction SilentlyContinue)) {
  & 'C:\Program Files\OpenSSH\install-sshd.ps1' | Out-Null
}
Set-Service sshd -StartupType Automatic
if ((Get-Service sshd).Status -ne 'Running') { Start-Service sshd }
if (-not (Get-NetFirewallRule -DisplayName 'OpenSSH SSH Server (sshd)' -ErrorAction SilentlyContinue)) {
  New-NetFirewallRule -Name OpenSSH-Server-In-TCP -DisplayName 'OpenSSH SSH Server (sshd)' `
    -Enabled True -Direction Inbound -Protocol TCP -Action Allow -LocalPort 22 | Out-Null
}
Set-NetFirewallRule -DisplayName 'OpenSSH SSH Server (sshd)' -Profile Any -Enabled True
$rule = Get-NetFirewallRule -DisplayName 'OpenSSH SSH Server (sshd)' | Select-Object Enabled, Profile
$svc = Get-Service sshd | Select-Object Status, StartType
@{ service = $svc; firewall = $rule } | ConvertTo-Json -Compress
PS

list_windows_vms() {
  KUBECONFIG="$1" oc get vm -n "$VM_NAMESPACE" --no-headers \
    -o custom-columns=':.metadata.name' 2>/dev/null \
    | awk -v pat="$WINDOWS_VM_PATTERN" '$0 ~ pat { print $1 }' | sort
}

virt_launcher_pod() {
  local kubeconfig="$1" vm="$2"
  KUBECONFIG="$kubeconfig" oc get pods -n "$VM_NAMESPACE" \
    -l "kubevirt.io/domain=${vm}" --field-selector=status.phase=Running \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true
}

libvirt_domain() {
  local kubeconfig="$1" pod="$2"
  KUBECONFIG="$kubeconfig" oc exec -n "$VM_NAMESPACE" "$pod" -c compute -- \
    virsh list --name 2>/dev/null | head -1
}

guest_powershell() {
  local kubeconfig="$1" pod="$2" domain="$3" ps="$4"
  local arg_json b64 out pid status_json
  b64=$(printf '%s' "$ps" | base64 -w0)
  arg_json=$(python3 - "$b64" <<'PY'
import base64, json, sys
ps = base64.b64decode(sys.argv[1]).decode()
print(json.dumps([
    "-NoProfile",
    "-EncodedCommand",
    base64.b64encode(ps.encode("utf-16-le")).decode(),
]))
PY
)
  out=$(KUBECONFIG="$kubeconfig" oc exec -n "$VM_NAMESPACE" "$pod" -c compute -- \
    virsh qemu-agent-command "$domain" \
    "{\"execute\":\"guest-exec\",\"arguments\":{\"path\":\"powershell.exe\",\"arg\":${arg_json},\"capture-output\":true}}" \
    2>/dev/null) || return 1
  pid=$(printf '%s' "$out" | python3 -c "import sys,json; print(json.load(sys.stdin)['return']['pid'])")
  for _ in $(seq 1 15); do
    sleep 2
    status_json=$(KUBECONFIG="$kubeconfig" oc exec -n "$VM_NAMESPACE" "$pod" -c compute -- \
      virsh qemu-agent-command "$domain" \
      "{\"execute\":\"guest-exec-status\",\"arguments\":{\"pid\":${pid}}}" 2>/dev/null) || continue
    printf '%s' "$status_json" | python3 -c "
import base64, json, sys
data = json.load(sys.stdin)
ret = data.get('return', {})
if not ret.get('exited'):
    sys.exit(2)
out = base64.b64decode(ret.get('out-data') or b'').decode(errors='replace').strip()
err = base64.b64decode(ret.get('err-data') or b'').decode(errors='replace').strip()
if out:
    print(out)
if err and 'CLIXML' not in err:
    print(err, file=sys.stderr)
sys.exit(0 if ret.get('exitcode') == 0 else 1)
" && return 0
  done
  return 1
}

ensure_vm_openssh() {
  local kubeconfig="$1" vm="$2"
  local pod domain agent
  agent=$(KUBECONFIG="$kubeconfig" oc get vmi "$vm" -n "$VM_NAMESPACE" \
    -o jsonpath='{.status.conditions[?(@.type=="AgentConnected")].status}' 2>/dev/null || true)
  if [[ "$agent" != "True" ]]; then
    warn "  ${vm}: qemu guest agent not connected — skipping OpenSSH ensure"
    return 1
  fi
  pod="$(virt_launcher_pod "$kubeconfig" "$vm")"
  [[ -n "$pod" ]] || { warn "  ${vm}: no running virt-launcher pod"; return 1; }
  domain="$(libvirt_domain "$kubeconfig" "$pod")"
  [[ -n "$domain" ]] || { warn "  ${vm}: libvirt domain not found"; return 1; }
  log "  ${vm}: ensuring sshd + firewall (domain=${domain})..."
  if ! guest_powershell "$kubeconfig" "$pod" "$domain" "$OPENSSH_PS"; then
    err "  ${vm}: guest OpenSSH ensure failed"
    return 1
  fi
  return 0
}

ensure_on_spoke() {
  local kubeconfig="$1" cluster="$2"
  [[ -f "$kubeconfig" ]] || return 0
  mapfile -t vms < <(list_windows_vms "$kubeconfig")
  if [[ ${#vms[@]} -eq 0 ]]; then
    log "No Windows VMs on ${cluster}."
    return 0
  fi
  log "Ensuring OpenSSH on ${#vms[@]} Windows VM(s) on ${cluster}..."
  local failed=0 vm
  for vm in "${vms[@]}"; do
    ensure_vm_openssh "$kubeconfig" "$vm" || failed=1
  done
  return "$failed"
}

main() {
  if [[ "${SKIP_WINDOWS_OPENSSH_ENSURE:-0}" == "1" ]]; then
    log "SKIP_WINDOWS_OPENSSH_ENSURE=1 — skipping."
    return 0
  fi
  local failed=0
  ensure_on_spoke "${PRIMARY_INSTALL_DIR}/auth/kubeconfig" ocp-primary || failed=1
  ensure_on_spoke "${SECONDARY_INSTALL_DIR}/auth/kubeconfig" ocp-secondary || failed=1
  if [[ "$failed" -ne 0 ]]; then
    err "OpenSSH ensure failed on one or more Windows VMs."
    return 1
  fi
  log "Windows OpenSSH ensure complete."
}

main "$@"
