#!/usr/bin/env bash
# RamenDR starter-kit install variant helpers for BYOC redeploy.
#
# PATTERN_VARIANT selects the install BOM via main.variant in values-global.yaml.
# All variants use the QE fork (RHDR catalog); partner BOMs differ only in variants/<name>/.
#
# shellcheck shell=bash

DEFAULT_PATTERN_VARIANT=odf
PATTERN_VARIANTS="odf drpartner-s4 drpartner-minimal"

: "${UPSTREAM_REPO:=https://github.com/elsapassaro/ramendr-starter-kit}"
: "${UPSTREAM_REF:=11327fb0f7e44ae34c4b8e6af7de167756684e1d}"
: "${UPSTREAM_BRANCH:=ocp-4.22-rhdr-ramen}"

_pv_log() {
  if [[ $(type -t log) == function ]]; then
    log "$@"
  else
    echo "[pattern-variant] $*"
  fi
}

_pv_warn() {
  if [[ $(type -t warn) == function ]]; then
    warn "$@"
  else
    echo "[pattern-variant] WARNING: $*" >&2
  fi
}

_pv_err() {
  if [[ $(type -t err) == function ]]; then
    err "$@"
  else
    echo "[pattern-variant] ERROR: $*" >&2
  fi
}

resolve_pattern_variant() {
  PATTERN_VARIANT="${PATTERN_VARIANT:-$DEFAULT_PATTERN_VARIANT}"
  case "$PATTERN_VARIANT" in
    odf|drpartner-s4|drpartner-minimal) ;;
    *)
      _pv_err "Unknown PATTERN_VARIANT=${PATTERN_VARIANT}."
      _pv_err "Supported: ${PATTERN_VARIANTS}"
      return 1
      ;;
  esac
  export PATTERN_VARIANT UPSTREAM_REPO UPSTREAM_REF UPSTREAM_BRANCH
}

pattern_variant_is_partner() {
  case "${PATTERN_VARIANT:-}" in
    drpartner-s4|drpartner-minimal) return 0 ;;
    *) return 1 ;;
  esac
}

pattern_uses_variants_dir() {
  local dir="${1:-${UPSTREAM_DIR:-}}"
  [[ -n "$dir" && -d "$dir/variants" ]]
}

hub_argocd_namespace() {
  case "${PATTERN_VARIANT:-}" in
    drpartner-minimal) echo "ramendr-starter-kit-minimal" ;;
    *) echo "ramendr-starter-kit-${PATTERN_VARIANT:-$DEFAULT_PATTERN_VARIANT}" ;;
  esac
}

hub_pattern_app_name() {
  hub_argocd_namespace
}

configure_variant_defaults() {
  case "$PATTERN_VARIANT" in
    odf)
      : "${SPOKE_RESILIENT_READY_NAMESPACE:=openshift-storage}"
      ;;
    drpartner-s4|drpartner-minimal)
      : "${REQUIRE_WINDOWS_VMS:=0}"
      : "${SKIP_WINDOWS_VM_STABILIZE:=1}"
      : "${SKIP_DR_VALIDATION:=1}"
      : "${SKIP_ODF_GOLDEN_IMAGE_FIX:=1}"
      : "${SPOKE_RESILIENT_READY_NAMESPACE:=openshift-cnv}"
      ;;
    *)
      _pv_err "Unknown PATTERN_VARIANT=${PATTERN_VARIANT}."
      _pv_err "Supported: ${PATTERN_VARIANTS}"
      return 1
      ;;
  esac
  export REQUIRE_WINDOWS_VMS SKIP_WINDOWS_VM_STABILIZE SKIP_DR_VALIDATION
  export SKIP_ODF_GOLDEN_IMAGE_FIX SPOKE_RESILIENT_READY_NAMESPACE
}

validate_pattern_variant() {
  local dir="${1:-${UPSTREAM_DIR:-}}"
  if [[ -z "$dir" || ! -d "$dir" ]]; then
    _pv_err "UPSTREAM_DIR is not a checkout; cannot validate PATTERN_VARIANT=${PATTERN_VARIANT}."
    return 1
  fi
  if ! pattern_uses_variants_dir "$dir"; then
    _pv_err "PATTERN_VARIANT=${PATTERN_VARIANT} requires starter-kit variants/ (v1.3 layout)."
    return 1
  fi
  if [[ ! -d "$dir/variants/${PATTERN_VARIANT}" ]]; then
    _pv_err "Unknown PATTERN_VARIANT=${PATTERN_VARIANT}."
    _pv_err "Available in this checkout: $(ls -1 "$dir/variants" 2>/dev/null | tr '\n' ' ')"
    _pv_err "Supported: ${PATTERN_VARIANTS}"
    return 1
  fi
  return 0
}

_pattern_variant_yaml_helper() {
  local yaml_helper="${REPO_ROOT:-}/scripts/lib/pattern_variant_yaml.py"
  if [[ ! -f "$yaml_helper" ]]; then
    yaml_helper="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/pattern_variant_yaml.py"
  fi
  printf '%s\n' "$yaml_helper"
}

apply_pattern_variant() {
  local dir="${1:-${UPSTREAM_DIR:-}}"
  validate_pattern_variant "$dir" || return 1
  _require_variant_gitops_match "$dir" || return 1

  local values_global="${dir}/values-global.yaml"
  [[ -f "$values_global" ]] || {
    _pv_err "Missing ${values_global}"
    return 1
  }

  local yaml_helper
  yaml_helper="$(_pattern_variant_yaml_helper)"

  _pv_log "Selecting pattern variant ${PATTERN_VARIANT} in ${values_global}..."
  python3 "$yaml_helper" apply "$values_global" "$PATTERN_VARIANT" || return 1

  if python3 "$yaml_helper" rhdr "$dir" "$PATTERN_VARIANT"; then
    :
  else
    return 1
  fi
  _pv_log "Ensured RHDR catalog (ramen-catalog / rhdr-multicluster-operator) in variant ${PATTERN_VARIANT} values."

  local cluster_names="${dir}/overrides/values-cluster-names.yaml"
  if [[ -f "$cluster_names" ]]; then
    python3 "$yaml_helper" byoc "$cluster_names" || return 1
    _pv_log "Ensured byoc: true in overrides/values-cluster-names.yaml (this harness is BYOC)."
  fi
}

# Hub Argo CD syncs values-global.yaml from git, not the local working-tree patch.
_require_variant_gitops_match() {
  local dir="$1"
  local branch="" ref="HEAD" git_variant=""
  branch="${UPSTREAM_BRANCH:-$UPSTREAM_BRANCH}"
  if [[ -n "$branch" ]] && git -C "$dir" rev-parse --verify --quiet "origin/${branch}^{commit}" >/dev/null; then
    ref="origin/${branch}"
  fi
  git_variant=$(git -C "$dir" show "${ref}:values-global.yaml" 2>/dev/null \
    | python3 -c "import sys,yaml; d=yaml.safe_load(sys.stdin) or {}; print((d.get('main') or {}).get('variant') or '')" \
    2>/dev/null || true)

  if [[ "$git_variant" == "$PATTERN_VARIANT" ]]; then
    _pv_log "${ref} values-global.yaml already has main.variant=${PATTERN_VARIANT}."
    return 0
  fi

  if [[ "$PATTERN_VARIANT" != "odf" ]]; then
    _pv_warn "Git ${ref} has main.variant='${git_variant:-unset}', local patch sets ${PATTERN_VARIANT}."
    _pv_warn "Hub Argo CD will keep syncing main.variant=${git_variant:-unset} until the fork commits ${PATTERN_VARIANT}."
    return 0
  fi

  _pv_err "Git ${ref} has main.variant='${git_variant:-unset}', but PATTERN_VARIANT=${PATTERN_VARIANT}."
  _pv_err "Hub Argo CD will not use a local-only values-global.yaml patch."
  _pv_err "Point UPSTREAM_* at a fork commit whose values-global.yaml has main.variant=${PATTERN_VARIANT}."
  return 1
}
