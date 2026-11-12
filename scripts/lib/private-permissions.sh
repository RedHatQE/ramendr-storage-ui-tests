#!/usr/bin/env bash
# Shared credential-permission helpers for local runs and multi-TaskRun CI.

if [[ -n "${_RAMENDR_PRIVATE_PERMISSIONS_SH:-}" ]]; then
  return 0
fi
_RAMENDR_PRIVATE_PERMISSIONS_SH=1

_private_permissions_err() {
  if [[ $(type -t err) == function ]]; then
    err "$@"
  else
    echo "[private-permissions] ERROR: $*" >&2
  fi
}

_private_permissions_gid() {
  local path="$1"

  if stat -c '%g' "$path" >/dev/null 2>&1; then
    stat -c '%g' "$path"
  else
    stat -f '%g' "$path"
  fi
}

set_private_permissions() {
  local path="$1"
  local kind="${2:-file}"
  local shared_gid="${CI_SHARED_WORKSPACE_GID:-}"
  local private_mode shared_mode actual_gid

  if [[ "$kind" == "directory" ]]; then
    private_mode=700
    shared_mode=750
  elif [[ "$kind" == "file" ]]; then
    private_mode=600
    shared_mode=640
  else
    _private_permissions_err "Permission kind must be 'file' or 'directory': $kind"
    return 1
  fi

  if [[ -z "$shared_gid" ]]; then
    chmod "$private_mode" "$path"
    return
  fi

  if [[ ! "$shared_gid" =~ ^[0-9]+$ ]]; then
    _private_permissions_err "CI_SHARED_WORKSPACE_GID must be a numeric group ID"
    return 1
  fi

  # Some restricted NFS servers reject even a redundant chgrp. Accept that
  # case only when the server already reports the requested group; never fall
  # back to granting access to others.
  if ! chgrp "$shared_gid" "$path" 2>/dev/null; then
    actual_gid="$(_private_permissions_gid "$path")" || {
      _private_permissions_err "Failed to read the group ID for $path"
      return 1
    }
    if [[ "$actual_gid" != "$shared_gid" ]]; then
      _private_permissions_err \
        "Failed to assign shared group $shared_gid to $path (current group: $actual_gid)"
      return 1
    fi
  fi

  chmod "$shared_mode" "$path"
}

set_cluster_credentials_permissions() {
  local install_dir="$1"
  local auth_dir="${install_dir}/auth"
  local credential

  [[ -d "$install_dir" ]] || return 0
  set_private_permissions "$install_dir" directory || return 1
  [[ -d "$auth_dir" ]] || return 0
  set_private_permissions "$auth_dir" directory || return 1

  for credential in "$auth_dir/kubeconfig" "$auth_dir/kubeadmin-password"; do
    if [[ -f "$credential" ]]; then
      set_private_permissions "$credential" || return 1
    fi
  done
}
