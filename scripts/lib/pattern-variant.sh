#!/usr/bin/env bash
# RamenDR starter-kit v1.3 variant helpers for BYOC redeploy.
#
# Validated Patterns v1.3 selects the install BOM with main.variant in
# values-global.yaml (variants/<name>/) instead of main.clusterGroupName.
# ACM ManagedCluster label clusterGroup=resilient is a different concept
# (spoke placement) and is unchanged.
#
# shellcheck shell=bash

# Official v1.3 pin (PR #29: default main.variant is odf).
: "${V13_UPSTREAM_REPO:=https://github.com/validatedpatterns/ramendr-starter-kit}"
: "${V13_UPSTREAM_REF:=7451daf8cb3926f4ab7e36a29fd3ee0da91444a1}"
: "${V13_UPSTREAM_BRANCH:=v1.3}"

# Known install variants from ramendr-starter-kit pattern-metadata.yaml.
PATTERN_VARIANTS_V13="odf drpartner-s4 drpartner-minimal"

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

pattern_variant_is_v13() {
  [[ -n "${PATTERN_VARIANT:-}" ]]
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

# Child Argo Applications live in this namespace (pattern name + clusterGroup).
# QE fork sets clusterGroup.name=minimal so pattern-install DNS length passes;
# child Applications land in ramendr-starter-kit-minimal.
hub_argocd_namespace() {
  case "${PATTERN_VARIANT:-}" in
    drpartner-minimal) echo "ramendr-starter-kit-minimal" ;;
    "") echo "ramendr-starter-kit-hub" ;;
    *) echo "ramendr-starter-kit-${PATTERN_VARIANT}" ;;
  esac
}

# Parent clustergroup Application name in vp-gitops (same as hub_argocd_namespace).
hub_pattern_app_name() {
  hub_argocd_namespace
}

# Partner / official v1.3 BOMs do not include the QE mixed Windows fleet.
# Only set defaults when the caller has not already exported the variable.
configure_variant_defaults() {
  if ! pattern_variant_is_v13; then
    return 0
  fi

  case "$PATTERN_VARIANT" in
    drpartner-s4|drpartner-minimal)
      : "${REQUIRE_WINDOWS_VMS:=0}"
      : "${SKIP_WINDOWS_VM_STABILIZE:=1}"
      : "${SKIP_DR_VALIDATION:=1}"
      : "${SKIP_ODF_GOLDEN_IMAGE_FIX:=1}"
      : "${SPOKE_RESILIENT_READY_NAMESPACE:=openshift-cnv}"
      ;;
    odf)
      : "${REQUIRE_WINDOWS_VMS:=0}"
      : "${SKIP_WINDOWS_VM_STABILIZE:=1}"
      : "${SKIP_DR_VALIDATION:=1}"
      : "${SPOKE_RESILIENT_READY_NAMESPACE:=openshift-storage}"
      ;;
    *)
      : "${REQUIRE_WINDOWS_VMS:=0}"
      : "${SKIP_WINDOWS_VM_STABILIZE:=1}"
      : "${SKIP_DR_VALIDATION:=1}"
      ;;
  esac
  export REQUIRE_WINDOWS_VMS SKIP_WINDOWS_VM_STABILIZE SKIP_DR_VALIDATION
  export SKIP_ODF_GOLDEN_IMAGE_FIX SPOKE_RESILIENT_READY_NAMESPACE
}

validate_pattern_variant() {
  local dir="${1:-${UPSTREAM_DIR:-}}"
  if ! pattern_variant_is_v13; then
    return 0
  fi
  if [[ -z "$dir" || ! -d "$dir" ]]; then
    _pv_err "UPSTREAM_DIR is not a checkout; cannot validate PATTERN_VARIANT=${PATTERN_VARIANT}."
    return 1
  fi
  if ! pattern_uses_variants_dir "$dir"; then
    _pv_err "PATTERN_VARIANT=${PATTERN_VARIANT} requires starter-kit v1.3 (variants/ directory)."
    _pv_err "Checkout has no variants/. Point UPSTREAM_REPO/UPSTREAM_REF at v1.3 or unset PATTERN_VARIANT."
    return 1
  fi
  if [[ ! -d "$dir/variants/${PATTERN_VARIANT}" ]]; then
    _pv_err "Unknown PATTERN_VARIANT=${PATTERN_VARIANT}."
    _pv_err "Available in this checkout: $(ls -1 "$dir/variants" 2>/dev/null | tr '\n' ' ')"
    _pv_err "Supported: ${PATTERN_VARIANTS_V13}"
    return 1
  fi
  return 0
}

# Rewrite values-global.yaml main.variant and drop legacy main.clusterGroupName.
# Also force byoc: true — this harness always pre-provisions spokes.
apply_pattern_variant() {
  local dir="${1:-${UPSTREAM_DIR:-}}"
  if ! pattern_variant_is_v13; then
    return 0
  fi
  validate_pattern_variant "$dir" || return 1
  _require_variant_gitops_match "$dir" || return 1

  local values_global="${dir}/values-global.yaml"
  [[ -f "$values_global" ]] || {
    _pv_err "Missing ${values_global}"
    return 1
  }

  _pv_log "Selecting pattern variant ${PATTERN_VARIANT} in ${values_global}..."
  local yaml_helper="${REPO_ROOT:-}/scripts/lib/pattern_variant_yaml.py"
  if [[ ! -f "$yaml_helper" ]]; then
    yaml_helper="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/pattern_variant_yaml.py"
  fi
  python3 "$yaml_helper" apply "$values_global" "$PATTERN_VARIANT" || return 1

  local cluster_names="${dir}/overrides/values-cluster-names.yaml"
  if [[ -f "$cluster_names" ]]; then
    python3 "$yaml_helper" byoc "$cluster_names" || return 1
    _pv_log "Ensured byoc: true in overrides/values-cluster-names.yaml (this harness is BYOC)."
  fi
}

# Hub Argo CD syncs values-global.yaml from git, not the local working-tree patch.
# Fail unless the commit Argo will select already has main.variant=PATTERN_VARIANT.
_require_variant_gitops_match() {
  local dir="$1"
  local origin="" branch="" ref="HEAD" git_variant=""
  origin=$(git -C "$dir" remote get-url origin 2>/dev/null || true)
  branch="${UPSTREAM_BRANCH:-${V13_UPSTREAM_BRANCH}}"
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

  _pv_err "Git ${ref} has main.variant='${git_variant:-unset}', but PATTERN_VARIANT=${PATTERN_VARIANT}."
  _pv_err "Hub Argo CD will not use a local-only values-global.yaml patch."
  if [[ "$origin" == *validatedpatterns/ramendr-starter-kit* ]]; then
    _pv_err "Official ${branch:-v1.3} stays at main.variant=${git_variant:-unset}."
  fi
  _pv_err "Fork v1.3, commit main.variant=${PATTERN_VARIANT}, and set UPSTREAM_REPO to that fork."
  return 1
}
