#!/usr/bin/env bash
# Shared helpers for DR validation scripts (no secrets logged).

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DR_VALIDATION_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DR_VALIDATION_DIR="${DR_VALIDATION_DIR:-$REPO_ROOT/dr-validation}"
VM_NAMESPACE="${VM_NAMESPACE:-gitops-vms}"
DRPC_NAMESPACE="${DRPC_NAMESPACE:-openshift-dr-ops}"
DRPC_NAME="${DRPC_NAME:-gitops-vm-protection}"
PLACEMENT_NAME="${PLACEMENT_NAME:-gitops-vm-protection-placement-1}"

SSH_USER="${SSH_USER:-cloud-user}"
SSH_IDENTITY_FILE="${SSH_IDENTITY_FILE:-$HOME/.ssh/id_rsa}"
DR_VALIDATION_LOG_PATH="${DR_VALIDATION_LOG_PATH:-/var/lib/ramendr-dr-validation/timestamps.log}"
DR_VALIDATION_MODE="${DR_VALIDATION_MODE:-hammerdb}"
# Legacy single-VM filter (used only when DR_VALIDATION_HAMMERDB_ALL_VMS=0).
DR_VALIDATION_HAMMERDB_VM="${DR_VALIDATION_HAMMERDB_VM:-rhel9-node-001}"
# Install HammerDB on every edge VM in gitops-vms (2 Linux + 2 Windows by default).
DR_VALIDATION_HAMMERDB_ALL_VMS="${DR_VALIDATION_HAMMERDB_ALL_VMS:-1}"
# Optional comma-separated VM name filter (overrides ALL_VMS and legacy HAMMERDB_VM).
DR_VALIDATION_HAMMERDB_VMS="${DR_VALIDATION_HAMMERDB_VMS:-}"
# Direct Microsoft download (go.microsoft.com/fwlink linkid=2216018 is broken — returns HTML).
DR_VALIDATION_SQL_SSEI_URL="${DR_VALIDATION_SQL_SSEI_URL:-https://download.microsoft.com/download/5/1/4/5145fe04-4d30-4b85-b0d1-39533663a2f1/SQL2022-SSEI-Expr.exe}"
DR_VALIDATION_PYTHON_WINDOWS_VERSION="${DR_VALIDATION_PYTHON_WINDOWS_VERSION:-3.12.7}"
DR_VALIDATION_PYTHON_WINDOWS_URL="${DR_VALIDATION_PYTHON_WINDOWS_URL:-https://www.python.org/ftp/python/${DR_VALIDATION_PYTHON_WINDOWS_VERSION}/python-${DR_VALIDATION_PYTHON_WINDOWS_VERSION}-amd64.exe}"
DR_VALIDATION_ODBC_DRIVER_MSI_URL="${DR_VALIDATION_ODBC_DRIVER_MSI_URL:-https://go.microsoft.com/fwlink/?linkid=2361646}"
WINDOWS_SSH_USER="${WINDOWS_SSH_USER:-Administrator}"
VALUES_SECRET="${VALUES_SECRET:-$HOME/values-secret.yaml}"
# Full fleet size in gitops-vms (2 Linux + 2 Windows); post-DR checks still use this.
DR_VALIDATION_EXPECTED_VMS="${DR_VALIDATION_EXPECTED_VMS:-4}"
# Linux DR data disk mount and PostgreSQL split-tablespace layout (see hammerdb/install-on-vm.sh).
DR_VALIDATION_DATA_DISK_MOUNT="${DR_VALIDATION_DATA_DISK_MOUNT:-/mnt/ramendr-data}"
DR_VALIDATION_OS_TABLESPACE="${DR_VALIDATION_OS_TABLESPACE:-ramendr_os}"
# Windows DR data disk drive letter for SQL Server PRIMARY filegroup (audit uses ramendr_os on OS disk).
DR_VALIDATION_DATA_DISK_DRIVE="${DR_VALIDATION_DATA_DISK_DRIVE:-D}"
# Bootstrap waits only for Linux edge VMs (Windows DR bootstrap is separate).
DR_VALIDATION_BOOTSTRAP_VM_COUNT="${DR_VALIDATION_BOOTSTRAP_VM_COUNT:-2}"
DR_VALIDATION_BOOTSTRAP_VM_PATTERN="${DR_VALIDATION_BOOTSTRAP_VM_PATTERN:-rhel}"
DR_VALIDATION_DB_SNAPSHOT_ROOT="${DR_VALIDATION_DB_SNAPSHOT_ROOT:-${REPO_ROOT}/.work/dr-validation-db/auto}"
# Semver-tagged utility container for in-cluster DR validation Jobs (override via env).
# Spokes are amd64-only; bump the tag when intentionally upgrading utility-container.
DR_VALIDATION_UTILITY_CONTAINER_IMAGE="${DR_VALIDATION_UTILITY_CONTAINER_IMAGE:-quay.io/validatedpatterns/utility-container:v1.0.4}"
DR_VALIDATION_INTERVAL="${DR_VALIDATION_INTERVAL:-10.0}"
DR_VALIDATION_SNAPSHOT_INTERVAL="${DR_VALIDATION_SNAPSHOT_INTERVAL:-300}"
DR_VALIDATION_SNAPSHOT_KEEP="${DR_VALIDATION_SNAPSHOT_KEEP:-1}"
AUTO_SNAPSHOT_ROOT="${REPO_ROOT}/.work/dr-validation-logs/auto"
# shellcheck disable=SC2034  # used by start/stop/snapshot-daemon.sh via source
SNAPSHOT_DAEMON_PID_FILE="${REPO_ROOT}/.work/dr-validation-snapshot-daemon.pid"
# shellcheck disable=SC2034  # used by start/stop/snapshot-daemon.sh via source
SNAPSHOT_DAEMON_LOG="${REPO_ROOT}/.work/dr-validation-snapshot-daemon.log"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log() { echo -e "${GREEN}[dr-validation]${NC} $*"; }
warn() { echo -e "${YELLOW}[dr-validation] WARNING:${NC} $*"; }
err() { echo -e "${RED}[dr-validation] ERROR:${NC} $*" >&2; }

require_cmd() {
  local c
  for c in "$@"; do
    command -v "$c" &>/dev/null || { err "Missing required command: $c"; exit 1; }
  done
}

determine_primary_cluster() {
  local placement_cluster
  placement_cluster=$(oc get placementdecision -n "$DRPC_NAMESPACE" \
    -l cluster.open-cluster-management.io/placement="$PLACEMENT_NAME" \
    -o jsonpath='{.items[0].status.decisions[0].clusterName}' 2>/dev/null || true)
  if [[ -n "$placement_cluster" ]]; then
    echo "$placement_cluster"
    return 0
  fi
  oc get drplacementcontrol "$DRPC_NAME" -n "$DRPC_NAMESPACE" \
    -o jsonpath='{.spec.preferredCluster}' 2>/dev/null || true
}

resolve_spoke_kubeconfig() {
  local cluster="$1"
  local install_dir=""
  case "$cluster" in
    ocp-primary) install_dir="${PRIMARY_INSTALL_DIR:-$HOME/git/ocp-primary-install}" ;;
    ocp-secondary) install_dir="${SECONDARY_INSTALL_DIR:-$HOME/git/ocp-secondary-install}" ;;
    *)
      err "Unknown cluster name: $cluster (expected ocp-primary or ocp-secondary)"
      return 1
      ;;
  esac
  local kc="$install_dir/auth/kubeconfig"
  if [[ ! -f "$kc" ]]; then
    err "Kubeconfig not found: $kc"
    return 1
  fi
  echo "$kc"
}

list_vm_ssh_hosts() {
  local kubeconfig="$1"
  KUBECONFIG="$kubeconfig" VM_NAMESPACE="$VM_NAMESPACE" python3 -c "
import json, os, subprocess, sys

raw = subprocess.check_output(
    ['oc', 'get', 'route,service,vmi', '-n', os.environ['VM_NAMESPACE'], '-o', 'json'],
    env=os.environ,
)
data = json.loads(raw)
items = data.get('items', [])
routes = [i for i in items if i.get('kind') == 'Route']
services = [i for i in items if i.get('kind') == 'Service']
vmis = [i for i in items if i.get('kind') == 'VirtualMachineInstance']

hosts = {}
for route in routes:
    name = route['metadata']['name']
    host = route.get('status', {}).get('ingress', [{}])[0].get('host', '')
    if host:
        hosts[name] = host

if hosts:
    for name, host in sorted(hosts.items()):
        print(f'{name}\t{host}\t22')
    sys.exit(0)

# No Routes (common with NodePort-only gitops-vms): use node IP + NodePort on the VMI node.
node_ips = {}
for vmi in vmis:
    if vmi.get('status', {}).get('phase') != 'Running':
        continue
    name = vmi['metadata']['name']
    node = vmi.get('status', {}).get('nodeName', '')
    if node:
        node_ips[name] = node

nodes_json = json.loads(subprocess.check_output(
    ['oc', 'get', 'nodes', '-o', 'json'],
    env=os.environ,
))
node_addr = {}
for node in nodes_json.get('items', []):
    nname = node['metadata']['name']
    ext = ''
    internal = ''
    for addr in node.get('status', {}).get('addresses', []):
        if addr.get('type') == 'ExternalIP':
            ext = addr.get('address', '')
        if addr.get('type') == 'InternalIP':
            internal = addr.get('address', '')
    node_addr[nname] = ext or internal

for svc in services:
    name = svc['metadata']['name']
    spec = svc.get('spec', {})
    if spec.get('type') != 'NodePort':
        continue
    ports = [p for p in spec.get('ports', []) if p.get('port') == 22 or p.get('name') == 'ssh']
    if not ports:
        continue
    nodeport = ports[0].get('nodePort')
    if not nodeport:
        continue
    node = node_ips.get(name, '')
    ip = node_addr.get(node, '')
    if ip:
        print(f'{name}\t{ip}\t{nodeport}')
"
}

cloud_init_password_from_vault() {
  ensure_hub_kubeconfig
  oc exec -n vault vault-0 -- vault kv get -field=userData secret/global/cloud-init 2>/dev/null | python3 -c "
import re, sys
text = sys.stdin.read()
m = re.search(r'^password:\\s*(\\S+)\\s*$', text, re.M)
print(m.group(1) if m else '')
" 2>/dev/null || true
}

SSH_OPTS=()

ssh_extra_opts() {
  SSH_OPTS=(-o StrictHostKeyChecking=accept-new -o ConnectTimeout=15)
  if [[ -f "$SSH_IDENTITY_FILE" ]]; then
    SSH_OPTS+=(-i "$SSH_IDENTITY_FILE")
  fi
}

# Seconds since the last valid record in a timestamp log (-1 if missing/empty).
log_last_record_age_seconds() {
  local log_file="$1"
  PYTHONPATH="${DR_VALIDATION_DIR}${PYTHONPATH:+:$PYTHONPATH}" python3 -c "
from datetime import datetime, timezone
from pathlib import Path
from ramendr_dr_validation.records import parse_line
import sys

path = Path(sys.argv[1])
if not path.is_file():
    print(-1)
    sys.exit(0)
lines = [ln for ln in path.read_text().splitlines() if ln.strip() and not ln.startswith('#')]
if not lines:
    print(-1)
    sys.exit(0)
rec = parse_line(lines[-1], len(lines))
age = (datetime.now(timezone.utc) - rec.timestamp).total_seconds()
print(int(age))
" "$log_file"
}

wait_for_edge_vms() {
  require_cmd oc python3
  local expected="${DR_VALIDATION_EXPECTED_VMS}"
  local max_tries="${DR_VALIDATION_WAIT_MAX_TRIES:-60}"
  local sleep_sec="${DR_VALIDATION_WAIT_SLEEP:-30}"

  ensure_hub_kubeconfig

  log "Waiting for ${expected} edge VM(s) and SSH routes in ${VM_NAMESPACE}..."
  local tries=0
  while [[ $tries -lt $max_tries ]]; do
    local primary spoke_kc running routes
    primary="$(determine_primary_cluster)"
    [[ -z "$primary" ]] && primary="ocp-primary"

    if ! spoke_kc="$(resolve_spoke_kubeconfig "$primary" 2>/dev/null)"; then
      sleep "$sleep_sec"
      tries=$((tries + 1))
      continue
    fi

    running=$(KUBECONFIG="$spoke_kc" oc get vm -n "$VM_NAMESPACE" --no-headers 2>/dev/null \
      | awk '$3 ~ /Running/ { c++ } END { print c+0 }')
    routes=0
    while IFS= read -r _; do
      routes=$((routes + 1))
    done < <(list_vm_ssh_hosts "$spoke_kc")

    log "  primary=${primary} running_vms=${running}/${expected} ssh_endpoints=${routes}/${expected}"
    if [[ "$running" -ge "$expected" ]] && [[ "$routes" -ge "$expected" ]]; then
      log "Edge VMs and SSH endpoints are ready on ${primary}."
      return 0
    fi
    sleep "$sleep_sec"
    tries=$((tries + 1))
  done
  err "Timed out waiting for edge VMs/routes."
  return 1
}

_count_vms_on_spoke() {
  local kubeconfig="$1" pattern="$2" status="${3:-}"
  KUBECONFIG="$kubeconfig" oc get vm -n "$VM_NAMESPACE" --no-headers 2>/dev/null \
    | awk -v pat="$pattern" -v st="$status" '
      $1 ~ pat { if (st == "" || $3 ~ st) c++ } END { print c+0 }'
}

_count_ssh_hosts_on_spoke() {
  local kubeconfig="$1" pattern="$2"
  local count=0 route_name
  while IFS=$'\t' read -r route_name _ _; do
    [[ -z "$route_name" ]] && continue
    [[ "$route_name" =~ $pattern ]] || continue
    count=$((count + 1))
  done < <(list_vm_ssh_hosts "$kubeconfig")
  echo "$count"
}

# Wait for HammerDB target VMs before bootstrap (respects allowlist via hammerdb_target_vm_count).
wait_for_bootstrap_vms_healthy() {
  local expected pattern
  if dr_validation_uses_hammerdb; then
    expected="$(hammerdb_target_vm_count)"
    pattern="."
  elif [[ "${DR_VALIDATION_HAMMERDB_ALL_VMS:-1}" == "1" ]]; then
    expected="${DR_VALIDATION_EXPECTED_VMS:-4}"
    pattern="."
  else
    expected="${DR_VALIDATION_BOOTSTRAP_VM_COUNT:-2}"
    pattern="${DR_VALIDATION_BOOTSTRAP_VM_PATTERN:-rhel}"
  fi
  local max_tries="${DR_VALIDATION_HEALTH_WAIT_TRIES:-40}"
  local sleep_sec="${DR_VALIDATION_HEALTH_WAIT_SLEEP:-30}"

  require_cmd oc python3
  ensure_hub_kubeconfig

  log "Waiting for ${expected} Running edge VM(s) matching '${pattern}' on current primary (up to $((max_tries * sleep_sec / 60)) min)..."
  local tries=0
  while [[ $tries -lt $max_tries ]]; do
    local primary spoke_kc running
    primary="$(determine_primary_cluster)"
    [[ -z "$primary" ]] && primary="ocp-primary"
    if ! spoke_kc="$(resolve_spoke_kubeconfig "$primary" 2>/dev/null)"; then
      sleep "$sleep_sec"
      tries=$((tries + 1))
      continue
    fi
    running="$(_count_vms_on_spoke "$spoke_kc" "$pattern" "Running")"
    log "  primary=${primary} running_bootstrap_vms=${running}/${expected} (pattern=${pattern})"
    if [[ "$running" -ge "$expected" ]]; then
      log "Bootstrap edge VMs are Running on ${primary}."
      return 0
    fi
    sleep "$sleep_sec"
    tries=$((tries + 1))
  done
  err "Timed out waiting for Running bootstrap VMs on primary."
  return 1
}

wait_for_bootstrap_ssh_endpoints() {
  local max_tries="${DR_VALIDATION_WAIT_MAX_TRIES:-60}"
  local sleep_sec="${DR_VALIDATION_WAIT_SLEEP:-30}"

  require_cmd oc python3
  ensure_hub_kubeconfig

  if dr_validation_uses_hammerdb; then
    local expected
    expected="$(hammerdb_target_vm_count)"
    log "Waiting for SSH endpoint(s) on ${expected} HammerDB target VM(s)..."
    local tries=0
    while [[ $tries -lt $max_tries ]]; do
      local primary spoke_kc hosts ready=0
      primary="$(determine_primary_cluster)"
      [[ -z "$primary" ]] && primary="ocp-primary"
      if spoke_kc="$(resolve_spoke_kubeconfig "$primary" 2>/dev/null)" && \
        hosts="$(get_hammerdb_vm_hosts "$spoke_kc" 2>/dev/null)" && [[ -n "$hosts" ]]; then
        while IFS= read -r _; do
          ready=$((ready + 1))
        done <<< "$hosts"
        log "  primary=${primary} hammerdb_ssh_endpoints=${ready}/${expected}"
        if [[ "$ready" -ge "$expected" ]]; then
          log "SSH endpoints ready for HammerDB targets on ${primary}."
          return 0
        fi
      else
        ready=0
        log "  primary=${primary} hammerdb_ssh_endpoints=${ready}/${expected}"
      fi
      log "  waiting for HammerDB SSH endpoints (attempt $((tries + 1))/${max_tries})..."
      sleep "$sleep_sec"
      tries=$((tries + 1))
    done
    err "Timed out waiting for HammerDB VM SSH endpoint(s)."
    return 1
  fi

  local expected="${DR_VALIDATION_BOOTSTRAP_VM_COUNT:-2}"
  local pattern="${DR_VALIDATION_BOOTSTRAP_VM_PATTERN:-rhel}"
  log "Waiting for ${expected} SSH endpoint(s) matching '${pattern}' in ${VM_NAMESPACE}..."
  local tries=0
  while [[ $tries -lt $max_tries ]]; do
    local primary spoke_kc routes
    primary="$(determine_primary_cluster)"
    [[ -z "$primary" ]] && primary="ocp-primary"
    if ! spoke_kc="$(resolve_spoke_kubeconfig "$primary" 2>/dev/null)"; then
      sleep "$sleep_sec"
      tries=$((tries + 1))
      continue
    fi
    routes="$(_count_ssh_hosts_on_spoke "$spoke_kc" "$pattern")"
    log "  primary=${primary} ssh_endpoints=${routes}/${expected} (pattern=${pattern})"
    if [[ "$routes" -ge "$expected" ]]; then
      log "Bootstrap SSH endpoints are ready on ${primary}."
      return 0
    fi
    sleep "$sleep_sec"
    tries=$((tries + 1))
  done
  err "Timed out waiting for bootstrap SSH endpoints."
  return 1
}

ensure_hub_kubeconfig() {
  local hub_install_dir="${HUB_INSTALL_DIR:-$HOME/git/hub-cluster-install}"
  if [[ -z "${KUBECONFIG:-}" ]] && [[ -f "${hub_install_dir}/auth/kubeconfig" ]]; then
    export KUBECONFIG="${hub_install_dir}/auth/kubeconfig"
  fi
}

collect_logs_to_dir() {
  local out_dir="$1"
  mkdir -p "$out_dir"
  require_cmd oc scp ssh python3
  ssh_extra_opts
  ensure_hub_kubeconfig

  local primary spoke_kc
  primary="$(determine_primary_cluster)"
  [[ -n "$primary" ]] || { err "Could not determine primary cluster"; return 1; }
  spoke_kc="$(resolve_spoke_kubeconfig "$primary")"

  local collected=0
  while IFS=$'\t' read -r route_name host port; do
    [[ -z "$route_name" ]] && continue
    port="${port:-22}"
    local dest="${out_dir}/${route_name}.timestamps.log"
    if scp -P "$port" "${SSH_OPTS[@]}" "${SSH_USER}@${host}:${DR_VALIDATION_LOG_PATH}" "$dest" 2>/dev/null; then
      collected=$((collected + 1))
    else
      warn "Could not fetch log from ${host}:${port}"
    fi
  done < <(list_vm_ssh_hosts "$spoke_kc")

  cat >"${out_dir}/metadata.json" <<META
{
  "collected_at_utc": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "primary_cluster": "${primary}",
  "vm_count": ${collected},
  "log_path": "${DR_VALIDATION_LOG_PATH}"
}
META

  if [[ "$collected" -eq 0 ]]; then
    err "No logs collected into ${out_dir}"
    return 1
  fi
  log "Collected ${collected} log(s) from ${primary} -> ${out_dir}"
  return 0
}

prune_auto_snapshots() {
  local keep="${DR_VALIDATION_SNAPSHOT_KEEP:-1}"
  [[ -d "$AUTO_SNAPSHOT_ROOT" ]] || return 0
  local dirs=()
  while IFS= read -r d; do
    dirs+=("$d")
  done < <(find "$AUTO_SNAPSHOT_ROOT" -mindepth 1 -maxdepth 1 -type d ! -name 'latest' | sort)
  local count=${#dirs[@]}
  if [[ "$count" -le "$keep" ]]; then
    return 0
  fi
  local to_remove=$((count - keep))
  local i=0
  for d in "${dirs[@]}"; do
    [[ $i -ge $to_remove ]] && break
    rm -rf "$d"
    i=$((i + 1))
  done
}

update_latest_snapshot_link() {
  local snap_dir="$1"
  mkdir -p "$AUTO_SNAPSHOT_ROOT"
  ln -sfn "$(basename "$snap_dir")" "${AUTO_SNAPSHOT_ROOT}/latest"
}

is_auto_db_snapshot_dir() {
  local out_dir="$1"
  local canonical_out="" canonical_root=""
  [[ -d "$out_dir" ]] || return 1
  canonical_out="$(cd "$out_dir" && pwd)"
  mkdir -p "$DR_VALIDATION_DB_SNAPSHOT_ROOT"
  canonical_root="$(cd "$DR_VALIDATION_DB_SNAPSHOT_ROOT" && pwd)"
  [[ "$canonical_out" == "${canonical_root}/"* ]]
}

update_latest_db_snapshot_link() {
  local snap_dir="$1"
  mkdir -p "$DR_VALIDATION_DB_SNAPSHOT_ROOT"
  ln -sfn "$(basename "$snap_dir")" "${DR_VALIDATION_DB_SNAPSHOT_ROOT}/latest"
}

# Resolve auto/latest to an absolute baseline directory.
# Returns 0 and prints the path when valid; 1 when missing; 2 when dangling.
resolve_db_baseline_dir() {
  local root="$1"
  local link="${root}/latest"
  local resolved=""
  if [[ ! -L "$link" ]]; then
    return 1
  fi
  if resolved="$(cd "$link" 2>/dev/null && pwd)"; then
    echo "$resolved"
    return 0
  fi
  return 2
}

seed_db_baseline_snapshot_if_missing() {
  local stamp dest count
  mkdir -p "$DR_VALIDATION_DB_SNAPSHOT_ROOT"
  if [[ -L "${DR_VALIDATION_DB_SNAPSHOT_ROOT}/latest" ]]; then
    shopt -s nullglob
    local existing=("${DR_VALIDATION_DB_SNAPSHOT_ROOT}/latest"/*.db-snapshot.json)
    shopt -u nullglob
    if [[ ${#existing[@]} -ge 1 ]]; then
      return 0
    fi
  fi
  stamp="$(date +%Y%m%d-%H%M%S)"
  dest="${DR_VALIDATION_DB_SNAPSHOT_ROOT}/${stamp}"
  log "Seeding initial DB baseline snapshot -> ${dest}"
  if ! "$DR_VALIDATION_SCRIPT_DIR/collect-db-snapshot-incluster.sh" "$dest"; then
    err "Could not seed initial DB baseline snapshot."
    return 1
  fi
}

prune_auto_snapshots_db() {
  local keep="${DR_VALIDATION_SNAPSHOT_KEEP:-1}"
  [[ -d "$DR_VALIDATION_DB_SNAPSHOT_ROOT" ]] || return 0
  local dirs=()
  while IFS= read -r d; do
    dirs+=("$d")
  done < <(find "$DR_VALIDATION_DB_SNAPSHOT_ROOT" -mindepth 1 -maxdepth 1 -type d ! -name 'latest' | sort)
  local count=${#dirs[@]}
  if [[ "$count" -le "$keep" ]]; then
    return 0
  fi
  local to_remove=$((count - keep))
  local i=0
  for d in "${dirs[@]}"; do
    [[ $i -ge $to_remove ]] && break
    rm -rf "$d"
    i=$((i + 1))
  done
}

wait_for_primary_vms_healthy() {
  local expected="${DR_VALIDATION_EXPECTED_VMS}"
  local max_tries="${DR_VALIDATION_HEALTH_WAIT_TRIES:-40}"
  local sleep_sec="${DR_VALIDATION_HEALTH_WAIT_SLEEP:-30}"

  require_cmd oc python3
  ensure_hub_kubeconfig

  log "Waiting for ${expected} Running edge VM(s) on current primary (up to $((max_tries * sleep_sec / 60)) min)..."
  local tries=0
  while [[ $tries -lt $max_tries ]]; do
    local primary spoke_kc running
    primary="$(determine_primary_cluster)"
    [[ -z "$primary" ]] && primary="ocp-primary"
    if ! spoke_kc="$(resolve_spoke_kubeconfig "$primary" 2>/dev/null)"; then
      sleep "$sleep_sec"
      tries=$((tries + 1))
      continue
    fi
    running=$(KUBECONFIG="$spoke_kc" oc get vm -n "$VM_NAMESPACE" --no-headers 2>/dev/null \
      | awk '$3 ~ /Running/ { c++ } END { print c+0 }')
    log "  primary=${primary} running_vms=${running}/${expected}"
    if [[ "$running" -ge "$expected" ]]; then
      log "Edge VMs are Running on ${primary}."
      return 0
    fi
    sleep "$sleep_sec"
    tries=$((tries + 1))
  done
  err "Timed out waiting for Running VMs on primary."
  return 1
}

verify_writers_recording() {
  require_cmd ssh
  ssh_extra_opts
  local expected="${DR_VALIDATION_EXPECTED_VMS}"

  local primary spoke_kc
  primary="$(determine_primary_cluster)"
  [[ -z "$primary" ]] && primary="ocp-primary"
  spoke_kc="$(resolve_spoke_kubeconfig "$primary")"

  local ok=0 fail=0 log_path="${DR_VALIDATION_LOG_PATH}"
  while IFS=$'\t' read -r route_name host port; do
    [[ -z "$route_name" ]] && continue
    port="${port:-22}"
    if ssh -p "$port" "${SSH_OPTS[@]}" "${SSH_USER}@${host}" bash -s "$log_path" <<'CHECK' 2>/dev/null
set -euo pipefail
log_path="$1"
systemctl is-active --quiet ramendr-dr-writer.service
test -s "$log_path"
tail -n 1 "$log_path" | grep -qE '^[0-9]+,'
CHECK
    then
      log "  OK ${route_name} (${host}:${port})"
      ok=$((ok + 1))
    else
      warn "  FAIL ${route_name} (${host}:${port})"
      fail=$((fail + 1))
    fi
  done < <(list_vm_ssh_hosts "$spoke_kc")

  if [[ "$ok" -lt "$expected" ]] || [[ "$fail" -gt 0 ]]; then
    err "Verified ${ok}/${expected} writers; ${fail} failed."
    return 1
  fi
  log "All ${ok} timestamp writer(s) running and recording."
  return 0
}

dr_validation_uses_hammerdb() {
  [[ "${DR_VALIDATION_MODE}" == "hammerdb" ]]
}

hammerdb_vm_platform() {
  local name="$1"
  if [[ "$name" == windows* ]]; then
    echo windows
  else
    echo linux
  fi
}

hammerdb_vm_ssh_user() {
  local name="$1"
  if [[ "$(hammerdb_vm_platform "$name")" == windows ]]; then
    echo "${WINDOWS_SSH_USER}"
  else
    echo "${SSH_USER}"
  fi
}

hammerdb_vm_is_target() {
  local name="$1"
  local vm
  if [[ -n "${DR_VALIDATION_HAMMERDB_VMS:-}" ]]; then
    IFS=',' read -ra targets <<< "${DR_VALIDATION_HAMMERDB_VMS}"
    for vm in "${targets[@]}"; do
      vm="${vm#"${vm%%[![:space:]]*}"}"
      vm="${vm%"${vm##*[![:space:]]}"}"
      [[ -n "$vm" && "$name" == "$vm" ]] && return 0
    done
    return 1
  fi
  if [[ "${DR_VALIDATION_HAMMERDB_ALL_VMS:-1}" == "1" ]]; then
    return 0
  fi
  [[ "$name" == "${DR_VALIDATION_HAMMERDB_VM}" ]]
}

hammerdb_target_vm_count() {
  if [[ -n "${DR_VALIDATION_HAMMERDB_VMS:-}" ]]; then
    local count=0 vm
    IFS=',' read -ra targets <<< "${DR_VALIDATION_HAMMERDB_VMS}"
    for vm in "${targets[@]}"; do
      vm="${vm#"${vm%%[![:space:]]*}"}"
      vm="${vm%"${vm##*[![:space:]]}"}"
      [[ -n "$vm" ]] && count=$((count + 1))
    done
    echo "$count"
    return 0
  fi
  if [[ "${DR_VALIDATION_HAMMERDB_ALL_VMS:-1}" == "1" ]]; then
    echo "${DR_VALIDATION_EXPECTED_VMS:-4}"
    return 0
  fi
  echo 1
}

load_mssql_credentials() {
  if [[ -n "${DR_VALIDATION_MSSQL_SA_PASSWORD:-}" \
    && -n "${DR_VALIDATION_MSSQL_USER:-}" \
    && -n "${DR_VALIDATION_MSSQL_PASSWORD:-}" ]]; then
    return 0
  fi
  if [[ ! -f "$VALUES_SECRET" ]]; then
    return 1
  fi
  local parsed
  parsed="$(python3 - "$VALUES_SECRET" <<'PY'
import re, sys

text = open(sys.argv[1]).read()
values = {}
for key, pattern in (
    ("sa_password", r"sa_password:\s*['\"]?([^'\"#\s]+)"),
    ("user", r"user:\s*['\"]?([^'\"#\s]+)"),
    ("password", r"password:\s*['\"]?([^'\"#\s]+)"),
):
    m = re.search(
        rf"mssql-hammerdb:\s*(?:#.*\n)*\s*{pattern}",
        text,
        re.MULTILINE,
    )
    if m:
        values[key] = m.group(1)
if len(values) < 3:
    def secret_block(secret: str) -> str:
        m = re.search(
            rf"^(?:  )?- name:\s*{re.escape(secret)}\s*$",
            text,
            re.MULTILINE,
        )
        if m:
            rest = text[m.end() :]
            n = re.search(r"^(?:  )?- (?:name:|fields:)", rest, re.MULTILINE)
            end = m.end() + (n.start() if n else len(rest))
            return text[m.start() : end]
        for m in re.finditer(r"^- fields:", text, re.MULTILINE):
            rest = text[m.end() :]
            n = re.search(r"^- (?:name:|fields:)", rest, re.MULTILINE)
            block = text[m.start() : m.end() + (n.start() if n else len(rest))]
            if re.search(rf"name:\s*{re.escape(secret)}\s*$", block, re.MULTILINE):
                return block
        return ""

    block = secret_block("mssql-hammerdb")
    if block:
        values = {}
        for key in ("sa_password", "user", "password"):
            m = re.search(
                rf"^\s*- name:\s*{re.escape(key)}\s*\n\s*value:\s*['\"]?([^'\"#\n]+)",
                block,
                re.MULTILINE,
            )
            if m:
                values[key] = m.group(1)
if len(values) == 3:
    print(values["sa_password"])
    print(values["user"])
    print(values["password"])
PY
)" || return 1
  if [[ -z "$parsed" ]]; then
    return 1
  fi
  DR_VALIDATION_MSSQL_SA_PASSWORD="${DR_VALIDATION_MSSQL_SA_PASSWORD:-$(sed -n '1p' <<<"$parsed")}"
  DR_VALIDATION_MSSQL_USER="${DR_VALIDATION_MSSQL_USER:-$(sed -n '2p' <<<"$parsed")}"
  DR_VALIDATION_MSSQL_PASSWORD="${DR_VALIDATION_MSSQL_PASSWORD:-$(sed -n '3p' <<<"$parsed")}"
  [[ -n "${DR_VALIDATION_MSSQL_SA_PASSWORD:-}" \
    && -n "${DR_VALIDATION_MSSQL_USER:-}" \
    && -n "${DR_VALIDATION_MSSQL_PASSWORD:-}" ]]
}

ensure_mssql_credentials() {
  load_mssql_credentials || true
  if [[ -n "${DR_VALIDATION_MSSQL_SA_PASSWORD:-}" \
    && -n "${DR_VALIDATION_MSSQL_USER:-}" \
    && -n "${DR_VALIDATION_MSSQL_PASSWORD:-}" ]]; then
    return 0
  fi
  err "Windows MSSQL install requires DR_VALIDATION_MSSQL_SA_PASSWORD, DR_VALIDATION_MSSQL_USER, and DR_VALIDATION_MSSQL_PASSWORD (or mssql-hammerdb in VALUES_SECRET)."
  return 1
}

load_windows_ssh_password() {
  if [[ -n "${WINDOWS_SSH_PASSWORD:-}" ]]; then
    return 0
  fi
  if [[ -n "${DR_VALIDATION_WINDOWS_SSH_PASSWORD:-}" ]]; then
    WINDOWS_SSH_PASSWORD="${DR_VALIDATION_WINDOWS_SSH_PASSWORD}"
    return 0
  fi
  if [[ -f "$VALUES_SECRET" ]]; then
    WINDOWS_SSH_PASSWORD=$(python3 - "$VALUES_SECRET" <<'PY'
import re, sys

text = open(sys.argv[1]).read()
m = re.search(
    r"windows-admin:\s*(?:#.*\n)*\s*password:\s*['\"]?([^'\"#\s]+)",
    text,
    re.MULTILINE,
)
if m:
    print(m.group(1))
    raise SystemExit(0)

def secret_block(secret: str) -> str:
    m = re.search(
        rf"^(?:  )?- name:\s*{re.escape(secret)}\s*$",
        text,
        re.MULTILINE,
    )
    if m:
        rest = text[m.end() :]
        n = re.search(r"^(?:  )?- (?:name:|fields:)", rest, re.MULTILINE)
        end = m.end() + (n.start() if n else len(rest))
        return text[m.start() : end]
    for m in re.finditer(r"^- fields:", text, re.MULTILINE):
        rest = text[m.end() :]
        n = re.search(r"^- (?:name:|fields:)", rest, re.MULTILINE)
        block = text[m.start() : m.end() + (n.start() if n else len(rest))]
        if re.search(rf"name:\s*{re.escape(secret)}\s*$", block, re.MULTILINE):
            return block
    return ""

block = secret_block("windows-admin")
if block:
    m = re.search(
        r"^\s*- name:\s*password\s*\n\s*value:\s*['\"]?([^'\"#\n]+)",
        block,
        re.MULTILINE,
    )
    if m:
        print(m.group(1))
        raise SystemExit(0)
PY
)
    [[ -n "${WINDOWS_SSH_PASSWORD:-}" ]] && return 0
  fi
  ensure_hub_kubeconfig
  WINDOWS_SSH_PASSWORD=$(oc exec -n vault vault-0 -- vault kv get -field=password secret/global/windows-admin 2>/dev/null || true)
  [[ -n "${WINDOWS_SSH_PASSWORD:-}" ]]
}

get_hammerdb_vm_hosts() {
  local kubeconfig="$1"
  local count=0 route_name host port platform ssh_user
  while IFS=$'\t' read -r route_name host port; do
    [[ -z "$route_name" ]] && continue
    hammerdb_vm_is_target "$route_name" || continue
    platform="$(hammerdb_vm_platform "$route_name")"
    ssh_user="$(hammerdb_vm_ssh_user "$route_name")"
    echo "${route_name}	${host}	${port:-22}	${platform}	${ssh_user}"
    count=$((count + 1))
  done < <(list_vm_ssh_hosts "$kubeconfig")
  if [[ "$count" -eq 0 ]]; then
    err "No SSH endpoints for HammerDB targets in gitops-vms."
    return 1
  fi
}

get_hammerdb_vm_host() {
  local kubeconfig="$1"
  get_hammerdb_vm_hosts "$kubeconfig" | head -1
}
