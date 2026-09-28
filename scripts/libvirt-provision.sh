#!/usr/bin/env bash
# macOS ships bash 3.2 (no mapfile). Re-exec with Homebrew bash when available.
# shellcheck source=lib/gnu-bash-reexec.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/gnu-bash-reexec.sh"
set -euo pipefail

#
# Provision three compact OCP clusters on a libvirt hypervisor (agent-based).
# Does not apply the RamenDR pattern — use scripts/redeploy.sh --pattern-only
# with REDEPLOY_PLATFORM=libvirt after kubeconfigs exist.
#
# Typical Tekton / remote:
#   export LIBVIRT_HOST=ocp-edge111.example.com
#   export PULL_SECRET_FILE=/var/run/secrets/pull-secret
#   export SSH_PUBKEY_FILE=/var/run/secrets/ssh.pub
#   export BASE_DOMAIN=lab.example.com
#   ./scripts/libvirt-provision.sh
#

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=lib/libvirt-common.sh
source "$REPO_ROOT/scripts/lib/libvirt-common.sh"
# shellcheck source=lib/libvirt-ssh.sh
source "$REPO_ROOT/scripts/lib/libvirt-ssh.sh"
# shellcheck source=lib/libvirt-networks.sh
source "$REPO_ROOT/scripts/lib/libvirt-networks.sh"
# shellcheck source=lib/libvirt-vms.sh
source "$REPO_ROOT/scripts/lib/libvirt-vms.sh"
# shellcheck source=lib/libvirt-agent.sh
source "$REPO_ROOT/scripts/lib/libvirt-agent.sh"

# Caller-side kubeconfigs default to ~/git/libvirt/<hypervisor>/… (not AWS ~/git/*-install).
libvirt_apply_default_install_dirs

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log() { echo -e "${GREEN}[$(date +%H:%M:%S)]${NC} $*"; }
warn() { echo -e "${YELLOW}[$(date +%H:%M:%S)] WARNING:${NC} $*"; }
err() { echo -e "${RED}[$(date +%H:%M:%S)] ERROR:${NC} $*"; }

usage() {
  cat <<EOF
Usage: ./scripts/libvirt-provision.sh [--destroy|--destroy-legacy|--help]

  (no args)          Create routed libvirt networks, 9 compact VMs, agent-based OCP 4.22 install
  --destroy          Destroy VMs and networks created by this script
  --destroy-legacy   Destroy ocp3m2w-ic4s22 VMs only (explicit; never implicit)
  --help             Show this help

Environment:
  LIBVIRT_HOST            Hypervisor hostname; when set, virt/wait run over SSH
  LIBVIRT_SSH_USER        SSH user (default root)
  LIBVIRT_SSH_OPTS        Extra ssh/scp options (default: BatchMode=yes,
                          StrictHostKeyChecking=no, UserKnownHostsFile=/dev/null)
  LIBVIRT_UPLINK_IFACE    NIC for guest MASQUERADE (default: detected from default route)
  BASE_DOMAIN             Cluster base domain (required; no Route53)
  PULL_SECRET_FILE        Path to pull-secret JSON (required for install)
  SSH_PUBKEY_FILE         Path to SSH public key for core@ (required for install)
  HUB_OCP_VERSION         openshift-install version (default 4.22.1)
  HUB_INSTALL_DIR         Hub kubeconfig dest (default ~/git/libvirt/<hv>/hub-cluster-install)
  PRIMARY_INSTALL_DIR     Primary kubeconfig dest
  SECONDARY_INSTALL_DIR   Secondary kubeconfig dest
  LIBVIRT_INSTALL_ROOT    Parent for those defaults (default ~/git/libvirt/<hv>)
  LIBVIRT_INSTALL_PARALLEL_SPOKES  Set 1 to install spokes in parallel after hub
  LIBVIRT_VCPUS / LIBVIRT_MEMORY_MIB
                          Base size; also default for spokes (8 / 24576 MiB)
  LIBVIRT_SPOKE_VCPUS / LIBVIRT_SPOKE_MEMORY_MIB
                          Spoke node size (defaults to LIBVIRT_VCPUS/MEMORY)
  LIBVIRT_HUB_VCPUS / LIBVIRT_HUB_MEMORY_MIB
                          Hub node size (default 16 / 49152 MiB — hub-only upsize)
  LIBVIRT_HUB_OSD_GIB / LIBVIRT_SPOKE_OSD_GIB
                          Extra virtio disk for LSO/ODF (default 100 / 200)

  <hv> is the short name from LIBVIRT_HOST, or hostname -s when unset.
EOF
}

check_install_prereqs() {
  local missing=0
  if [[ -z "${BASE_DOMAIN:-}" ]]; then
    err "BASE_DOMAIN is not set."
    missing=1
  fi
  if [[ -z "${PULL_SECRET_FILE:-}" || ! -f "$PULL_SECRET_FILE" ]]; then
    err "PULL_SECRET_FILE is missing (path to pull-secret JSON)."
    missing=1
  fi
  if [[ -z "${SSH_PUBKEY_FILE:-}" || ! -f "$SSH_PUBKEY_FILE" ]]; then
    err "SSH_PUBKEY_FILE is missing (SSH public key for cluster nodes)."
    missing=1
  fi
  if [[ -z "${LIBVIRT_HOST:-}" || "${LIBVIRT_REMOTE_SESSION:-}" == "1" ]]; then
    for cmd in virsh virt-install qemu-img python3 curl tar; do
      if ! command -v "$cmd" >/dev/null; then
        err "Missing on hypervisor: $cmd"
        missing=1
      fi
    done
    if ! python3 -c "import yaml" 2>/dev/null; then
      err "PyYAML is required on the hypervisor (python3 -m pip install pyyaml)."
      missing=1
    fi
  else
    for cmd in ssh scp python3; do
      if ! command -v "$cmd" >/dev/null; then
        err "Missing locally: $cmd"
        missing=1
      fi
    done
  fi
  [[ $missing -eq 0 ]] || { err "Prerequisites not met. Aborting."; exit 1; }
}

provision_all() {
  check_install_prereqs
  log "Kubeconfig dirs: hub=$HUB_INSTALL_DIR primary=$PRIMARY_INSTALL_DIR secondary=$SECONDARY_INSTALL_DIR"
  if libvirt_is_remote; then
    libvirt_reexec_on_host
    return
  fi
  libvirt_ensure_all_networks
  libvirt_install_all_clusters
  log "Libvirt provision complete. Next: REDEPLOY_PLATFORM=libvirt LIBVIRT_HOST=\$LIBVIRT_HOST ./scripts/redeploy.sh --pattern-only"
}

destroy_owned() {
  if libvirt_is_remote; then
    libvirt_reexec_on_host --destroy
    return
  fi
  libvirt_destroy_owned_vms
  libvirt_destroy_networks
  log "Destroyed ramendr libvirt VMs and networks."
}

destroy_legacy() {
  if libvirt_is_remote; then
    libvirt_reexec_on_host --destroy-legacy
    return
  fi
  libvirt_destroy_legacy_vms
  log "Destroyed legacy ocp3m2w-ic4s22 VMs (if they existed)."
}

case "${1:-}" in
  --destroy)
    destroy_owned
    ;;
  --destroy-legacy)
    destroy_legacy
    ;;
  --help|-h)
    usage
    ;;
  "")
    provision_all
    ;;
  *)
    err "Unknown argument: $1"
    usage
    exit 1
    ;;
esac
