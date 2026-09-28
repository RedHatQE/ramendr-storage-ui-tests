#!/usr/bin/env bash
# shellcheck shell=bash
# SSH helpers so libvirt-provision.sh can run from Tekton and drive ocp-edge111.

# Lab hypervisors often get reinstalled; accept-new still fails when a known_hosts
# entry is stale. Default is non-interactive and skips host-key pinning.
: "${LIBVIRT_SSH_OPTS:=-o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null}"

# shellcheck disable=SC2206
LIBVIRT_SSH_OPT_ARR=(${LIBVIRT_SSH_OPTS})

libvirt_ssh() {
  if [[ -z "${LIBVIRT_HOST:-}" || "${LIBVIRT_REMOTE_SESSION:-}" == "1" ]]; then
    # shellcheck disable=SC2294
    "$@"
    return
  fi
  # shellcheck disable=SC2029
  ssh "${LIBVIRT_SSH_OPT_ARR[@]}" "${LIBVIRT_SSH_USER}@${LIBVIRT_HOST}" "$@"
}

libvirt_scp_to() {
  local src="$1" dest="$2"
  if [[ -z "${LIBVIRT_HOST:-}" || "${LIBVIRT_REMOTE_SESSION:-}" == "1" ]]; then
    mkdir -p "$(dirname "$dest")"
    cp -a "$src" "$dest"
    return
  fi
  ssh -n "${LIBVIRT_SSH_OPT_ARR[@]}" "${LIBVIRT_SSH_USER}@${LIBVIRT_HOST}" \
    "mkdir -p $(printf '%q' "$(dirname "$dest")")" </dev/null
  scp "${LIBVIRT_SSH_OPT_ARR[@]}" "$src" \
    "${LIBVIRT_SSH_USER}@${LIBVIRT_HOST}:${dest}" </dev/null
}

libvirt_scp_from() {
  local src="$1" dest="$2"
  mkdir -p "$(dirname "$dest")"
  if [[ -z "${LIBVIRT_HOST:-}" || "${LIBVIRT_REMOTE_SESSION:-}" == "1" ]]; then
    cp -a "$src" "$dest"
    return
  fi
  scp "${LIBVIRT_SSH_OPT_ARR[@]}" \
    "${LIBVIRT_SSH_USER}@${LIBVIRT_HOST}:${src}" "$dest"
}

# Re-exec this script on the hypervisor with the virt/wait half. Caller keeps
# kubeconfig copies. Secrets are copied to a 0700 remote dir and never logged.
libvirt_reexec_on_host() {
  local remote_root="${LIBVIRT_REMOTE_WORKDIR}/scripts-src"
  local remote_secrets="${LIBVIRT_REMOTE_WORKDIR}/secrets"
  local remote_pull="${remote_secrets}/pull-secret"
  local remote_sshkey="${remote_secrets}/ssh.pub"
  local args=("$@")

  _lv_log "Syncing provision scripts to ${LIBVIRT_SSH_USER}@${LIBVIRT_HOST}:${remote_root}"
  ssh "${LIBVIRT_SSH_OPT_ARR[@]}" "${LIBVIRT_SSH_USER}@${LIBVIRT_HOST}" \
    "mkdir -p $(printf '%q' "$remote_root") $(printf '%q' "$remote_secrets") && chmod 700 $(printf '%q' "$remote_secrets")"

  if command -v rsync >/dev/null; then
    (
      cd "$REPO_ROOT" || return 1
      rsync -az -e "ssh ${LIBVIRT_SSH_OPTS}" \
        --relative \
        scripts/libvirt-provision.sh \
        scripts/lib/gnu-bash-reexec.sh \
        scripts/lib/libvirt-common.sh \
        scripts/lib/libvirt-ssh.sh \
        scripts/lib/libvirt-networks.sh \
        scripts/lib/libvirt-vms.sh \
        scripts/lib/libvirt-agent.sh \
        install-config-examples/libvirt \
        "${LIBVIRT_SSH_USER}@${LIBVIRT_HOST}:${remote_root}/"
    )
  else
    tar -C "$REPO_ROOT" -czf - \
      scripts/libvirt-provision.sh \
      scripts/lib/gnu-bash-reexec.sh \
      scripts/lib/libvirt-common.sh \
      scripts/lib/libvirt-ssh.sh \
      scripts/lib/libvirt-networks.sh \
      scripts/lib/libvirt-vms.sh \
      scripts/lib/libvirt-agent.sh \
      install-config-examples/libvirt | \
      ssh "${LIBVIRT_SSH_OPT_ARR[@]}" "${LIBVIRT_SSH_USER}@${LIBVIRT_HOST}" \
        "tar -C $(printf '%q' "$remote_root") -xzf -"
  fi

  if [[ -n "${PULL_SECRET_FILE:-}" && -f "$PULL_SECRET_FILE" ]]; then
    libvirt_scp_to "$PULL_SECRET_FILE" "$remote_pull"
    ssh "${LIBVIRT_SSH_OPT_ARR[@]}" "${LIBVIRT_SSH_USER}@${LIBVIRT_HOST}" \
      "chmod 600 $(printf '%q' "$remote_pull")"
  fi
  if [[ -n "${SSH_PUBKEY_FILE:-}" && -f "$SSH_PUBKEY_FILE" ]]; then
    libvirt_scp_to "$SSH_PUBKEY_FILE" "$remote_sshkey"
    ssh "${LIBVIRT_SSH_OPT_ARR[@]}" "${LIBVIRT_SSH_USER}@${LIBVIRT_HOST}" \
      "chmod 600 $(printf '%q' "$remote_sshkey")"
  fi

  _lv_log "Running provision on hypervisor (LIBVIRT_REMOTE_SESSION=1)..."
  # Env that must be present on the host; do not pass AWS credentials.
  ssh "${LIBVIRT_SSH_OPT_ARR[@]}" "${LIBVIRT_SSH_USER}@${LIBVIRT_HOST}" \
    env \
    LIBVIRT_REMOTE_SESSION=1 \
    LIBVIRT_HOST= \
    LIBVIRT_UPLINK_IFACE="${LIBVIRT_UPLINK_IFACE:-}" \
    BASE_DOMAIN="$BASE_DOMAIN" \
    HUB_OCP_VERSION="$HUB_OCP_VERSION" \
    PULL_SECRET_FILE="${PULL_SECRET_FILE:+$remote_pull}" \
    SSH_PUBKEY_FILE="${SSH_PUBKEY_FILE:+$remote_sshkey}" \
    LIBVIRT_IMAGE_DIR="$LIBVIRT_IMAGE_DIR" \
    LIBVIRT_REMOTE_WORKDIR="$LIBVIRT_REMOTE_WORKDIR" \
    LIBVIRT_VCPUS="$LIBVIRT_VCPUS" \
    LIBVIRT_MEMORY_MIB="$LIBVIRT_MEMORY_MIB" \
    LIBVIRT_HUB_VCPUS="$LIBVIRT_HUB_VCPUS" \
    LIBVIRT_HUB_MEMORY_MIB="$LIBVIRT_HUB_MEMORY_MIB" \
    LIBVIRT_SPOKE_VCPUS="$LIBVIRT_SPOKE_VCPUS" \
    LIBVIRT_SPOKE_MEMORY_MIB="$LIBVIRT_SPOKE_MEMORY_MIB" \
    LIBVIRT_OS_DISK_GIB="$LIBVIRT_OS_DISK_GIB" \
    LIBVIRT_HUB_OSD_GIB="$LIBVIRT_HUB_OSD_GIB" \
    LIBVIRT_SPOKE_OSD_GIB="$LIBVIRT_SPOKE_OSD_GIB" \
    LIBVIRT_OS_VARIANT="$LIBVIRT_OS_VARIANT" \
    LIBVIRT_INSTALL_PARALLEL_SPOKES="$LIBVIRT_INSTALL_PARALLEL_SPOKES" \
    HUB_INSTALL_DIR="${LIBVIRT_REMOTE_WORKDIR}/hub-cluster-install" \
    PRIMARY_INSTALL_DIR="${LIBVIRT_REMOTE_WORKDIR}/ocp-primary-install" \
    SECONDARY_INSTALL_DIR="${LIBVIRT_REMOTE_WORKDIR}/ocp-secondary-install" \
    bash "$(printf '%q' "$remote_root/scripts/libvirt-provision.sh")" "${args[@]}"

  local cluster dest src
  for cluster in "${LIBVIRT_CLUSTERS[@]}"; do
    dest="$(libvirt_install_dir_for "$cluster")/auth/kubeconfig"
    src="${LIBVIRT_REMOTE_WORKDIR}/${cluster}-cluster-install/auth/kubeconfig"
    case "$cluster" in
      hub) src="${LIBVIRT_REMOTE_WORKDIR}/hub-cluster-install/auth/kubeconfig" ;;
      ocp-primary) src="${LIBVIRT_REMOTE_WORKDIR}/ocp-primary-install/auth/kubeconfig" ;;
      ocp-secondary) src="${LIBVIRT_REMOTE_WORKDIR}/ocp-secondary-install/auth/kubeconfig" ;;
    esac
    if ssh "${LIBVIRT_SSH_OPT_ARR[@]}" "${LIBVIRT_SSH_USER}@${LIBVIRT_HOST}" \
      "test -f $(printf '%q' "$src")"; then
      _lv_log "Copying $cluster kubeconfig to $dest"
      libvirt_scp_from "$src" "$dest"
      chmod 600 "$dest"
    else
      _lv_warn "No kubeconfig on hypervisor for $cluster ($src)"
    fi
  done
}

# Write a VALUES_SECRET copy with the AWS secret block removed (libvirt does not
# need ~/.aws/credentials). Never prints secret contents. Source is unchanged.
libvirt_write_values_secret_without_aws() {
  local src="$1" dest="$2"
  python3 - "$src" "$dest" <<'PY'
import sys
from pathlib import Path

try:
    import yaml
except ImportError as exc:
    raise SystemExit("PyYAML is required to filter VALUES_SECRET for libvirt") from exc

src, dest = Path(sys.argv[1]), Path(sys.argv[2])
data = yaml.safe_load(src.read_text(encoding="utf-8")) or {}
secrets = data.get("secrets")
if isinstance(secrets, list):
    data["secrets"] = [
        entry for entry in secrets
        if not (isinstance(entry, dict) and entry.get("name") == "aws")
    ]
if "version" not in data:
    data["version"] = "2.0"
dest.parent.mkdir(parents=True, exist_ok=True)
dest.write_text(
    yaml.safe_dump(data, default_flow_style=False, sort_keys=False),
    encoding="utf-8",
)
dest.chmod(0o600)
PY
}

# Copy files referenced by path=/ini_file= in VALUES_SECRET onto the remote
# HOME tree (pattern parse_secrets reads every secret entry). Never logs file
# contents. Only stages paths that resolve under the caller's $HOME.
libvirt_stage_values_secret_home_files() {
  local local_values="$1"
  local remote_home="$2"
  local local_home="${HOME}"
  local local_path remote_path

  [[ -f "$local_values" ]] || return 1
  [[ -n "$remote_home" ]] || return 1

  while IFS=$'\t' read -r local_path remote_path; do
    [[ -n "$local_path" && -n "$remote_path" ]] || continue
    if [[ ! -f "$local_path" ]]; then
      _lv_err "VALUES_SECRET references missing local file: $local_path"
      return 1
    fi
    _lv_log "Staging secret path file onto hypervisor HOME: ${remote_path#"$remote_home"/}"
    # ssh must not consume this loop's stdin (would skip remaining path files).
    ssh -n "${LIBVIRT_SSH_OPT_ARR[@]}" "${LIBVIRT_SSH_USER}@${LIBVIRT_HOST}" \
      "mkdir -p $(printf '%q' "$(dirname "$remote_path")")" </dev/null
    libvirt_scp_to "$local_path" "$remote_path"
    ssh -n "${LIBVIRT_SSH_OPT_ARR[@]}" "${LIBVIRT_SSH_USER}@${LIBVIRT_HOST}" \
      "chmod 600 $(printf '%q' "$remote_path")" </dev/null
  done < <(python3 - "$local_values" "$local_home" "$remote_home" <<'PY'
import sys
from pathlib import Path

try:
    import yaml
except ImportError as exc:
    raise SystemExit("PyYAML is required to stage VALUES_SECRET path files") from exc

values_path, local_home, remote_home = sys.argv[1:4]
local_home_p = Path(local_home).resolve()
remote_home_p = Path(remote_home)
data = yaml.safe_load(Path(values_path).read_text(encoding="utf-8")) or {}
seen = set()

def emit(raw: str) -> None:
    if not raw or raw in seen:
        return
    expanded = Path(raw).expanduser()
    try:
        expanded = expanded.resolve()
    except FileNotFoundError:
        expanded = Path(raw).expanduser().absolute()
    try:
        rel = expanded.relative_to(local_home_p)
    except ValueError:
        # Absolute paths outside caller HOME (e.g. already-staged kubeconfigs)
        # are handled elsewhere; skip here.
        return
    remote = remote_home_p / rel
    seen.add(raw)
    print(f"{expanded}\t{remote}")

for secret in data.get("secrets") or []:
    if not isinstance(secret, dict):
        continue
    for field in secret.get("fields") or []:
        if not isinstance(field, dict):
            continue
        for key in ("path", "ini_file"):
            if key in field and isinstance(field[key], str):
                emit(field[key])
PY
)
}

# Sync redeploy scripts + VALUES_SECRET to the hypervisor and re-exec so oc can
# reach libvirt cluster APIs (guest DNS / private NAT only exist on the HV).
# Used for REDEPLOY_PLATFORM=libvirt --pattern-only from Tekton or a laptop.
#
# pattern.sh bind-mounts $HOME into the utility container, so KUBECONFIG and
# VALUES_SECRET must live under the remote user's HOME (not /var/lib/...).
# Provision still keeps authoritative install dirs in LIBVIRT_REMOTE_WORKDIR;
# we stage copies under $HOME/ramendr-libvirt for install-byoc.
libvirt_reexec_redeploy_on_host() {
  local remote_root="${LIBVIRT_REMOTE_WORKDIR}/scripts-src"
  local provision_hub="${LIBVIRT_REMOTE_WORKDIR}/hub-cluster-install"
  local provision_primary="${LIBVIRT_REMOTE_WORKDIR}/ocp-primary-install"
  local provision_secondary="${LIBVIRT_REMOTE_WORKDIR}/ocp-secondary-install"
  local args=("$@")
  local local_values="${VALUES_SECRET:-$HOME/values-secret.yaml}"
  local remote_home stage_root remote_secrets remote_values remote_work
  local remote_hub remote_primary remote_secondary
  local cluster src provision_kc dest
  local filtered_values=""

  [[ -n "${REPO_ROOT:-}" ]] || { _lv_err "REPO_ROOT is not set"; return 1; }
  [[ -f "$local_values" ]] || {
    _lv_err "VALUES_SECRET not found: $local_values"
    return 1
  }

  remote_home="$(ssh "${LIBVIRT_SSH_OPT_ARR[@]}" "${LIBVIRT_SSH_USER}@${LIBVIRT_HOST}" \
    'printf %s "$HOME"')"
  [[ -n "$remote_home" ]] || {
    _lv_err "Could not determine HOME on ${LIBVIRT_HOST}"
    return 1
  }
  stage_root="${remote_home}/ramendr-libvirt"
  remote_secrets="${stage_root}/secrets"
  # Libvirt-specific secret file: no aws: block (no ~/.aws/credentials needed).
  remote_values="${remote_secrets}/values-secret-libvirt.yaml"
  remote_work="${stage_root}/redeploy-work"
  remote_hub="${stage_root}/hub-cluster-install"
  remote_primary="${stage_root}/ocp-primary-install"
  remote_secondary="${stage_root}/ocp-secondary-install"

  filtered_values="$(mktemp -p "${TMPDIR:-/tmp}" ramendr-values-libvirt.XXXXXX)"
  # shellcheck disable=SC2064
  trap 'rm -f "${filtered_values}"' RETURN
  libvirt_write_values_secret_without_aws "$local_values" "$filtered_values" || return 1

  _lv_log "Syncing redeploy scripts to ${LIBVIRT_SSH_USER}@${LIBVIRT_HOST}:${remote_root}"
  ssh "${LIBVIRT_SSH_OPT_ARR[@]}" "${LIBVIRT_SSH_USER}@${LIBVIRT_HOST}" \
    "mkdir -p $(printf '%q' "$remote_root") \
      $(printf '%q' "$remote_secrets") \
      $(printf '%q' "$remote_work") \
      $(printf '%q' "$remote_hub/auth") \
      $(printf '%q' "$remote_primary/auth") \
      $(printf '%q' "$remote_secondary/auth") && \
     chmod 700 $(printf '%q' "$remote_secrets")"

  if command -v rsync >/dev/null; then
    (
      cd "$REPO_ROOT" || return 1
      rsync -az -e "ssh ${LIBVIRT_SSH_OPTS}" \
        --relative \
        scripts \
        overrides/libvirt \
        "${LIBVIRT_SSH_USER}@${LIBVIRT_HOST}:${remote_root}/"
    )
  else
    tar -C "$REPO_ROOT" -czf - scripts overrides/libvirt | \
      ssh "${LIBVIRT_SSH_OPT_ARR[@]}" "${LIBVIRT_SSH_USER}@${LIBVIRT_HOST}" \
        "tar -C $(printf '%q' "$remote_root") -xzf -"
  fi

  _lv_log "Copying libvirt VALUES_SECRET (aws block removed) to ${remote_values} (contents not logged)..."
  libvirt_scp_to "$filtered_values" "$remote_values"
  ssh "${LIBVIRT_SSH_OPT_ARR[@]}" "${LIBVIRT_SSH_USER}@${LIBVIRT_HOST}" \
    "chmod 600 $(printf '%q' "$remote_values")"

  # parse_secrets loads every path=/ini_file= entry; stage those under remote HOME.
  libvirt_stage_values_secret_home_files "$filtered_values" "$remote_home" || return 1

  # Stage kubeconfigs under HOME: prefer provision dirs on the HV, else upload.
  for cluster in hub ocp-primary ocp-secondary; do
    case "$cluster" in
      hub)
        src="${HUB_INSTALL_DIR}/auth/kubeconfig"
        provision_kc="${provision_hub}/auth/kubeconfig"
        dest="${remote_hub}/auth/kubeconfig"
        ;;
      ocp-primary)
        src="${PRIMARY_INSTALL_DIR}/auth/kubeconfig"
        provision_kc="${provision_primary}/auth/kubeconfig"
        dest="${remote_primary}/auth/kubeconfig"
        ;;
      ocp-secondary)
        src="${SECONDARY_INSTALL_DIR}/auth/kubeconfig"
        provision_kc="${provision_secondary}/auth/kubeconfig"
        dest="${remote_secondary}/auth/kubeconfig"
        ;;
    esac
    if ssh "${LIBVIRT_SSH_OPT_ARR[@]}" "${LIBVIRT_SSH_USER}@${LIBVIRT_HOST}" \
      "test -f $(printf '%q' "$provision_kc")"; then
      _lv_log "Staging $cluster kubeconfig into ${stage_root} (from provision workdir)..."
      ssh "${LIBVIRT_SSH_OPT_ARR[@]}" "${LIBVIRT_SSH_USER}@${LIBVIRT_HOST}" \
        "install -m 600 $(printf '%q' "$provision_kc") $(printf '%q' "$dest")"
    elif [[ -f "$src" ]]; then
      _lv_log "Uploading $cluster kubeconfig into remote HOME stage..."
      libvirt_scp_to "$src" "$dest"
      ssh "${LIBVIRT_SSH_OPT_ARR[@]}" "${LIBVIRT_SSH_USER}@${LIBVIRT_HOST}" \
        "chmod 600 $(printf '%q' "$dest")"
    else
      _lv_err "Missing kubeconfig for $cluster (not on HV at $provision_kc, not local at $src)"
      return 1
    fi
  done

  _lv_log "Running redeploy on hypervisor (LIBVIRT_REMOTE_SESSION=1, HOME-staged kubeconfigs)..."
  # Do not forward AWS credentials; HV uses local libvirt DNS for cluster APIs.
  # Prepend provision's tools dir so `oc` is found in non-login SSH sessions.
  local remote_path="${LIBVIRT_REMOTE_WORKDIR}/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
  ssh "${LIBVIRT_SSH_OPT_ARR[@]}" "${LIBVIRT_SSH_USER}@${LIBVIRT_HOST}" \
    env \
    PATH="$remote_path" \
    HOME="$remote_home" \
    LIBVIRT_REMOTE_SESSION=1 \
    LIBVIRT_HOST= \
    REDEPLOY_PLATFORM=libvirt \
    LIBVIRT_REMOTE_WORKDIR="$LIBVIRT_REMOTE_WORKDIR" \
    LIBVIRT_INSTALL_ROOT="$stage_root" \
    WORK_DIR="$remote_work" \
    VALUES_SECRET="$remote_values" \
    HUB_INSTALL_DIR="$remote_hub" \
    PRIMARY_INSTALL_DIR="$remote_primary" \
    SECONDARY_INSTALL_DIR="$remote_secondary" \
    BASE_DOMAIN="${BASE_DOMAIN:-}" \
    PATTERN_VARIANT="${PATTERN_VARIANT:-}" \
    UPSTREAM_REPO="${UPSTREAM_REPO:-}" \
    UPSTREAM_REF="${UPSTREAM_REF:-}" \
    UPSTREAM_BRANCH="${UPSTREAM_BRANCH:-}" \
    UPSTREAM_DIR="${remote_work}/upstream/ramendr-starter-kit" \
    REQUIRE_WINDOWS_VMS="${REQUIRE_WINDOWS_VMS:-0}" \
    SKIP_WINDOWS_VM_STABILIZE="${SKIP_WINDOWS_VM_STABILIZE:-1}" \
    SKIP_DR_VALIDATION="${SKIP_DR_VALIDATION:-}" \
    DR_VALIDATION_MODE="${DR_VALIDATION_MODE:-}" \
    ODF_MIN_LABELED_NODES="${ODF_MIN_LABELED_NODES:-}" \
    bash "$(printf '%q' "$remote_root/scripts/redeploy.sh")" "${args[@]}"
}
