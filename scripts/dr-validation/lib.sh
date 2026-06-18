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
DR_VALIDATION_HAMMERDB_VM="${DR_VALIDATION_HAMMERDB_VM:-rhel9-node-001}"
DR_VALIDATION_DB_SNAPSHOT_ROOT="${DR_VALIDATION_DB_SNAPSHOT_ROOT:-${REPO_ROOT}/.work/dr-validation-db/auto}"
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
  local expected="${DR_VALIDATION_EXPECTED_VMS:-4}"
  local max_tries="${DR_VALIDATION_WAIT_MAX_TRIES:-60}"
  local sleep_sec="${DR_VALIDATION_WAIT_SLEEP:-30}"

  local hub_install_dir="${HUB_INSTALL_DIR:-$HOME/git/hub-cluster-install}"
  if [[ -z "${KUBECONFIG:-}" ]] && [[ -f "${hub_install_dir}/auth/kubeconfig" ]]; then
    export KUBECONFIG="${hub_install_dir}/auth/kubeconfig"
  fi

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
  "$DR_VALIDATION_SCRIPT_DIR/collect-db-snapshot-incluster.sh" "$dest"
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
  local expected="${DR_VALIDATION_EXPECTED_VMS:-4}"
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
  local expected="${DR_VALIDATION_EXPECTED_VMS:-4}"

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

get_hammerdb_vm_host() {
  local kubeconfig="$1"
  local target="${DR_VALIDATION_HAMMERDB_VM:-}"
  while IFS=$'\t' read -r route_name host port; do
    [[ -z "$route_name" ]] && continue
    if [[ -n "$target" && "$route_name" != "$target" ]]; then
      continue
    fi
    echo "${route_name}	${host}	${port:-22}"
    return 0
  done < <(list_vm_ssh_hosts "$kubeconfig")
  if [[ -n "$target" ]]; then
    warn "HammerDB target VM '${target}' not found; using first gitops-vms SSH endpoint."
    while IFS=$'\t' read -r route_name host port; do
      [[ -z "$route_name" ]] && continue
      echo "${route_name}	${host}	${port:-22}"
      return 0
    done < <(list_vm_ssh_hosts "$kubeconfig")
  fi
  err "No SSH endpoints for HammerDB target in gitops-vms."
  return 1
}
