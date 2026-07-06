#!/usr/bin/env bash
# ACM resilient clustergroup placement helpers for BYOC redeploy.
#
# Spoke ODF (values-resilient.yaml) is delivered via resilient-placement on the hub.
# That placement is often evaluated before BYOC spokes register, leaving an empty
# PlacementDecision and blocking ramendr-starter-kit-resilient on the spokes.

: "${SPOKE_CLUSTER_GROUP_LABEL:=resilient}"
: "${ACM_PLACEMENT_NAMESPACE:=open-cluster-management}"
: "${RESILIENT_PLACEMENT_NAME:=resilient-placement}"
: "${SPOKE_CLUSTERS:=ocp-primary ocp-secondary}"
: "${SPOKE_GITOPS_NS:=vp-gitops}"
: "${RESILIENT_PARENT_APP:=ramendr-starter-kit-resilient}"
: "${RESILIENT_APP_RECOVERY_AFTER_SECONDS:=900}"
: "${SPOKE_APPPROJECT_PREP_WAIT_ATTEMPTS:=40}"
: "${SPOKE_APPPROJECT_PREP_WAIT_SLEEP:=15}"
: "${PRIMARY_INSTALL_DIR:=$HOME/git/ocp-primary-install}"
: "${SECONDARY_INSTALL_DIR:=$HOME/git/ocp-secondary-install}"

_rs_log() {
  if [[ $(type -t log) == function ]]; then
    log "$@"
  else
    echo "[resilient-spokes] $*"
  fi
}

_rs_warn() {
  if [[ $(type -t warn) == function ]]; then
    warn "$@"
  else
    echo "[resilient-spokes] WARNING: $*" >&2
  fi
}

managedcluster_api_available() {
  oc api-resources --api-group=cluster.open-cluster-management.io 2>/dev/null \
    | awk '$NF == "ManagedCluster" { found=1 } END { exit !found }'
}

placement_api_available() {
  oc api-resources --api-group=cluster.open-cluster-management.io 2>/dev/null \
    | awk '$NF == "Placement" { found=1 } END { exit !found }'
}

ensure_spoke_managed_cluster_labels() {
  local cluster="$1"
  managedcluster_api_available || return 0
  oc label managedcluster "$cluster" \
    "clusterGroup=${SPOKE_CLUSTER_GROUP_LABEL}" --overwrite &>/dev/null || return 1
}

register_spoke_managed_cluster() {
  local cluster="$1"
  if ! managedcluster_api_available; then
    return 0
  fi

  if oc get managedcluster "$cluster" &>/dev/null; then
    if ! ensure_spoke_managed_cluster_labels "$cluster"; then
      _rs_warn "[placement] Failed to label existing ManagedCluster ${cluster}."
      return 1
    fi
    return 0
  fi

  if ! oc apply -f - <<EOF
apiVersion: cluster.open-cluster-management.io/v1
kind: ManagedCluster
metadata:
  name: ${cluster}
  labels:
    clusterGroup: ${SPOKE_CLUSTER_GROUP_LABEL}
spec:
  hubAcceptsClient: true
EOF
  then
    _rs_warn "[placement] Failed to register ManagedCluster ${cluster}."
    return 1
  fi
  _rs_log "[placement] Registered ManagedCluster ${cluster} (clusterGroup=${SPOKE_CLUSTER_GROUP_LABEL})."
}

preregister_spoke_managed_clusters() {
  if ! managedcluster_api_available; then
    _rs_log "[placement] ManagedCluster API not ready -- skipping spoke registration."
    return 0
  fi
  local cluster
  for cluster in $SPOKE_CLUSTERS; do
    register_spoke_managed_cluster "$cluster"
  done
}

spoke_managed_cluster_joined() {
  local cluster="$1"
  [[ "$(oc get managedcluster "$cluster" \
    -o jsonpath='{.status.conditions[?(@.type=="ManagedClusterJoined")].status}' 2>/dev/null)" == "True" ]]
}

joined_spoke_count() {
  local cluster count=0
  for cluster in $SPOKE_CLUSTERS; do
    spoke_managed_cluster_joined "$cluster" && count=$((count + 1))
  done
  echo "$count"
}

resilient_placement_clusters() {
  oc get placementdecision -n "$ACM_PLACEMENT_NAMESPACE" \
    -l "cluster.open-cluster-management.io/placement=${RESILIENT_PLACEMENT_NAME}" \
    -o jsonpath='{range .items[*]}{range .status.decisions[*]}{.clusterName}{"\n"}{end}{end}' 2>/dev/null \
    | sort -u
}

resilient_placement_selected_count() {
  local cluster count=0
  for cluster in $SPOKE_CLUSTERS; do
    resilient_placement_clusters | grep -qx "$cluster" && count=$((count + 1))
  done
  echo "$count"
}

resilient_placement_satisfied() {
  local expected="${1:-2}"
  [[ "$(resilient_placement_selected_count)" -ge "$expected" ]]
}

refresh_resilient_placements() {
  placement_api_available || return 0
  local pd deleted=0
  while IFS= read -r pd; do
    [[ -z "$pd" ]] && continue
    if oc delete "$pd" -n "$ACM_PLACEMENT_NAMESPACE" --ignore-not-found &>/dev/null; then
      deleted=$((deleted + 1))
    fi
  done < <(
    {
      oc get placementdecision -n "$ACM_PLACEMENT_NAMESPACE" \
        -l "cluster.open-cluster-management.io/placement=${RESILIENT_PLACEMENT_NAME}" \
        -o name 2>/dev/null
      oc get placementdecision -n "$ACM_PLACEMENT_NAMESPACE" \
        -l "cluster.open-cluster-management.io/placement=hub-argo-ca-resilient" \
        -o name 2>/dev/null
    } | sort -u
  )
  if [[ "$deleted" -gt 0 ]]; then
    _rs_log "[placement] Deleted ${deleted} stale PlacementDecision(s); ACM will reschedule."
  fi
}

wait_for_resilient_placement() {
  local expected="${1:-2}"
  local max_attempts="${RESILIENT_PLACEMENT_WAIT_ATTEMPTS:-40}"
  local sleep_s="${RESILIENT_PLACEMENT_WAIT_SLEEP:-30}"
  local tries=0

  _rs_log "[placement] Waiting for ${RESILIENT_PLACEMENT_NAME} to select ${expected} spoke(s)..."
  while [[ $tries -lt $max_attempts ]]; do
    if resilient_placement_satisfied "$expected"; then
      _rs_log "[placement] ${RESILIENT_PLACEMENT_NAME} selects: $(resilient_placement_clusters | tr '\n' ' ')"
      return 0
    fi

    if [[ "$(joined_spoke_count)" -ge "$expected" ]]; then
      refresh_resilient_placements
    fi

    tries=$((tries + 1))
    _rs_log "[placement] Still waiting (${tries}/${max_attempts}); joined=$(joined_spoke_count), selected=$(resilient_placement_selected_count)"
    sleep "$sleep_s"
  done

  _rs_warn "[placement] Timed out waiting for ${RESILIENT_PLACEMENT_NAME} (${expected} spokes expected)."
  oc get placement "$RESILIENT_PLACEMENT_NAME" -n "$ACM_PLACEMENT_NAMESPACE" \
    -o custom-columns='NAME:.metadata.name,SATISFIED:.status.conditions[?(@.type=="PlacementSatisfied")].status,REASON:.status.conditions[?(@.type=="PlacementSatisfied")].reason' \
    2>/dev/null || true
  return 1
}

ensure_resilient_spoke_gitops() {
  preregister_spoke_managed_clusters
  refresh_resilient_placements
  wait_for_resilient_placement 2
}

_spoke_install_dir() {
  case "$1" in
    ocp-primary) echo "$PRIMARY_INSTALL_DIR" ;;
    ocp-secondary) echo "$SECONDARY_INSTALL_DIR" ;;
    *) return 1 ;;
  esac
}

_spoke_kubeconfig() {
  local dir
  dir=$(_spoke_install_dir "$1") || return 1
  echo "${dir}/auth/kubeconfig"
}

ensure_spoke_argo_appproject_default() {
  local kc="$1"
  local ns="${2:-$SPOKE_GITOPS_NS}"

  if KUBECONFIG="$kc" oc get appproject default -n "$ns" &>/dev/null; then
    return 0
  fi

  _rs_log "[spoke-gitops] Creating AppProject/default in ${ns} (parent app references project default)."
  KUBECONFIG="$kc" oc apply -f - <<EOF
apiVersion: argoproj.io/v1alpha1
kind: AppProject
metadata:
  name: default
  namespace: ${ns}
spec:
  clusterResourceWhitelist:
  - group: '*'
    kind: '*'
  destinations:
  - namespace: '*'
    server: '*'
  sourceRepos:
  - '*'
EOF
}

# Parent resilient Application uses spec.project: default. On a fresh spoke, ACM/Argo can
# auto-sync before AppProject/default exists, wedging the sync with InvalidSpecError and
# blocking ODF (openshift-storage) child apps. Create the project early and unblock.
prepare_spoke_argo_appprojects_on_all_spokes() {
  local max_attempts="${SPOKE_APPPROJECT_PREP_WAIT_ATTEMPTS}"
  local sleep_s="${SPOKE_APPPROJECT_PREP_WAIT_SLEEP}"
  local tries=0 ready_count cluster kc expected
  expected=$(wc -w <<< "$SPOKE_CLUSTERS")

  _rs_log "[spoke-gitops] Preparing AppProject/default on all spokes (before resilient parent sync)..."
  while [[ $tries -lt $max_attempts ]]; do
    ready_count=0
    for cluster in $SPOKE_CLUSTERS; do
      kc=$(_spoke_kubeconfig "$cluster") || continue
      [[ -f "$kc" ]] || continue
      if ! KUBECONFIG="$kc" oc get namespace "$SPOKE_GITOPS_NS" &>/dev/null; then
        continue
      fi
      ensure_spoke_argo_appproject_default "$kc" "$SPOKE_GITOPS_NS"
      if spoke_resilient_app_needs_recovery "$cluster"; then
        recover_spoke_resilient_app "$cluster" || true
      fi
      ready_count=$((ready_count + 1))
    done

    if [[ "$ready_count" -ge "$expected" ]]; then
      _rs_log "[spoke-gitops] AppProject/default ready on all spokes."
      return 0
    fi

    tries=$((tries + 1))
    _rs_log "[spoke-gitops] Waiting for ${SPOKE_GITOPS_NS} on all spokes (${tries}/${max_attempts})..."
    sleep "$sleep_s"
  done

  _rs_warn "[spoke-gitops] Timed out pre-creating AppProject/default on all spokes."
  for cluster in $SPOKE_CLUSTERS; do
    kc=$(_spoke_kubeconfig "$cluster") || continue
    [[ -f "$kc" ]] || continue
    if KUBECONFIG="$kc" oc get namespace "$SPOKE_GITOPS_NS" &>/dev/null; then
      ensure_spoke_argo_appproject_default "$kc" "$SPOKE_GITOPS_NS" || true
      if spoke_resilient_app_needs_recovery "$cluster"; then
        recover_spoke_resilient_app "$cluster" || true
      fi
    fi
  done
  return 1
}

spoke_resilient_app_exists() {
  local cluster="$1"
  local kc
  kc=$(_spoke_kubeconfig "$cluster") || return 1
  [[ -f "$kc" ]] || return 1
  KUBECONFIG="$kc" oc get application.argoproj.io "$RESILIENT_PARENT_APP" \
    -n "$SPOKE_GITOPS_NS" &>/dev/null
}

spoke_resilient_app_needs_recovery() {
  local cluster="$1"
  local kc sync health op_phase op_msg invalid op_started started_s now_s

  kc=$(_spoke_kubeconfig "$cluster") || return 1
  [[ -f "$kc" ]] || return 1

  if ! KUBECONFIG="$kc" oc get application.argoproj.io "$RESILIENT_PARENT_APP" \
    -n "$SPOKE_GITOPS_NS" &>/dev/null; then
    return 1
  fi

  sync=$(KUBECONFIG="$kc" oc get application.argoproj.io "$RESILIENT_PARENT_APP" \
    -n "$SPOKE_GITOPS_NS" -o jsonpath='{.status.sync.status}' 2>/dev/null || true)
  health=$(KUBECONFIG="$kc" oc get application.argoproj.io "$RESILIENT_PARENT_APP" \
    -n "$SPOKE_GITOPS_NS" -o jsonpath='{.status.health.status}' 2>/dev/null || true)

  if [[ "$sync" == "Synced" && "$health" == "Healthy" ]]; then
    return 1
  fi

  invalid=$(KUBECONFIG="$kc" oc get application.argoproj.io "$RESILIENT_PARENT_APP" \
    -n "$SPOKE_GITOPS_NS" \
    -o jsonpath='{.status.conditions[?(@.type=="InvalidSpecError")].message}' 2>/dev/null || true)
  op_msg=$(KUBECONFIG="$kc" oc get application.argoproj.io "$RESILIENT_PARENT_APP" \
    -n "$SPOKE_GITOPS_NS" -o jsonpath='{.status.operationState.message}' 2>/dev/null || true)
  op_phase=$(KUBECONFIG="$kc" oc get application.argoproj.io "$RESILIENT_PARENT_APP" \
    -n "$SPOKE_GITOPS_NS" -o jsonpath='{.status.operationState.phase}' 2>/dev/null || true)
  op_started=$(KUBECONFIG="$kc" oc get application.argoproj.io "$RESILIENT_PARENT_APP" \
    -n "$SPOKE_GITOPS_NS" -o jsonpath='{.status.operationState.startedAt}' 2>/dev/null || true)

  if [[ -n "$invalid" ]] \
    || [[ "$op_msg" == *InvalidSpecError* ]] \
    || [[ "$op_msg" == *"does not exist"* ]]; then
    return 0
  fi
  if [[ "$op_phase" == "Running" && "$sync" != "Synced" ]]; then
    started_s=$(date -d "$op_started" +%s 2>/dev/null || echo 0)
    now_s=$(date +%s)
    if [[ "$started_s" -gt 0 && $((now_s - started_s)) -ge "$RESILIENT_APP_RECOVERY_AFTER_SECONDS" ]]; then
      return 0
    fi
  fi
  return 1
}

recover_spoke_resilient_app() {
  local cluster="$1"
  local kc
  kc=$(_spoke_kubeconfig "$cluster") || return 1
  [[ -f "$kc" ]] || { _rs_warn "[spoke-gitops] No kubeconfig for ${cluster}."; return 1; }

  if ! KUBECONFIG="$kc" oc get application.argoproj.io "$RESILIENT_PARENT_APP" \
    -n "$SPOKE_GITOPS_NS" &>/dev/null; then
    return 1
  fi

  _rs_log "[spoke-gitops] Recovering ${RESILIENT_PARENT_APP} on ${cluster} (terminate wedged sync, refresh, resync)..."
  ensure_spoke_argo_appproject_default "$kc" "$SPOKE_GITOPS_NS"

  KUBECONFIG="$kc" oc patch application.argoproj.io "$RESILIENT_PARENT_APP" \
    -n "$SPOKE_GITOPS_NS" --type merge -p '{"operation":null}' 2>/dev/null || true
  KUBECONFIG="$kc" oc annotate application.argoproj.io "$RESILIENT_PARENT_APP" \
    -n "$SPOKE_GITOPS_NS" argocd.argoproj.io/refresh=hard --overwrite 2>/dev/null || true
  sleep 5
  KUBECONFIG="$kc" oc patch application.argoproj.io "$RESILIENT_PARENT_APP" \
    -n "$SPOKE_GITOPS_NS" --type merge \
    -p '{"operation":{"initiatedBy":{"username":"redeploy"},"sync":{"revision":"HEAD","syncStrategy":{"apply":{"force":true},"hook":{}}}}}' \
    2>/dev/null || true
}

recover_all_spoke_resilient_apps() {
  local cluster recovered=0
  for cluster in $SPOKE_CLUSTERS; do
    if spoke_resilient_app_needs_recovery "$cluster"; then
      recover_spoke_resilient_app "$cluster" && recovered=$((recovered + 1))
    fi
  done
  [[ "$recovered" -gt 0 ]]
}

spoke_resilient_gitops_ready() {
  local cluster="$1"
  local kc sync health

  kc=$(_spoke_kubeconfig "$cluster") || return 1
  [[ -f "$kc" ]] || return 1

  if ! KUBECONFIG="$kc" oc get application.argoproj.io "$RESILIENT_PARENT_APP" \
    -n "$SPOKE_GITOPS_NS" &>/dev/null; then
    return 1
  fi

  sync=$(KUBECONFIG="$kc" oc get application.argoproj.io "$RESILIENT_PARENT_APP" \
    -n "$SPOKE_GITOPS_NS" -o jsonpath='{.status.sync.status}' 2>/dev/null || true)
  health=$(KUBECONFIG="$kc" oc get application.argoproj.io "$RESILIENT_PARENT_APP" \
    -n "$SPOKE_GITOPS_NS" -o jsonpath='{.status.health.status}' 2>/dev/null || true)

  [[ "$sync" == "Synced" ]] || return 1
  [[ "$health" == "Healthy" || "$health" == "Progressing" ]] || return 1
  KUBECONFIG="$kc" oc get namespace openshift-storage &>/dev/null
}

spoke_resilient_gitops_all_ready() {
  local cluster
  for cluster in $SPOKE_CLUSTERS; do
    spoke_resilient_gitops_ready "$cluster" || return 1
  done
  return 0
}

_spoke_resilient_gitops_status_line() {
  local cluster="$1"
  local kc sync health odf_ns

  kc=$(_spoke_kubeconfig "$cluster") || return 0
  [[ -f "$kc" ]] || return 0

  if ! KUBECONFIG="$kc" oc get application.argoproj.io "$RESILIENT_PARENT_APP" \
    -n "$SPOKE_GITOPS_NS" &>/dev/null; then
    echo "${cluster}: app missing"
    return 0
  fi

  sync=$(KUBECONFIG="$kc" oc get application.argoproj.io "$RESILIENT_PARENT_APP" \
    -n "$SPOKE_GITOPS_NS" -o jsonpath='{.status.sync.status}' 2>/dev/null || echo unknown)
  health=$(KUBECONFIG="$kc" oc get application.argoproj.io "$RESILIENT_PARENT_APP" \
    -n "$SPOKE_GITOPS_NS" -o jsonpath='{.status.health.status}' 2>/dev/null || echo unknown)
  if KUBECONFIG="$kc" oc get namespace openshift-storage &>/dev/null; then
    odf_ns=yes
  else
    odf_ns=no
  fi
  echo "${cluster}: sync=${sync} health=${health} openshift-storage=${odf_ns}"
}

wait_for_spoke_resilient_gitops() {
  local max_attempts="${SPOKE_RESILIENT_GITOPS_WAIT_ATTEMPTS:-60}"
  local sleep_s="${SPOKE_RESILIENT_GITOPS_WAIT_SLEEP:-60}"
  local tries=0 ready_count=0 cluster kc expected
  expected=$(wc -w <<< "$SPOKE_CLUSTERS")

  prepare_spoke_argo_appprojects_on_all_spokes || true

  _rs_log "[spoke-gitops] Waiting for ${RESILIENT_PARENT_APP} + openshift-storage on all spokes..."
  while [[ $tries -lt $max_attempts ]]; do
    ready_count=0
    for cluster in $SPOKE_CLUSTERS; do
      kc=$(_spoke_kubeconfig "$cluster") || continue
      [[ -f "$kc" ]] || continue
      if KUBECONFIG="$kc" oc get namespace "$SPOKE_GITOPS_NS" &>/dev/null; then
        ensure_spoke_argo_appproject_default "$kc" "$SPOKE_GITOPS_NS"
      fi
      if spoke_resilient_gitops_ready "$cluster"; then
        ready_count=$((ready_count + 1))
        continue
      fi
      if spoke_resilient_app_needs_recovery "$cluster"; then
        recover_spoke_resilient_app "$cluster" || true
      fi
    done

    if [[ "$ready_count" -ge "$expected" ]]; then
      _rs_log "[spoke-gitops] Spoke resilient GitOps converged on all spokes."
      return 0
    fi

    tries=$((tries + 1))
    _rs_log "[spoke-gitops] Still waiting (${tries}/${max_attempts}); ready=${ready_count}/${expected} — $(_spoke_resilient_gitops_status_line ocp-primary); $(_spoke_resilient_gitops_status_line ocp-secondary)"
    sleep "$sleep_s"
  done

  _rs_warn "[spoke-gitops] Timed out waiting for spoke resilient GitOps / ODF namespace."
  _spoke_resilient_gitops_status_line ocp-primary
  _spoke_resilient_gitops_status_line ocp-secondary
  return 1
}
