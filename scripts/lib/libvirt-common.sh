#!/usr/bin/env bash
# shellcheck shell=bash
# Shared libvirt compact-cluster inventory for libvirt-provision.sh.
#
# Three compact 3-node clusters on one hypervisor (ocp-edge111-class):
#   Hub:   16 vCPU / 48 GiB (LIBVIRT_HUB_*) — ODF-friendly
#   Spokes: 8 vCPU / 24 GiB (LIBVIRT_SPOKE_* / LIBVIRT_VCPUS)
#   Disks: 120 GiB OS + per-cluster OSD disk (LIBVIRT_*_OSD_GIB)

: "${LIBVIRT_SSH_USER:=root}"
: "${LIBVIRT_IMAGE_DIR:=/var/lib/libvirt/images}"
: "${LIBVIRT_REMOTE_WORKDIR:=/var/lib/ramendr-libvirt}"
# Shared / spoke defaults (compact). Hub is upsized separately — ODF on hub
# needs more CPU/RAM than 8/24Gi (MDS/NooBaa Pending on ocp-edge111-class HVs).
: "${LIBVIRT_VCPUS:=8}"
: "${LIBVIRT_MEMORY_MIB:=24576}"
: "${LIBVIRT_SPOKE_VCPUS:=${LIBVIRT_VCPUS}}"
: "${LIBVIRT_SPOKE_MEMORY_MIB:=${LIBVIRT_MEMORY_MIB}}"
# Hub defaults: 16 vCPU / 48 GiB. On a 96 CPU / ~256 GiB HV with 6× spoke
# 8/24Gi this is ~96 vCPU committed and mild RAM overcommit (lab-OK).
: "${LIBVIRT_HUB_VCPUS:=16}"
: "${LIBVIRT_HUB_MEMORY_MIB:=49152}"
: "${LIBVIRT_OS_DISK_GIB:=120}"
: "${LIBVIRT_HUB_OSD_GIB:=100}"
: "${LIBVIRT_SPOKE_OSD_GIB:=200}"
: "${LIBVIRT_OS_VARIANT:=rhel8.0}"
: "${LIBVIRT_INSTALL_PARALLEL_SPOKES:=0}"
: "${HUB_OCP_VERSION:=4.22.1}"
: "${BASE_DOMAIN:=}"

# Derive BASE_DOMAIN from the hub install-config when unset (common on HV
# pattern-only sessions that do not forward BASE_DOMAIN from the laptop).
libvirt_resolve_base_domain() {
  if [[ -n "${BASE_DOMAIN:-}" ]]; then
    return 0
  fi
  local ic candidate=""
  for ic in \
    "${HUB_INSTALL_DIR:-}/install-config.yaml" \
    "${LIBVIRT_REMOTE_WORKDIR:-/var/lib/ramendr-libvirt}/hub-cluster-install/install-config.yaml" \
    "$(libvirt_install_dir_for hub 2>/dev/null || true)/install-config.yaml"; do
    [[ -n "$ic" && -f "$ic" ]] || continue
    candidate="$(awk '/^baseDomain:[[:space:]]*/ { print $2; exit }' "$ic" 2>/dev/null || true)"
    candidate="${candidate//\"/}"
    candidate="${candidate//\'/}"
    if [[ -n "$candidate" ]]; then
      BASE_DOMAIN="$candidate"
      export BASE_DOMAIN
      _lv_log "Derived BASE_DOMAIN=${BASE_DOMAIN} from ${ic}"
      return 0
    fi
  done
  _lv_warn "BASE_DOMAIN is empty and could not be read from hub install-config."
  return 1
}

# Used by libvirt-vms.sh (sourced after this file).
# shellcheck disable=SC2034
LIBVIRT_LEGACY_VMS=(
  ocp3m2w-ic4s22-master-0
  ocp3m2w-ic4s22-master-1
  ocp3m2w-ic4s22-master-2
  ocp3m2w-ic4s22-worker-0
  ocp3m2w-ic4s22-worker-1
)

LIBVIRT_CLUSTERS=(hub ocp-primary ocp-secondary)

_lv_log() {
  if [[ $(type -t log) == function ]]; then
    log "$@"
  else
    echo "[libvirt] $*"
  fi
}

_lv_warn() {
  if [[ $(type -t warn) == function ]]; then
    warn "$@"
  else
    echo "[libvirt] WARNING: $*" >&2
  fi
}

_lv_err() {
  if [[ $(type -t err) == function ]]; then
    err "$@"
  else
    echo "[libvirt] ERROR: $*" >&2
  fi
}

libvirt_cluster_prefix() {
  case "$1" in
    hub) echo "70" ;;
    ocp-primary) echo "71" ;;
    ocp-secondary) echo "72" ;;
    *) return 1 ;;
  esac
}

libvirt_network_name() {
  case "$1" in
    hub) echo "ramendr-hub" ;;
    ocp-primary) echo "ramendr-primary" ;;
    ocp-secondary) echo "ramendr-secondary" ;;
    *) return 1 ;;
  esac
}

libvirt_bridge_name() {
  case "$1" in
    hub) echo "virbr-rd-hub" ;;
    ocp-primary) echo "virbr-rd-pri" ;;
    ocp-secondary) echo "virbr-rd-sec" ;;
    *) return 1 ;;
  esac
}

libvirt_cidr() {
  local p
  p="$(libvirt_cluster_prefix "$1")" || return 1
  echo "192.168.${p}.0/24"
}

libvirt_gateway() {
  local p
  p="$(libvirt_cluster_prefix "$1")" || return 1
  echo "192.168.${p}.1"
}

libvirt_api_vip() {
  local p
  p="$(libvirt_cluster_prefix "$1")" || return 1
  echo "192.168.${p}.10"
}

libvirt_ingress_vip() {
  local p
  p="$(libvirt_cluster_prefix "$1")" || return 1
  echo "192.168.${p}.11"
}

libvirt_node_ip() {
  local p idx="$2"
  p="$(libvirt_cluster_prefix "$1")" || return 1
  echo "192.168.${p}.$((21 + idx))"
}

libvirt_node_mac() {
  local p idx="$2"
  p="$(libvirt_cluster_prefix "$1")" || return 1
  printf '52:54:00:%s:00:%02x\n' "$p" "$((idx + 1))"
}

libvirt_vm_name() {
  echo "${1}-master-${2}"
}

libvirt_osd_gib() {
  case "$1" in
    hub) echo "${LIBVIRT_HUB_OSD_GIB}" ;;
    *) echo "${LIBVIRT_SPOKE_OSD_GIB}" ;;
  esac
}

libvirt_cluster_vcpus() {
  case "$1" in
    hub) echo "${LIBVIRT_HUB_VCPUS}" ;;
    *) echo "${LIBVIRT_SPOKE_VCPUS}" ;;
  esac
}

libvirt_cluster_memory_mib() {
  case "$1" in
    hub) echo "${LIBVIRT_HUB_MEMORY_MIB}" ;;
    *) echo "${LIBVIRT_SPOKE_MEMORY_MIB}" ;;
  esac
}

libvirt_cluster_network_cidr() {
  case "$1" in
    hub) echo "10.128.0.0/14" ;;
    ocp-primary) echo "10.132.0.0/14" ;;
    ocp-secondary) echo "10.136.0.0/14" ;;
    *) return 1 ;;
  esac
}

libvirt_service_network_cidr() {
  case "$1" in
    hub) echo "172.30.0.0/16" ;;
    ocp-primary) echo "172.31.0.0/16" ;;
    ocp-secondary) echo "172.32.0.0/16" ;;
    *) return 1 ;;
  esac
}

# Short, path-safe label for the hypervisor (LIBVIRT_HOST or local hostname).
# Example: LIBVIRT_HOST=ocp-edge111.example.com → ocp-edge111
libvirt_hypervisor_label() {
  local host="${LIBVIRT_HOST:-}"
  if [[ -z "$host" ]]; then
    host="$(hostname -s 2>/dev/null || hostname 2>/dev/null || echo localhost)"
  fi
  host="${host%%.*}"
  host="$(printf '%s' "$host" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9._-]/-/g')"
  [[ -n "$host" ]] || host="localhost"
  printf '%s\n' "$host"
}

# Caller-side kubeconfig root for libvirt (keeps AWS ~/git/*-install dirs untouched).
# Override with LIBVIRT_INSTALL_ROOT, or set HUB/PRIMARY/SECONDARY_INSTALL_DIR explicitly.
libvirt_default_install_root() {
  printf '%s\n' "${LIBVIRT_INSTALL_ROOT:-$HOME/git/libvirt/$(libvirt_hypervisor_label)}"
}

# Set HUB/PRIMARY/SECONDARY_INSTALL_DIR defaults under ~/git/libvirt/<hv>/ when unset.
# On the hypervisor (LIBVIRT_REMOTE_SESSION=1), default to LIBVIRT_REMOTE_WORKDIR
# where libvirt-provision.sh writes kubeconfigs.
libvirt_apply_default_install_dirs() {
  local root
  if [[ "${LIBVIRT_REMOTE_SESSION:-}" == "1" ]]; then
    root="${LIBVIRT_INSTALL_ROOT:-${LIBVIRT_REMOTE_WORKDIR}}"
  else
    root="$(libvirt_default_install_root)"
  fi
  : "${HUB_INSTALL_DIR:=${root}/hub-cluster-install}"
  : "${PRIMARY_INSTALL_DIR:=${root}/ocp-primary-install}"
  : "${SECONDARY_INSTALL_DIR:=${root}/ocp-secondary-install}"
  export HUB_INSTALL_DIR PRIMARY_INSTALL_DIR SECONDARY_INSTALL_DIR
}

libvirt_install_dir_for() {
  local root
  root="$(libvirt_default_install_root)"
  case "$1" in
    hub) echo "${HUB_INSTALL_DIR:-${root}/hub-cluster-install}" ;;
    ocp-primary) echo "${PRIMARY_INSTALL_DIR:-${root}/ocp-primary-install}" ;;
    ocp-secondary) echo "${SECONDARY_INSTALL_DIR:-${root}/ocp-secondary-install}" ;;
    *) return 1 ;;
  esac
}

libvirt_owned_vms() {
  local cluster i
  for cluster in "${LIBVIRT_CLUSTERS[@]}"; do
    for i in 0 1 2; do
      libvirt_vm_name "$cluster" "$i"
    done
  done
}

libvirt_is_remote() {
  [[ -n "${LIBVIRT_HOST:-}" && "${LIBVIRT_REMOTE_SESSION:-}" != "1" ]]
}
