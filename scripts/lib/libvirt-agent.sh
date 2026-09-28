#!/usr/bin/env bash
# shellcheck shell=bash
# Agent-based installer (ABI) for compact 3-node clusters on libvirt.

: "${OPENSHIFT_INSTALL:=openshift-install}"

libvirt_tools_bin_dir() {
  printf '%s\n' "${LIBVIRT_REMOTE_WORKDIR}/bin"
}

# Agent ISO generation shells out to `oc`; download it next to openshift-install when missing.
libvirt_ensure_oc() {
  local ver="$HUB_OCP_VERSION" dest bin
  dest="$(libvirt_tools_bin_dir)"
  mkdir -p "$dest"
  export PATH="${dest}:${PATH}"

  if command -v oc >/dev/null; then
    bin="$(command -v oc)"
    if oc version --client 2>/dev/null | grep -q "$ver"; then
      return 0
    fi
    _lv_warn "oc at $bin is not $ver; downloading $ver into $dest."
  else
    _lv_log "oc not found in PATH; downloading $ver into $dest."
  fi

  local url="https://mirror.openshift.com/pub/openshift-v4/clients/ocp/${ver}/openshift-client-linux.tar.gz"
  _lv_log "Downloading oc $ver..."
  curl -fsSL "$url" | tar -xz -C "$dest" oc kubectl
  chmod +x "$dest/oc" "$dest/kubectl"
  export PATH="${dest}:${PATH}"
  command -v oc >/dev/null || {
    _lv_err "oc still not found after download"
    return 1
  }
}

libvirt_ensure_openshift_install() {
  local ver="$HUB_OCP_VERSION" bin dest
  dest="$(libvirt_tools_bin_dir)"
  mkdir -p "$dest"
  export PATH="${dest}:${PATH}"

  if command -v "$OPENSHIFT_INSTALL" >/dev/null; then
    bin="$(command -v "$OPENSHIFT_INSTALL")"
    if "$bin" version 2>/dev/null | grep -q "$ver"; then
      OPENSHIFT_INSTALL="$bin"
      libvirt_ensure_oc
      return 0
    fi
    _lv_warn "openshift-install at $bin is not $ver; downloading $ver."
  fi
  local url="https://mirror.openshift.com/pub/openshift-v4/clients/ocp/${ver}/openshift-install-linux.tar.gz"
  _lv_log "Downloading openshift-install $ver..."
  curl -fsSL "$url" | tar -xz -C "$dest" openshift-install
  chmod +x "$dest/openshift-install"
  OPENSHIFT_INSTALL="$dest/openshift-install"
  libvirt_ensure_oc
}

libvirt_render_install_files() {
  local cluster="$1" dir="$2"
  local template_dir="${REPO_ROOT}/install-config-examples/libvirt"
  mkdir -p "$dir"
  python3 - "$template_dir" "$dir" "$cluster" "$BASE_DOMAIN" \
    "$(libvirt_cidr "$cluster")" \
    "$(libvirt_cluster_network_cidr "$cluster")" \
    "$(libvirt_service_network_cidr "$cluster")" \
    "$(libvirt_node_ip "$cluster" 0)" \
    "$(libvirt_node_mac "$cluster" 0)" \
    "$(libvirt_node_mac "$cluster" 1)" \
    "$(libvirt_node_mac "$cluster" 2)" \
    "$PULL_SECRET_FILE" \
    "$SSH_PUBKEY_FILE" <<'PY'
import json
import pathlib
import sys

try:
    import yaml
except ImportError as exc:
    raise SystemExit("PyYAML is required to render agent install-config") from exc

(
    template_dir,
    dest,
    cluster,
    base_domain,
    machine_cidr,
    cluster_cidr,
    service_cidr,
    rendezvous,
    mac0,
    mac1,
    mac2,
    pull_path,
    ssh_path,
) = sys.argv[1:14]
pull_raw = pathlib.Path(pull_path).read_text().strip()
try:
    json.loads(pull_raw)
except json.JSONDecodeError as exc:
    raise SystemExit(f"PULL_SECRET_FILE is not valid JSON: {exc}") from exc
ssh = pathlib.Path(ssh_path).read_text().strip()
dest_p = pathlib.Path(dest)
ic_path = pathlib.Path(template_dir) / "install-config.yaml.example"
data = yaml.safe_load(ic_path.read_text())
data["baseDomain"] = base_domain
data["metadata"]["name"] = cluster
data["networking"]["clusterNetwork"][0]["cidr"] = cluster_cidr
data["networking"]["machineNetwork"][0]["cidr"] = machine_cidr
data["networking"]["serviceNetwork"] = [service_cidr]
data["pullSecret"] = pull_raw
data["sshKey"] = ssh
(dest_p / "install-config.yaml").write_text(yaml.safe_dump(data, sort_keys=False))
agent = (pathlib.Path(template_dir) / "agent-config.yaml.example").read_text()
agent = (
    agent.replace("<CLUSTER_NAME>", cluster)
    .replace("<RENDEZVOUS_IP>", rendezvous)
    .replace("<MAC_0>", mac0)
    .replace("<MAC_1>", mac1)
    .replace("<MAC_2>", mac2)
)
(dest_p / "agent-config.yaml").write_text(agent)
PY
  chmod 600 "$dir/install-config.yaml"
}

# Copy the generated agent ISO into LIBVIRT_IMAGE_DIR for virt-install.
# Safe to call again after VM destroy (older undefine --remove-all-storage
# deleted this shared file when it was attached as a cdrom disk).
libvirt_publish_agent_iso() {
  local cluster="$1"
  local dir iso_src iso_dst
  dir="$(libvirt_install_dir_for "$cluster")"
  iso_src="$(find "$dir" -maxdepth 1 -name '*.iso' -print -quit)"
  [[ -n "$iso_src" ]] || { _lv_err "No agent ISO in $dir for $cluster"; return 1; }
  iso_dst="$(libvirt_iso_path "$cluster")"
  mkdir -p "$(dirname "$iso_dst")"
  cp -f "$iso_src" "$iso_dst"
  _lv_log "Agent ISO for $cluster: $iso_dst"
}

libvirt_create_agent_image() {
  local cluster="$1"
  local dir
  dir="$(libvirt_install_dir_for "$cluster")"
  rm -rf "$dir"
  mkdir -p "$dir"
  libvirt_render_install_files "$cluster" "$dir"
  _lv_log "Creating agent ISO for $cluster in $dir (contents of pull-secret are not logged)..."
  "$OPENSHIFT_INSTALL" agent create image --dir "$dir"
  libvirt_publish_agent_iso "$cluster"
}

# Count unique "Host: name" prefixes matching a pattern in the install log.
# Must tolerate zero matches under `set -o pipefail` (grep exit 1 would kill the watcher).
libvirt_install_log_host_count() {
  local log="$1" pattern="$2"
  local n
  n="$(grep -E "$pattern" "$log" 2>/dev/null | grep -oE 'Host: [^,]+' | sort -u | wc -l | tr -d ' ' || true)"
  printf '%s\n' "${n:-0}"
}

# Eject agent ISO after image write; after masters Join, move api DNS off the
# live bootstrap node onto a master (bootkube tears down :6443 on rendezvous).
libvirt_watch_bootstrap_helpers() {
  local cluster="$1" dir="$2"
  local log="$dir/.openshift_install.log"
  local deadline=$((SECONDS + 7200))
  local ejected=0 api_flipped=0
  local hosts_written hosts_rebooting hosts_joined
  local rendezvous_ip
  rendezvous_ip="$(libvirt_node_ip "$cluster" 0)"
  _lv_log "Watching $log for ISO eject + API DNS flip..."
  while (( SECONDS < deadline )); do
    if [[ -f "$log" ]]; then
      hosts_written="$(libvirt_install_log_host_count "$log" \
        'Host: .+reached installation stage Writing image to disk: 100%')"
      hosts_rebooting="$(libvirt_install_log_host_count "$log" \
        'Host: .+reached installation stage Rebooting')"
      hosts_joined="$(libvirt_install_log_host_count "$log" \
        'Host: .+reached installation stage Joined')"
      if (( ejected == 0 && (hosts_written >= 1 || hosts_rebooting >= 1) )); then
        _lv_log "Ejecting agent ISO for $cluster (written=${hosts_written} rebooting=${hosts_rebooting}; no VM reset)..."
        libvirt_eject_agent_iso "$cluster"
        ejected=1
      fi
      if (( hosts_joined >= 1 )); then
        # Prefer a disk-booted master that already serves :6443. Never select
        # rendezvous — that is the failure mode when bootkube tears it down.
        if libvirt_point_api_dns_to_masters "$cluster"; then
          api_flipped=1
        elif (( api_flipped == 0 )); then
          # Bootstrap API on rendezvous gone but masters not listening yet:
          # force DNS to node-1 so wait-for does not stick on .21 refused.
          if ! libvirt_ssh bash -c "timeout 1 bash -c 'echo >/dev/tcp/${rendezvous_ip}/6443'" >/dev/null 2>&1; then
            _lv_log "Rendezvous :6443 down; forcing API DNS to disk masters for $cluster..."
            libvirt_point_api_dns_to_masters "$cluster" force || true
            api_flipped=1
          fi
        fi
      fi
      if (( ejected == 1 && api_flipped == 1 )); then
        _lv_log "Bootstrap helpers armed for $cluster (written=${hosts_written} joined=${hosts_joined}); re-flipping until wait-for exits..."
        while (( SECONDS < deadline )); do
          sleep 15
          # Prefer a master that answers :6443. Only force off rendezvous when
          # guest DNS is still on .21 and bootstrap API is already gone.
          if libvirt_point_api_dns_to_masters "$cluster"; then
            continue
          fi
          cur_api="$(libvirt_ssh dig +short @"$(libvirt_gateway "$cluster")" \
            "api.${cluster}.${BASE_DOMAIN}" 2>/dev/null | head -1 | tr -d '[:space:]' || true)"
          if [[ "$cur_api" == "$rendezvous_ip" ]] \
            && ! libvirt_ssh bash -c "timeout 1 bash -c 'echo >/dev/tcp/${rendezvous_ip}/6443'" >/dev/null 2>&1; then
            libvirt_point_api_dns_to_masters "$cluster" force || true
          fi
        done
        return 0
      fi
    fi
    sleep 2
  done
  if (( ejected == 0 )); then
    _lv_warn "Timed out waiting to eject agent ISO for $cluster"
    return 1
  fi
  return 0
}

libvirt_wait_install() {
  local cluster="$1"
  local dir helper_pid=""
  dir="$(libvirt_install_dir_for "$cluster")"
  _lv_log "Waiting for bootstrap-complete on $cluster..."
  libvirt_watch_bootstrap_helpers "$cluster" "$dir" &
  helper_pid=$!
  if ! "$OPENSHIFT_INSTALL" agent wait-for bootstrap-complete --dir "$dir"; then
    kill "$helper_pid" 2>/dev/null || true
    wait "$helper_pid" 2>/dev/null || true
    return 1
  fi
  kill "$helper_pid" 2>/dev/null || true
  wait "$helper_pid" 2>/dev/null || true
  libvirt_eject_agent_iso "$cluster"
  # Guest api-int must already point at a live master (MCS :22623) before the
  # rendezvous disk boot — otherwise firstboot hangs resolving api-int → .21.
  libvirt_point_api_dns_to_masters "$cluster" force || true
  # Rendezvous stays on liveiso until assisted "Waiting for controller"; force
  # disk boot so the 3rd etcd member joins before install-complete's 40m window.
  libvirt_reboot_rendezvous_onto_disk "$cluster"
  # Rendezvous is on disk now; allow node-0 as an API/apps target.
  libvirt_point_api_dns_to_masters "$cluster" include_rendezvous force || true
  _lv_log "Waiting for install-complete on $cluster..."
  "$OPENSHIFT_INSTALL" agent wait-for install-complete --dir "$dir"
  libvirt_eject_agent_iso "$cluster"
  local kc="$dir/auth/kubeconfig"
  [[ -f "$kc" ]] || { _lv_err "Missing kubeconfig $kc"; return 1; }
  chmod 600 "$kc"
  _lv_log "Cluster $cluster installed. Kubeconfig: $kc"
  # platform none leaves Image Registry Operator Removed (no cloud object
  # storage). Pattern Jobs (ODF node-label) pull
  # image-registry.openshift-image-registry.svc:5000/openshift/cli.
  libvirt_ensure_image_registry "$cluster" "$kc" || true
}

# Nodes' resolv.conf uses libvirt dnsmasq (not CoreDNS). Kubelet image pulls of
# image-registry.openshift-image-registry.svc need that name in addnhosts.
libvirt_ensure_image_registry_dns() {
  local cluster="$1" kubeconfig="$2"
  local svc_ip name
  svc_ip="$(KUBECONFIG="$kubeconfig" oc get svc image-registry \
    -n openshift-image-registry -o jsonpath='{.spec.clusterIP}' 2>/dev/null || true)"
  [[ -n "$svc_ip" ]] || return 1
  name="$(libvirt_network_name "$cluster")"
  # shellcheck disable=SC2087
  libvirt_ssh bash -s -- "$name" "$svc_ip" <<'EOS' || return 1
set -euo pipefail
name="$1" ip="$2"
f="/var/lib/libvirt/dnsmasq/${name}.addnhosts"
[[ -f "$f" ]] || exit 0
grep -v 'image-registry.openshift-image-registry.svc' "$f" > "${f}.new" || true
echo "${ip} image-registry.openshift-image-registry.svc image-registry.openshift-image-registry.svc.cluster.local" >> "${f}.new"
mv "${f}.new" "$f"
pidfile="/run/libvirt/network/${name}.pid"
if [[ -f "$pidfile" ]]; then
  pid="$(cat "$pidfile" 2>/dev/null || true)"
  if [[ -n "${pid}" ]] && kill -0 "$pid" 2>/dev/null; then
    kill -HUP "$pid" || true
  fi
fi
EOS
  _lv_log "[$cluster] Guest DNS: image-registry.openshift-image-registry.svc -> ${svc_ip}"
}

# platform none / bare metal: Image Registry Operator bootstraps as Removed so
# install can finish without shareable object storage. Lab clusters need Managed
# + emptyDir so in-cluster ImageStream pulls work (non-production; images are
# lost if the registry pod restarts). See OCP "Configuring the registry for bare metal".
libvirt_ensure_image_registry() {
  local cluster="$1"
  local kubeconfig="${2:-}"
  local dir state tries=0

  if [[ -z "$kubeconfig" ]]; then
    dir="$(libvirt_install_dir_for "$cluster")"
    kubeconfig="${dir}/auth/kubeconfig"
  fi
  [[ -f "$kubeconfig" ]] || {
    _lv_warn "[$cluster] No kubeconfig for image registry ensure (${kubeconfig})."
    return 0
  }
  command -v oc >/dev/null || {
    _lv_warn "[$cluster] oc not in PATH; skipping image registry ensure."
    return 0
  }

  if KUBECONFIG="$kubeconfig" oc get co image-registry \
       -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null \
       | grep -qx True \
     && KUBECONFIG="$kubeconfig" oc get svc image-registry \
       -n openshift-image-registry >/dev/null 2>&1; then
    state="$(KUBECONFIG="$kubeconfig" oc get configs.imageregistry.operator.openshift.io cluster \
      -o jsonpath='{.spec.managementState}' 2>/dev/null || true)"
    if [[ "$state" == "Managed" ]]; then
      _lv_log "[$cluster] Image registry already Managed and Available."
      libvirt_ensure_image_registry_dns "$cluster" "$kubeconfig" || true
      return 0
    fi
  fi

  _lv_log "[$cluster] Enabling Image Registry (Managed + emptyDir; platform none default is Removed)..."
  if ! KUBECONFIG="$kubeconfig" oc patch configs.imageregistry.operator.openshift.io cluster \
    --type merge -p '{"spec":{"managementState":"Managed","storage":{"emptyDir":{}}}}'; then
    _lv_warn "[$cluster] Failed to patch Image Registry Operator config."
    return 1
  fi

  while [[ $tries -lt 60 ]]; do
    if KUBECONFIG="$kubeconfig" oc get co image-registry \
         -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null \
         | grep -qx True \
       && KUBECONFIG="$kubeconfig" oc get svc image-registry \
         -n openshift-image-registry >/dev/null 2>&1; then
      _lv_log "[$cluster] Image registry is Available."
      libvirt_ensure_image_registry_dns "$cluster" "$kubeconfig" || true
      return 0
    fi
    sleep 10
    tries=$((tries + 1))
  done
  _lv_warn "[$cluster] Image registry not Available after $((tries * 10))s; ODF label Jobs may ImagePullBackOff."
  return 1
}

libvirt_ensure_image_registry_all() {
  local cluster kc
  for cluster in hub ocp-primary ocp-secondary; do
    case "$cluster" in
      hub) kc="${HUB_INSTALL_DIR}/auth/kubeconfig" ;;
      ocp-primary) kc="${PRIMARY_INSTALL_DIR}/auth/kubeconfig" ;;
      ocp-secondary) kc="${SECONDARY_INSTALL_DIR}/auth/kubeconfig" ;;
    esac
    if [[ ! -f "$kc" ]]; then
      kc="$(libvirt_install_dir_for "$cluster")/auth/kubeconfig"
    fi
    libvirt_ensure_image_registry "$cluster" "$kc" || true
  done
}

libvirt_install_cluster() {
  local cluster="$1"
  _lv_log "=== Installing compact cluster $cluster ==="
  libvirt_create_agent_image "$cluster"
  libvirt_recreate_cluster_vms "$cluster"
  # Re-publish after destroy: a prior --remove-all-storage undefine may have
  # removed the shared ISO from LIBVIRT_IMAGE_DIR.
  libvirt_publish_agent_iso "$cluster"
  libvirt_wait_install "$cluster"
}

libvirt_install_all_clusters() {
  libvirt_ensure_openshift_install
  libvirt_install_cluster hub
  if [[ "${LIBVIRT_INSTALL_PARALLEL_SPOKES}" == "1" ]]; then
    _lv_log "Installing spokes in parallel..."
    libvirt_install_cluster ocp-primary &
    local p1=$!
    libvirt_install_cluster ocp-secondary &
    local p2=$!
    wait "$p1" || return 1
    wait "$p2" || return 1
  else
    libvirt_install_cluster ocp-primary
    libvirt_install_cluster ocp-secondary
  fi
}
