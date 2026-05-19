#!/usr/bin/env bash
set -euo pipefail

# Install and start the RamenDR timestamp writer on edge VMs (via SSH + Routes).
#
# Usage:
#   ./scripts/dr-validation/install-writer.sh [vm-route-name-prefix]
# Environment:
#   KUBECONFIG or HUB_INSTALL_DIR — hub access to resolve primary cluster
#   PRIMARY_INSTALL_DIR / SECONDARY_INSTALL_DIR — spoke kubeconfigs
#   SSH_USER, SSH_IDENTITY_FILE

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

FILTER="${1:-}"

require_cmd oc python3 scp ssh
ssh_extra_opts

hub_install_dir="${HUB_INSTALL_DIR:-$HOME/git/hub-cluster-install}"
if [[ -z "${KUBECONFIG:-}" ]] && [[ -f "${hub_install_dir}/auth/kubeconfig" ]]; then
  export KUBECONFIG="${hub_install_dir}/auth/kubeconfig"
fi

PRIMARY="$(determine_primary_cluster)"
if [[ -z "$PRIMARY" ]]; then
  err "Could not determine primary cluster from DRPC. Set KUBECONFIG to hub and ensure DR is configured."
  exit 1
fi
log "Primary cluster (VMs expected here): $PRIMARY"

SPOKE_KC="$(resolve_spoke_kubeconfig "$PRIMARY")"
log "Using spoke kubeconfig: $SPOKE_KC"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

mkdir -p "$TMP_DIR/ramendr_dr_validation"
install -m 0644 "$DR_VALIDATION_DIR/ramendr_dr_validation/records.py" "$TMP_DIR/ramendr_dr_validation/records.py"
install -m 0644 "$TMP_DIR/ramendr_dr_validation/records.py" "$TMP_DIR/records.py"
touch "$TMP_DIR/ramendr_dr_validation/__init__.py"
install -m 0755 "$DR_VALIDATION_DIR/ramendr_dr_validation/writer.py" "$TMP_DIR/ramendr-dr-writer"
cp "$DR_VALIDATION_DIR/systemd/ramendr-dr-writer.service" "$TMP_DIR/ramendr-dr-writer.service"

installed=0
while IFS=$'\t' read -r route_name host port; do
  [[ -z "$route_name" ]] && continue
  port="${port:-22}"
  if [[ -n "$FILTER" ]] && [[ "$route_name" != *"$FILTER"* ]]; then
    continue
  fi
  log "Installing writer on $route_name (${host}:${port})..."
  scp -P "$port" "${SSH_OPTS[@]}" \
    "$TMP_DIR/ramendr-dr-writer" "$TMP_DIR/records.py" "$TMP_DIR/ramendr-dr-writer.service" \
    "${SSH_USER}@${host}:/tmp/" || { warn "SCP failed for ${host}:${port} — skipping"; continue; }

  ssh -p "$port" "${SSH_OPTS[@]}" "${SSH_USER}@${host}" bash -s <<EOF
set -euo pipefail
sudo mkdir -p /var/lib/ramendr-dr-validation /usr/local/lib/ramendr_dr_validation /usr/local/bin
sudo install -m 0644 /tmp/records.py /usr/local/lib/ramendr_dr_validation/records.py
sudo touch /usr/local/lib/ramendr_dr_validation/__init__.py
sudo install -m 0755 /tmp/ramendr-dr-writer /usr/local/bin/ramendr-dr-writer
sudo install -m 0644 /tmp/ramendr-dr-writer.service /etc/systemd/system/ramendr-dr-writer.service
sudo systemctl daemon-reload
sudo systemctl enable ramendr-dr-writer.service
sudo systemctl restart ramendr-dr-writer.service
systemctl is-active ramendr-dr-writer.service
tail -n 3 /var/lib/ramendr-dr-validation/timestamps.log 2>/dev/null || true
EOF
  installed=$((installed + 1))
done < <(list_vm_ssh_hosts "$SPOKE_KC")

if [[ "$installed" -eq 0 ]]; then
  err "No VMs updated. Check routes in namespace $VM_NAMESPACE on $PRIMARY."
  exit 1
fi
log "Writer installed on $installed VM(s)."
