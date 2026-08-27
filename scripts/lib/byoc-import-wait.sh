#!/usr/bin/env bash
# BYOC spoke import + pattern install-byoc health-loop helpers.
#
# Fresh redeploy: bootstrap spoke hub namespaces/secrets early, optionally cut
# install-byoc's 60×60s wait short, then wait for ACM join.

set -euo pipefail

: "${BYOC_IMPORT_WAIT_ATTEMPTS:=40}"
: "${BYOC_IMPORT_WAIT_SLEEP:=30}"
: "${SPOKE_CLUSTERS:=ocp-primary ocp-secondary}"
: "${PRIMARY_INSTALL_DIR:=${HOME}/git/ocp-primary-install}"
: "${SECONDARY_INSTALL_DIR:=${HOME}/git/ocp-secondary-install}"
: "${BYOC_BOOTSTRAP_SPOKE_IMPORT:=1}"
: "${PATTERN_INSTALL_EARLY_EXIT_CHECKS:=3}"
: "${PATTERN_INSTALL_EARLY_EXIT_SLEEP:=30}"

_byoc_log() {
  if [[ $(type -t log) == function ]]; then
    log "$@"
  else
    echo "[byoc] $*"
  fi
}

_byoc_warn() {
  if [[ $(type -t warn) == function ]]; then
    warn "$@"
  else
    echo "[byoc] WARNING: $*" >&2
  fi
}

_spoke_kubeconfig_path() {
  case "$1" in
    ocp-primary) echo "${PRIMARY_INSTALL_DIR}/auth/kubeconfig" ;;
    ocp-secondary) echo "${SECONDARY_INSTALL_DIR}/auth/kubeconfig" ;;
    *) return 1 ;;
  esac
}

_secret_has_kubeconfig_data() {
  local namespace="$1" secret="$2"
  [[ -n "$(oc get secret "$secret" -n "$namespace" \
    -o jsonpath='{.data.kubeconfig}' 2>/dev/null || true)" ]]
}

_byoc_bootstrap_secrets_ready() {
  local cluster
  for cluster in $SPOKE_CLUSTERS; do
    _secret_has_kubeconfig_data "$cluster" auto-import-secret || return 1
  done
}

_ensure_spoke_import_secrets() {
  local cluster="$1" kc_file="$2" secret
  oc get namespace "$cluster" &>/dev/null \
    || oc create namespace "$cluster" &>/dev/null \
    || return 1
  for secret in auto-import-secret admin-kubeconfig; do
    oc create secret generic "$secret" \
      -n "$cluster" \
      --from-file=kubeconfig="$kc_file" \
      --dry-run=client -o yaml \
      | oc apply -f - &>/dev/null || return 1
  done
  _byoc_log "[$cluster] hub namespace + import secrets ready."
}

bootstrap_byoc_spoke_import() {
  local cluster kc_file failed=0
  [[ "${BYOC_BOOTSTRAP_SPOKE_IMPORT}" == "1" ]] || return 0
  _byoc_log "Bootstrapping BYOC spoke hub namespaces and import secrets..."
  for cluster in $SPOKE_CLUSTERS; do
    kc_file="$(_spoke_kubeconfig_path "$cluster" 2>/dev/null || true)"
    if [[ -z "$kc_file" || ! -f "$kc_file" ]]; then
      _byoc_warn "[$cluster] install kubeconfig missing."
      failed=1
      continue
    fi
    _ensure_spoke_import_secrets "$cluster" "$kc_file" || failed=1
  done
  return "$failed"
}

wait_for_spoke_namespace() {
  local cluster="$1" tries=0
  while [[ $tries -lt $BYOC_IMPORT_WAIT_ATTEMPTS ]]; do
    oc get namespace "$cluster" &>/dev/null && return 0
    _byoc_log "[$cluster] waiting for hub namespace ($((tries + 1))/${BYOC_IMPORT_WAIT_ATTEMPTS})..."
    sleep "$BYOC_IMPORT_WAIT_SLEEP"
    tries=$((tries + 1))
  done
  _byoc_warn "[$cluster] hub namespace did not appear."
  return 1
}

wait_for_eso_secret() {
  local cluster="$1" secret="$2" tries=0
  while [[ $tries -lt $BYOC_IMPORT_WAIT_ATTEMPTS ]]; do
    _secret_has_kubeconfig_data "$cluster" "$secret" && return 0
    _byoc_log "[$cluster] waiting for $secret ($((tries + 1))/${BYOC_IMPORT_WAIT_ATTEMPTS})..."
    sleep "$BYOC_IMPORT_WAIT_SLEEP"
    tries=$((tries + 1))
  done
  _byoc_warn "[$cluster] secret $secret not ready."
  return 1
}

wait_for_managedcluster_joined() {
  local cluster="$1" tries=0 joined
  while [[ $tries -lt $BYOC_IMPORT_WAIT_ATTEMPTS ]]; do
    joined="$(oc get managedcluster "$cluster" \
      -o jsonpath='{.status.conditions[?(@.type=="ManagedClusterJoined")].status}' 2>/dev/null || true)"
    [[ "$joined" == "True" ]] && return 0
    _byoc_log "[$cluster] waiting for ManagedCluster Joined ($((tries + 1))/${BYOC_IMPORT_WAIT_ATTEMPTS})..."
    sleep "$BYOC_IMPORT_WAIT_SLEEP"
    tries=$((tries + 1))
  done
  _byoc_warn "[$cluster] ManagedCluster did not reach Joined."
  return 1
}

byoc_spokes_joined_count() {
  local cluster joined count=0
  for cluster in $SPOKE_CLUSTERS; do
    joined="$(oc get managedcluster "$cluster" \
      -o jsonpath='{.status.conditions[?(@.type=="ManagedClusterJoined")].status}' 2>/dev/null || true)"
    [[ "$joined" == "True" ]] && count=$((count + 1))
  done
  echo "$count"
}

wait_for_byoc_spoke_import() {
  local cluster failed=0
  _byoc_log "Waiting for BYOC spoke import (${SPOKE_CLUSTERS})..."
  bootstrap_byoc_spoke_import || true
  for cluster in $SPOKE_CLUSTERS; do
    wait_for_spoke_namespace "$cluster" || { failed=1; continue; }
    wait_for_eso_secret "$cluster" auto-import-secret || failed=1
    wait_for_eso_secret "$cluster" admin-kubeconfig || failed=1
    wait_for_managedcluster_joined "$cluster" || failed=1
  done
  if [[ "$failed" -ne 0 ]]; then
    oc get managedcluster $SPOKE_CLUSTERS \
      -o custom-columns='NAME:.metadata.name,JOINED:.status.conditions[?(@.type=="ManagedClusterJoined")].status,AVAILABLE:.status.conditions[?(@.type=="ManagedClusterConditionAvailable")].status' \
      2>/dev/null || true
    return 1
  fi
  _byoc_log "All BYOC spokes imported."
}

# Pre-PR-#25 OR gate: continue past install-byoc timeout when hub landed.
pattern_install_recoverable() {
  local ns hub_health rdr_health acm_health joined
  ns="$(hub_argocd_namespace)"
  hub_health="$(hub_pattern_app_health)"
  rdr_health=$(oc get application.argoproj.io regional-dr -n "$ns" \
    -o jsonpath='{.status.health.status}' 2>/dev/null || true)
  acm_health=$(oc get application.argoproj.io acm -n "$ns" \
    -o jsonpath='{.status.health.status}' 2>/dev/null || true)
  joined=$(oc get managedclusters --no-headers 2>/dev/null | wc -l | tr -d ' ' || true)
  [[ "$hub_health" == "Healthy" ]] \
    || [[ "$rdr_health" == "Healthy" ]] \
    || [[ "$acm_health" == "Healthy" ]] \
    || [[ "${joined:-0}" -ge 3 ]]
}

# Count hub child apps still blocking convergence.
_pattern_install_blocking_count() {
  local allow_byoc_pending="${1:-0}" hub_health="$2" acm_health="$3" spokes_joined="$4"
  local ns parent line name sync health count=0

  ns="$(hub_argocd_namespace)"
  parent="$(hub_pattern_app_name)"

  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    name="${line%%|*}"
    sync="${line#*|}"; sync="${sync%%|*}"
    health="${line##*|}"

    [[ "$sync" == "Synced" && "$health" == "Healthy" ]] && continue
    [[ "$name" == "$parent" && "$health" == "Healthy" ]] && continue
    case "$name" in
      regional-dr|opp-policy|odf|odf-dr|acm)
        [[ "$health" == "Healthy" ]] && continue
        ;;
    esac
    if [[ "$allow_byoc_pending" == "1" && "${spokes_joined:-0}" -lt 2 \
          && "$hub_health" == "Healthy" && "$acm_health" == "Healthy" ]]; then
      case "$name" in
        odf-dr|opp-policy)
          [[ "$health" == "Progressing" || "$health" == "Healthy" ]] && continue
          ;;
      esac
    fi
    count=$((count + 1))
  done < <(oc get application.argoproj.io -n "$ns" \
    -o jsonpath='{range .items[*]}{.metadata.name}|{.status.sync.status}|{.status.health.status}{"\n"}{end}' \
    2>/dev/null || true)
  echo "$count"
}

pattern_install_early_exit_watcher() {
  local pid="$1" consecutive=0 reason=""
  local ns hub_health rdr_health acm_health spokes_joined blocking

  ns="$(hub_argocd_namespace)"
  while kill -0 "$pid" 2>/dev/null; do
    sleep "$PATTERN_INSTALL_EARLY_EXIT_SLEEP"
    [[ -n "${KUBECONFIG:-}" ]] || continue

    hub_health="$(hub_pattern_app_health)"
    rdr_health=$(oc get application.argoproj.io regional-dr -n "$ns" \
      -o jsonpath='{.status.health.status}' 2>/dev/null || true)
    acm_health=$(oc get application.argoproj.io acm -n "$ns" \
      -o jsonpath='{.status.health.status}' 2>/dev/null || true)
    spokes_joined="$(byoc_spokes_joined_count 2>/dev/null || echo 0)"

    if [[ "$hub_health" == "Healthy" && "$rdr_health" == "Healthy" ]]; then
      blocking="$(_pattern_install_blocking_count 0 "$hub_health" "$acm_health" "$spokes_joined")"
      if [[ "${blocking:-1}" == "0" ]]; then
        reason="stable drift"
      fi
    elif [[ "$hub_health" == "Healthy" && "$acm_health" == "Healthy" \
        && "${spokes_joined:-0}" -lt 2 ]] && _byoc_bootstrap_secrets_ready; then
      blocking="$(_pattern_install_blocking_count 1 "$hub_health" "$acm_health" "$spokes_joined")"
      if [[ "${blocking:-1}" == "0" ]]; then
        reason="BYOC spoke import pending"
      fi
    fi

    if [[ -n "$reason" ]]; then
      consecutive=$((consecutive + 1))
      _byoc_log "[early-exit] ${reason} (${consecutive}/${PATTERN_INSTALL_EARLY_EXIT_CHECKS})..."
      if [[ "$consecutive" -ge "$PATTERN_INSTALL_EARLY_EXIT_CHECKS" ]]; then
        _byoc_log "[early-exit] Cutting pattern.sh short."
        kill "$pid" 2>/dev/null || true
        return 0
      fi
    else
      consecutive=0
    fi
  done
}

nudge_progressing_odf_apps() {
  local ns parent app
  ns="$(hub_argocd_namespace)"
  parent="$(hub_pattern_app_name)"
  if ! oc get application.argoproj.io regional-dr -n "$ns" &>/dev/null; then
    oc patch application.argoproj.io "$parent" -n vp-gitops --type merge \
      -p '{"operation":{"initiatedBy":{"automated":true},"sync":{}}}' 2>/dev/null || true
  fi
  for app in odf-dr opp-policy regional-dr; do
    oc patch application.argoproj.io "$app" -n "$ns" --type merge \
      -p '{"operation":{"initiatedBy":{"automated":true},"sync":{}}}' 2>/dev/null || true
  done
}
