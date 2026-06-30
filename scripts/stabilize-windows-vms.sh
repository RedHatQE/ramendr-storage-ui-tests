#!/usr/bin/env bash
# Recover paused/unhealthy Windows edge VMs after deploy (sequential restart).
#
# edge-gitops-vms keeps evictionStrategy: LiveMigrate for DR. Mitigations for libvirt
# IOError / SyncVMI stalls are virtio OS disks (fork values) and SPOKE_METAL_REPLICAS=2.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VM_NAMESPACE="${VM_NAMESPACE:-gitops-vms}"
WINDOWS_VM_PATTERN="${WINDOWS_VM_PATTERN:-windows}"
PRIMARY_INSTALL_DIR="${PRIMARY_INSTALL_DIR:-$HOME/git/ocp-primary-install}"
HUB_INSTALL_DIR="${HUB_INSTALL_DIR:-$HOME/git/hub-cluster-install}"
WAIT_TRIES="${WINDOWS_VM_STABILIZE_WAIT_TRIES:-40}"
WAIT_SLEEP="${WINDOWS_VM_STABILIZE_WAIT_SLEEP:-30}"
# regional-dr can be Synced/Healthy before gitops-vms Windows VM objects exist on the spoke.
# Default 60 × 30s = 30 min.
WINDOWS_VM_APPEAR_WAIT_TRIES="${WINDOWS_VM_APPEAR_WAIT_TRIES:-60}"
WINDOWS_VM_APPEAR_WAIT_SLEEP="${WINDOWS_VM_APPEAR_WAIT_SLEEP:-30}"
# Windows OS disks clone from a registry-imported golden image (~45Gi). The VM DV stays
# CloneScheduled (progress N/A) until that import finishes; measured ~70 min on ODF.
# Default 180 × 30s = 90 min.
DV_WAIT_TRIES="${WINDOWS_VM_DV_WAIT_TRIES:-180}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log() { echo -e "${GREEN}[windows-vms]${NC} $*"; }
warn() { echo -e "${YELLOW}[windows-vms] WARNING:${NC} $*"; }
err() { echo -e "${RED}[windows-vms] ERROR:${NC} $*" >&2; }

determine_primary_cluster() {
  local hub_kc="${HUB_INSTALL_DIR}/auth/kubeconfig"
  [[ -f "$hub_kc" ]] || return 1
  KUBECONFIG="$hub_kc" oc get placementdecision -n openshift-dr-ops \
    -l cluster.open-cluster-management.io/placement=gitops-vm-protection-placement-1 \
    -o jsonpath='{.items[0].status.decisions[0].clusterName}' 2>/dev/null || true
}

resolve_spoke_kubeconfig() {
  local cluster="$1"
  local install_dir=""
  case "$cluster" in
    ocp-primary) install_dir="$PRIMARY_INSTALL_DIR" ;;
    ocp-secondary) install_dir="${SECONDARY_INSTALL_DIR:-$HOME/git/ocp-secondary-install}" ;;
    *) return 1 ;;
  esac
  local kc="$install_dir/auth/kubeconfig"
  [[ -f "$kc" ]] || return 1
  echo "$kc"
}

list_windows_vms() {
  KUBECONFIG="$1" oc get vm -n "$VM_NAMESPACE" --no-headers -o custom-columns=':.metadata.name' 2>/dev/null \
    | awk -v pat="$WINDOWS_VM_PATTERN" '$0 ~ pat { print $1 }' | sort
}

vm_os_dv_phase() {
  local kubeconfig="$1" vm="$2"
  KUBECONFIG="$kubeconfig" oc get datavolume "$vm" -n "$VM_NAMESPACE" \
    -o jsonpath='{.status.phase}' 2>/dev/null || true
}

vm_awaiting_os_disk() {
  local kubeconfig="$1" vm="$2"
  local printable dv_phase
  printable="$(KUBECONFIG="$kubeconfig" oc get vm "$vm" -n "$VM_NAMESPACE" \
    -o jsonpath='{.status.printableStatus}' 2>/dev/null || true)"
  dv_phase="$(vm_os_dv_phase "$kubeconfig" "$vm")"

  case "$printable" in
    Provisioning|Starting|WaitingForVolumeBinding|DataVolumeProvisioning|DataVolumeError)
      return 0
      ;;
  esac

  if [[ -n "$dv_phase" && "$dv_phase" != "Succeeded" ]]; then
    return 0
  fi
  return 1
}

vm_is_healthy() {
  local kubeconfig="$1" vm="$2"
  local printable ready paused
  printable="$(KUBECONFIG="$kubeconfig" oc get vm "$vm" -n "$VM_NAMESPACE" \
    -o jsonpath='{.status.printableStatus}' 2>/dev/null || true)"
  ready="$(KUBECONFIG="$kubeconfig" oc get vm "$vm" -n "$VM_NAMESPACE" \
    -o jsonpath='{.status.ready}' 2>/dev/null || true)"
  paused="$(KUBECONFIG="$kubeconfig" oc get vmi "$vm" -n "$VM_NAMESPACE" \
    -o jsonpath='{.status.conditions[?(@.type=="Paused")].status}' 2>/dev/null || true)"
  [[ "$printable" == "Running" && "$ready" == "true" && "$paused" != "True" ]]
}

vm_needs_restart() {
  local kubeconfig="$1" vm="$2"
  # Never restart while OS disk import/clone is still running.
  if vm_awaiting_os_disk "$kubeconfig" "$vm"; then
    return 1
  fi
  local printable ready paused
  printable="$(KUBECONFIG="$kubeconfig" oc get vm "$vm" -n "$VM_NAMESPACE" \
    -o jsonpath='{.status.printableStatus}' 2>/dev/null || true)"
  ready="$(KUBECONFIG="$kubeconfig" oc get vm "$vm" -n "$VM_NAMESPACE" \
    -o jsonpath='{.status.ready}' 2>/dev/null || true)"
  paused="$(KUBECONFIG="$kubeconfig" oc get vmi "$vm" -n "$VM_NAMESPACE" \
    -o jsonpath='{.status.conditions[?(@.type=="Paused")].status}' 2>/dev/null || true)"
  [[ "$printable" == "Paused" || "$paused" == "True" ]] \
    || [[ "$printable" == "Running" && "$ready" != "true" ]]
}

wait_vm_os_dv() {
  local kubeconfig="$1" vm="$2"
  local tries=0 dv_phase progress
  while [[ $tries -lt $DV_WAIT_TRIES ]]; do
    dv_phase="$(vm_os_dv_phase "$kubeconfig" "$vm")"
    if [[ "$dv_phase" == "Succeeded" ]]; then
      log "  ${vm}: OS DataVolume Succeeded"
      return 0
    fi
    if [[ "$dv_phase" == "Failed" ]]; then
      err "  ${vm}: OS DataVolume Failed"
      return 1
    fi
    progress="$(KUBECONFIG="$kubeconfig" oc get datavolume "$vm" -n "$VM_NAMESPACE" \
      -o jsonpath='{.status.progress}' 2>/dev/null || true)"
    log "  ${vm}: OS DataVolume phase=${dv_phase:-Pending} progress=${progress:-n/a} (attempt $((tries + 1))/${DV_WAIT_TRIES})"
    sleep "$WAIT_SLEEP"
    tries=$((tries + 1))
  done
  return 1
}

restart_vm() {
  local kubeconfig="$1" vm="$2"
  export KUBECONFIG="$kubeconfig"
  if command -v virtctl >/dev/null 2>&1; then
    virtctl restart "$vm" -n "$VM_NAMESPACE" --grace-period=0 >/dev/null 2>&1 \
      || virtctl stop "$vm" -n "$VM_NAMESPACE" --grace-period=0 >/dev/null 2>&1 || true
    sleep 5
    virtctl start "$vm" -n "$VM_NAMESPACE" >/dev/null 2>&1 || true
  else
    warn "virtctl not found; deleting VMI to trigger restart for ${vm}"
    oc delete vmi "$vm" -n "$VM_NAMESPACE" --ignore-not-found >/dev/null 2>&1 || true
  fi
}

wait_vm_running() {
  local kubeconfig="$1" vm="$2"
  local tries=0
  while [[ $tries -lt $WAIT_TRIES ]]; do
    local printable ready paused
    printable="$(KUBECONFIG="$kubeconfig" oc get vm "$vm" -n "$VM_NAMESPACE" \
      -o jsonpath='{.status.printableStatus}' 2>/dev/null || true)"
    ready="$(KUBECONFIG="$kubeconfig" oc get vm "$vm" -n "$VM_NAMESPACE" \
      -o jsonpath='{.status.ready}' 2>/dev/null || true)"
    paused="$(KUBECONFIG="$kubeconfig" oc get vmi "$vm" -n "$VM_NAMESPACE" \
      -o jsonpath='{.status.conditions[?(@.type=="Paused")].status}' 2>/dev/null || true)"
    if [[ "$printable" == "Running" && "$ready" == "true" && "$paused" != "True" ]]; then
      log "  ${vm}: Running and ready (evictionStrategy=$(KUBECONFIG="$kubeconfig" oc get vm "$vm" -n "$VM_NAMESPACE" -o jsonpath='{.spec.template.spec.evictionStrategy}' 2>/dev/null || echo LiveMigrate))"
      return 0
    fi
    log "  ${vm}: status=${printable:-<none>} ready=${ready:-false} paused=${paused:-false} (attempt $((tries + 1))/${WAIT_TRIES})"
    sleep "$WAIT_SLEEP"
    tries=$((tries + 1))
  done
  return 1
}

wait_for_windows_vms_on_spoke() {
  local kubeconfig="$1" cluster="$2"
  local tries=0 count

  while [[ $tries -lt $WINDOWS_VM_APPEAR_WAIT_TRIES ]]; do
    count="$(list_windows_vms "$kubeconfig" | wc -l | tr -d ' ')"
    if [[ "${count:-0}" -gt 0 ]]; then
      log "Found ${count} Windows VM(s) in ${VM_NAMESPACE} on ${cluster}."
      return 0
    fi
    log "Waiting for Windows VMs matching '${WINDOWS_VM_PATTERN}' in ${VM_NAMESPACE} on ${cluster} ($((tries + 1))/${WINDOWS_VM_APPEAR_WAIT_TRIES})..."
    sleep "$WINDOWS_VM_APPEAR_WAIT_SLEEP"
    tries=$((tries + 1))
  done

  warn "Timed out waiting for Windows VMs in ${VM_NAMESPACE} on ${cluster}."
  return 1
}

main() {
  if [[ "${SKIP_WINDOWS_VM_STABILIZE:-0}" == "1" ]]; then
    log "SKIP_WINDOWS_VM_STABILIZE=1 — skipping Windows VM stabilization."
    return 0
  fi

  local primary spoke_kc
  primary="$(determine_primary_cluster)"
  [[ -n "$primary" ]] || primary="ocp-primary"
  spoke_kc="$(resolve_spoke_kubeconfig "$primary")" || {
    warn "No kubeconfig for ${primary}; skipping Windows VM stabilization."
    return 0
  }

  if ! wait_for_windows_vms_on_spoke "$spoke_kc" "$primary"; then
    if [[ "${REQUIRE_WINDOWS_VMS:-0}" == "1" ]]; then
      return 1
    fi
    return 0
  fi

  mapfile -t windows_vms < <(list_windows_vms "$spoke_kc")
  if [[ ${#windows_vms[@]} -eq 0 ]]; then
    warn "No Windows VMs matching '${WINDOWS_VM_PATTERN}' in ${VM_NAMESPACE} on ${primary}."
    return 0
  fi

  log "Checking ${#windows_vms[@]} Windows VM(s) on ${primary} (keeping evictionStrategy: LiveMigrate)..."
  local failed=0 vm
  for vm in "${windows_vms[@]}"; do
    if vm_awaiting_os_disk "$spoke_kc" "$vm"; then
      log "  ${vm}: OS disk still provisioning — waiting for DataVolume (no restart)..."
      if ! wait_vm_os_dv "$spoke_kc" "$vm"; then
        warn "  ${vm}: OS DataVolume not ready within timeout — skipping restart."
        failed=1
        continue
      fi
    fi

    if vm_is_healthy "$spoke_kc" "$vm"; then
      log "  ${vm}: healthy — no restart needed"
      continue
    fi

    if vm_needs_restart "$spoke_kc" "$vm"; then
      log "Restarting ${vm} (paused or unhealthy)..."
      restart_vm "$spoke_kc" "$vm"
      if ! wait_vm_running "$spoke_kc" "$vm"; then
        err "${vm} did not reach Running/ready after restart."
        failed=1
      fi
      continue
    fi

    log "  ${vm}: waiting for first boot after OS disk is ready..."
    if ! wait_vm_running "$spoke_kc" "$vm"; then
      err "${vm} did not reach Running/ready."
      failed=1
    fi
  done

  if [[ "$failed" -ne 0 ]]; then
    err "One or more Windows VMs failed stabilization."
    return 1
  fi

  local ensure_script="${REPO_ROOT}/scripts/ensure-windows-openssh.sh"
  if [[ -x "$ensure_script" ]]; then
    log "Ensuring OpenSSH firewall/sshd on Windows VMs (both spokes)..."
    if ! "$ensure_script"; then
      err "OpenSSH ensure failed; sanity SSH probe may fail until fixed."
      return 1
    fi
  else
    err "OpenSSH ensure script not executable: $ensure_script"
    return 1
  fi

  log "Windows VM stabilization complete."
}

main "$@"
