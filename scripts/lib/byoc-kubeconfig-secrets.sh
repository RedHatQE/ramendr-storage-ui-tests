#!/usr/bin/env bash
# Prepare values-secret.yaml for BYOC pattern install (kubeconfig paths for spokes).
#
# Copies the user's VALUES_SECRET into .work/values-secret.yaml and merges spoke
# kubeconfig file paths (replace stale entries or add missing ones). The user's
# source file is never modified.

set -euo pipefail

: "${PRIMARY_INSTALL_DIR:=${HOME}/git/ocp-primary-install}"
: "${SECONDARY_INSTALL_DIR:=${HOME}/git/ocp-secondary-install}"

BYOC_VALUES_SECRET="${BYOC_VALUES_SECRET:-}"

_byoc_ks_log() {
  if [[ $(type -t log) == function ]]; then
    log "$@"
  else
    echo "[byoc-secrets] $*"
  fi
}

_byoc_ks_err() {
  if [[ $(type -t err) == function ]]; then
    err "$@"
  else
    echo "[byoc-secrets] ERROR: $*" >&2
  fi
}

prepare_byoc_values_secret() {
  local source_secret="${1:-${VALUES_SECRET:-${HOME}/values-secret.yaml}}"
  local work_dir="${WORK_DIR:?WORK_DIR must be set}"
  local dest_secret="${BYOC_VALUES_SECRET:-${work_dir}/values-secret.yaml}"
  local primary_kc="${PRIMARY_INSTALL_DIR}/auth/kubeconfig"
  local secondary_kc="${SECONDARY_INSTALL_DIR}/auth/kubeconfig"

  [[ -f "$source_secret" ]] || {
    _byoc_ks_err "VALUES_SECRET not found: $source_secret"
    return 1
  }
  [[ -f "$primary_kc" ]] || {
    _byoc_ks_err "Primary spoke kubeconfig not found: $primary_kc"
    return 1
  }
  [[ -f "$secondary_kc" ]] || {
    _byoc_ks_err "Secondary spoke kubeconfig not found: $secondary_kc"
    return 1
  }

  mkdir -p "$(dirname "$dest_secret")"
  install -m 600 "$source_secret" "$dest_secret" || {
    _byoc_ks_err "Failed to copy values-secret to $dest_secret"
    return 1
  }

  _byoc_ks_log "Merging spoke kubeconfig paths into $dest_secret (source: $source_secret)..."

  python3 - "$dest_secret" "$primary_kc" "$secondary_kc" <<'PY'
import sys

try:
    import yaml
except ImportError as exc:
    raise SystemExit(
        "PyYAML is required to merge kubeconfig entries into values-secret.yaml. "
        "Install with: python3 -m pip install pyyaml"
    ) from exc

out_path, primary_kc, secondary_kc = sys.argv[1:4]
kubeconfig_secrets = {
    "ocp-primary_cluster_kubeconfig": primary_kc,
    "ocp-secondary_cluster_kubeconfig": secondary_kc,
}

with open(out_path, encoding="utf-8") as fh:
    data = yaml.safe_load(fh) or {}

secrets = data.get("secrets")
if not isinstance(secrets, list):
    secrets = []

secrets = [
    entry for entry in secrets
    if not (isinstance(entry, dict) and entry.get("name") in kubeconfig_secrets)
]

for name, kc_path in kubeconfig_secrets.items():
    secrets.append({
        "name": name,
        "fields": [{"name": "kubeconfig", "path": kc_path}],
    })

data["secrets"] = secrets
if "version" not in data:
    data["version"] = "2.0"

with open(out_path, "w", encoding="utf-8") as fh:
    yaml.safe_dump(data, fh, default_flow_style=False, sort_keys=False)
PY

  BYOC_VALUES_SECRET="$dest_secret"
  export BYOC_VALUES_SECRET
  _byoc_ks_log "BYOC values-secret ready at $BYOC_VALUES_SECRET"
}
