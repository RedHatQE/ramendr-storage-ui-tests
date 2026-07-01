#!/usr/bin/env bash
# Verify OpenSSH on Windows edge VMs (pre-configured on martjack golden images).
#
# Uses virtctl ssh (KubeVirt port-forward) + optional login via windows-admin secret.
# Runs from the host that has kubeconfig + virtctl; no in-cluster probe pod required.
set -euo pipefail

VM_NAMESPACE="${VM_NAMESPACE:-gitops-vms}"
REQUIRE_WINDOWS_VMS="${REQUIRE_WINDOWS_VMS:-1}"
WINDOWS_VM_PATTERN="${WINDOWS_VM_PATTERN:-windows}"
PRIMARY_INSTALL_DIR="${PRIMARY_INSTALL_DIR:-$HOME/git/ocp-primary-install}"
SECONDARY_INSTALL_DIR="${SECONDARY_INSTALL_DIR:-$HOME/git/ocp-secondary-install}"
WINDOWS_SSH_USER="${WINDOWS_SSH_USER:-Administrator}"
VALUES_SECRET="${VALUES_SECRET:-$HOME/values-secret.yaml}"
SSH_WAIT_TRIES="${WINDOWS_SSH_WAIT_TRIES:-${WINDOWS_OPENSSH_AGENT_WAIT_TRIES:-120}}"
SSH_WAIT_SLEEP="${WINDOWS_SSH_WAIT_SLEEP:-${WINDOWS_OPENSSH_AGENT_WAIT_SLEEP:-10}}"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log() { echo -e "${GREEN}[windows-openssh]${NC} $*"; }
warn() { echo -e "${YELLOW}[windows-openssh] WARNING:${NC} $*"; }
err() { echo -e "${RED}[windows-openssh] ERROR:${NC} $*" >&2; }

require_tools() {
  if ! command -v virtctl >/dev/null 2>&1; then
    err "virtctl not found in PATH (required for SSH verification)."
    return 1
  fi
  if [[ "${1:-0}" -eq 1 ]] && ! command -v sshpass >/dev/null 2>&1; then
    err "sshpass not found in PATH (required for password login check)."
    return 1
  fi
}

load_windows_ssh_password() {
  if [[ -n "${WINDOWS_SSH_PASSWORD:-}" ]]; then
    return 0
  fi
  [[ -f "$VALUES_SECRET" ]] || return 1
  WINDOWS_SSH_PASSWORD=$(python3 - "$VALUES_SECRET" <<'PY'
import re, sys

text = open(sys.argv[1]).read()

# Flat form: windows-admin:\n  password: Redhat123!
m = re.search(
    r"windows-admin:\s*(?:#.*\n)*\s*password:\s*['\"]?([^'\"#\s]+)",
    text,
    re.MULTILINE,
)
if m:
    print(m.group(1))
    raise SystemExit(0)

# Fork values-secret v2 list form (name/fields order may vary):
# - name: windows-admin
#   fields:
#   - name: password
#     value: Redhat123!
for item in re.finditer(
    r"^- (?:fields:|name:)[^\n]*(?:\n(?!^- ).*?)*?(?=^- |\nversion:|\Z)",
    text,
    re.DOTALL | re.MULTILINE,
):
    chunk = item.group(0)
    if not re.search(r"name:\s*windows-admin\s*$", chunk, re.MULTILINE):
        continue
    m = re.search(
        r"- name:\s*password\s*\n\s*value:\s*['\"]?([^'\"#\n]+)", chunk
    )
    if m:
        print(m.group(1))
        raise SystemExit(0)
PY
)
  [[ -n "${WINDOWS_SSH_PASSWORD:-}" ]]
}

list_windows_vms() {
  KUBECONFIG="$1" oc get vm -n "$VM_NAMESPACE" --no-headers \
    -o custom-columns=':.metadata.name' 2>/dev/null \
    | awk -v pat="$WINDOWS_VM_PATTERN" '$0 ~ pat { print $1 }' | sort
}

virtctl_ssh_common_opts() {
  printf '%s\n' \
    --local-ssh-opts "-o StrictHostKeyChecking=no" \
    --local-ssh-opts "-o UserKnownHostsFile=/dev/null" \
    --local-ssh-opts "-o ConnectTimeout=15"
}

probe_ssh_login() {
  local kubeconfig="$1" vm="$2"
  mapfile -t opts < <(virtctl_ssh_common_opts)
  KUBECONFIG="$kubeconfig" SSHPASS="$WINDOWS_SSH_PASSWORD" sshpass -e \
    virtctl ssh "${WINDOWS_SSH_USER}@vm/${vm}" -n "$VM_NAMESPACE" \
    -c hostname "${opts[@]}" \
    --local-ssh-opts "-o PreferredAuthentications=password" \
    --local-ssh-opts "-o PubkeyAuthentication=no" \
    >/dev/null 2>&1
}

probe_ssh_tcp() {
  local kubeconfig="$1" vm="$2" out=""
  mapfile -t opts < <(virtctl_ssh_common_opts)
  out=$(KUBECONFIG="$kubeconfig" virtctl ssh "${WINDOWS_SSH_USER}@vm/${vm}" -n "$VM_NAMESPACE" \
    -c hostname "${opts[@]}" \
    --local-ssh-opts "-o BatchMode=yes" 2>&1) || true
  # BatchMode always fails auth; reaching sshd returns "Permission denied".
  [[ "$out" == *"Permission denied"* ]]
}

probe_ssh() {
  local kubeconfig="$1" vm="$2" use_auth="$3"
  if [[ "$use_auth" -eq 1 ]]; then
    probe_ssh_login "$kubeconfig" "$vm"
  else
    probe_ssh_tcp "$kubeconfig" "$vm"
  fi
}

verify_on_spoke() {
  local kubeconfig="$1" cluster="$2"
  if [[ ! -f "$kubeconfig" ]]; then
    if [[ "$REQUIRE_WINDOWS_VMS" == "1" ]]; then
      err "Kubeconfig not found for ${cluster}: ${kubeconfig}"
      return 1
    fi
    warn "Kubeconfig not found for ${cluster}: ${kubeconfig}; skipping Windows SSH verification."
    return 0
  fi
  mapfile -t vms < <(list_windows_vms "$kubeconfig")
  if [[ ${#vms[@]} -eq 0 ]]; then
    log "No Windows VMs on ${cluster}."
    return 0
  fi

  local use_auth=0 failed=0
  if load_windows_ssh_password; then
    use_auth=1
    log "Verifying SSH on ${#vms[@]} Windows VM(s) on ${cluster} (user=${WINDOWS_SSH_USER}, virtctl login check)..."
  else
    warn "windows-admin password not found in VALUES_SECRET — TCP-only check via virtctl ssh."
    log "Verifying SSH on ${#vms[@]} Windows VM(s) on ${cluster} (virtctl port 22 only)..."
  fi
  require_tools "$use_auth" || return 1

  local -a pending=("${vms[@]}")
  local tries=0 max_wait=$((SSH_WAIT_TRIES * SSH_WAIT_SLEEP))
  log "Waiting up to ${max_wait}s for OpenSSH on: ${vms[*]}"
  while [[ ${#pending[@]} -gt 0 && tries -lt SSH_WAIT_TRIES ]]; do
    local -a still=()
    local vm
    for vm in "${pending[@]}"; do
      if probe_ssh "$kubeconfig" "$vm" "$use_auth"; then
        if [[ "$use_auth" -eq 1 ]]; then
          log "  ${vm}: SSH login OK (${WINDOWS_SSH_USER}@vm/${vm})"
        else
          log "  ${vm}: SSH port reachable (virtctl)"
        fi
        continue
      fi
      still+=("$vm")
    done
    pending=("${still[@]}")
    [[ ${#pending[@]} -eq 0 ]] && break
    log "  still waiting (${#pending[@]} VM(s)): ${pending[*]} — attempt $((tries + 1))/${SSH_WAIT_TRIES}..."
    sleep "$SSH_WAIT_SLEEP"
    tries=$((tries + 1))
  done

  if [[ ${#pending[@]} -gt 0 ]]; then
    for vm in "${pending[@]}"; do
      warn "  ${vm}: OpenSSH not reachable after ${max_wait}s"
    done
    failed=1
  fi
  return "$failed"
}

main() {
  if [[ "${SKIP_WINDOWS_OPENSSH_ENSURE:-0}" == "1" ]]; then
    log "SKIP_WINDOWS_OPENSSH_ENSURE=1 — skipping."
    return 0
  fi
  local failed=0
  verify_on_spoke "${PRIMARY_INSTALL_DIR}/auth/kubeconfig" ocp-primary || failed=1
  verify_on_spoke "${SECONDARY_INSTALL_DIR}/auth/kubeconfig" ocp-secondary || failed=1
  if [[ "$failed" -ne 0 ]]; then
    err "Windows SSH verification failed on one or more VMs."
    return 1
  fi
  log "Windows SSH verification complete."
}

main "$@"
