#!/usr/bin/env bash
# Wait for BYOC spoke import via ExternalSecrets + ACM ManagedCluster join.

set -euo pipefail

: "${BYOC_IMPORT_WAIT_ATTEMPTS:=40}"
: "${BYOC_IMPORT_WAIT_SLEEP:=30}"
: "${SPOKE_CLUSTERS:=ocp-primary ocp-secondary}"

_byoc_wait_log() {
  if [[ $(type -t log) == function ]]; then
    log "$@"
  else
    echo "[byoc-import] $*"
  fi
}

_byoc_wait_warn() {
  if [[ $(type -t warn) == function ]]; then
    warn "$@"
  else
    echo "[byoc-import] WARNING: $*" >&2
  fi
}

wait_for_spoke_namespace() {
  local cluster="$1"
  local tries=0
  while [[ $tries -lt $BYOC_IMPORT_WAIT_ATTEMPTS ]]; do
    if oc get namespace "$cluster" &>/dev/null; then
      return 0
    fi
    _byoc_wait_log "[$cluster] waiting for hub namespace (attempt $((tries + 1))/${BYOC_IMPORT_WAIT_ATTEMPTS})..."
    sleep "$BYOC_IMPORT_WAIT_SLEEP"
    tries=$((tries + 1))
  done
  _byoc_wait_warn "[$cluster] hub namespace did not appear within timeout."
  return 1
}

_secret_has_kubeconfig_data() {
  local namespace="$1" secret="$2"
  local b64
  b64="$(oc get secret "$secret" -n "$namespace" \
    -o jsonpath='{.data.kubeconfig}' 2>/dev/null || true)"
  [[ -n "$b64" ]]
}

wait_for_eso_secret() {
  local cluster="$1" secret="$2"
  local tries=0
  while [[ $tries -lt $BYOC_IMPORT_WAIT_ATTEMPTS ]]; do
    if _secret_has_kubeconfig_data "$cluster" "$secret"; then
      _byoc_wait_log "[$cluster] secret $secret is ready."
      return 0
    fi
    _byoc_wait_log "[$cluster] waiting for ESO secret $secret (attempt $((tries + 1))/${BYOC_IMPORT_WAIT_ATTEMPTS})..."
    sleep "$BYOC_IMPORT_WAIT_SLEEP"
    tries=$((tries + 1))
  done
  _byoc_wait_warn "[$cluster] secret $secret not ready within timeout."
  return 1
}

wait_for_managedcluster_joined() {
  local cluster="$1"
  local tries=0 joined
  while [[ $tries -lt $BYOC_IMPORT_WAIT_ATTEMPTS ]]; do
    joined="$(oc get managedcluster "$cluster" \
      -o jsonpath='{.status.conditions[?(@.type=="ManagedClusterJoined")].status}' 2>/dev/null || true)"
    if [[ "$joined" == "True" ]]; then
      _byoc_wait_log "[$cluster] ManagedCluster Joined."
      return 0
    fi
    _byoc_wait_log "[$cluster] waiting for ManagedCluster Joined (attempt $((tries + 1))/${BYOC_IMPORT_WAIT_ATTEMPTS})..."
    sleep "$BYOC_IMPORT_WAIT_SLEEP"
    tries=$((tries + 1))
  done
  _byoc_wait_warn "[$cluster] ManagedCluster did not reach Joined within timeout."
  return 1
}

wait_for_byoc_spoke_import() {
  local cluster failed=0
  _byoc_wait_log "Waiting for BYOC spoke import via ExternalSecrets (clusters: ${SPOKE_CLUSTERS})..."
  for cluster in $SPOKE_CLUSTERS; do
    wait_for_spoke_namespace "$cluster" || failed=1
    wait_for_eso_secret "$cluster" "auto-import-secret" || failed=1
    wait_for_eso_secret "$cluster" "admin-kubeconfig" || failed=1
    wait_for_managedcluster_joined "$cluster" || failed=1
  done
  if [[ "$failed" -ne 0 ]]; then
    oc get managedcluster $SPOKE_CLUSTERS \
      -o custom-columns='NAME:.metadata.name,JOINED:.status.conditions[?(@.type=="ManagedClusterJoined")].status,AVAILABLE:.status.conditions[?(@.type=="ManagedClusterConditionAvailable")].status' \
      2>/dev/null || true
    return 1
  fi
  _byoc_wait_log "All BYOC spokes imported."
}
