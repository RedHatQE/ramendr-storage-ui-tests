#!/usr/bin/env bash
# Shared DRPlacementControl safety checks (hub KUBECONFIG must be set).

: "${DRPC_NAMESPACE:=openshift-dr-ops}"
: "${DRPC_NAME:=gitops-vm-protection}"
: "${PLACEMENT_NAME:=gitops-vm-protection-placement-1}"

_drpc_guard_err() { echo -e "\033[0;31m[drpc-guard] ERROR:\033[0m $*" >&2; }
_drpc_guard_warn() { echo -e "\033[1;33m[drpc-guard] WARNING:\033[0m $*" >&2; }
_drpc_guard_ok() { echo -e "\033[0;32m[drpc-guard]\033[0m $*"; }

_normalize_progression() {
  echo "$1" | tr '[:upper:]' '[:lower:]' | tr -d ' '
}

# Returns 0 if safe, 1 if blocked, 2 if unknown (use --force to override).
drpc_progression_safety() {
  local progression_raw progression
  progression_raw=$(oc get drplacementcontrol "$DRPC_NAME" -n "$DRPC_NAMESPACE" \
    -o jsonpath='{.status.progression}' 2>/dev/null || true)
  progression=$(_normalize_progression "$progression_raw")

  if [[ -z "$progression" ]]; then
    _drpc_guard_warn "DRPC progression is empty (DR may still be running)."
    return 2
  fi

  case "$progression" in
    completed|deployed|failedover|relocated|cleaningup|waitforusertocleanup|waitonusertocleanup|waitforuser)
      _drpc_guard_ok "DRPC progression '${progression_raw}' is safe for non-primary cleanup."
      return 0
      ;;
    *failingover*|*relocating*|*restoring*|*creating*|*progressing*|*syncing*|*initializing*)
      _drpc_guard_err "DRPC progression '${progression_raw}' — DR still in progress; cleanup blocked."
      return 1
      ;;
    *)
      _drpc_guard_warn "DRPC progression '${progression_raw}' is not in the known-safe list."
      return 2
      ;;
  esac
}

assert_drpc_exists() {
  oc get drplacementcontrol "$DRPC_NAME" -n "$DRPC_NAMESPACE" &>/dev/null || {
    _drpc_guard_err "DRPC ${DRPC_NAME} not found in ${DRPC_NAMESPACE}."
    return 1
  }
}

assert_placement_decision_primary() {
  local cluster
  cluster=$(oc get placementdecision -n "$DRPC_NAMESPACE" \
    -l cluster.open-cluster-management.io/placement="$PLACEMENT_NAME" \
    -o jsonpath='{.items[0].status.decisions[0].clusterName}' 2>/dev/null || true)
  if [[ -z "$cluster" ]]; then
    _drpc_guard_err "PlacementDecision for ${PLACEMENT_NAME} not ready — primary cluster is ambiguous."
    return 1
  fi
  _drpc_guard_ok "PlacementDecision primary: ${cluster}"
  return 0
}

assert_safe_to_cleanup_non_primary() {
  local force="${1:-0}"
  assert_drpc_exists || return 1

  local safety=0
  drpc_progression_safety || safety=$?

  if [[ "$safety" -eq 1 ]]; then
    return 1
  fi
  if [[ "$safety" -eq 2 ]] && [[ "$force" != "1" ]]; then
    _drpc_guard_err "Refusing cleanup. Re-run with --force if you accept the risk."
    return 1
  fi

  if ! assert_placement_decision_primary; then
    [[ "$force" == "1" ]] && {
      _drpc_guard_warn "--force: continuing without PlacementDecision (risky)."
      return 0
    }
    return 1
  fi
  return 0
}
