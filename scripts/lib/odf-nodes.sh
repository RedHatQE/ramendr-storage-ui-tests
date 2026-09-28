#!/usr/bin/env bash
# shellcheck shell=bash
# Label compact or worker nodes for ODF (no AWS MachineSets).

label_odf_storage_nodes() {
  local min_nodes="${ODF_MIN_LABELED_NODES:-3}"
  log "Labeling ODF storage nodes on hub and spokes (need >= ${min_nodes} Ready per cluster)..."
  local entry cluster dir kubeconfig labeled
  for entry in "hub:$HUB_INSTALL_DIR" "ocp-primary:$PRIMARY_INSTALL_DIR" "ocp-secondary:$SECONDARY_INSTALL_DIR"; do
    cluster="${entry%%:*}"
    dir="${entry##*:}"
    kubeconfig="$dir/auth/kubeconfig"
    if [[ ! -f "$kubeconfig" ]]; then
      warn " No kubeconfig for $cluster - skipping ODF labels."
      continue
    fi

    log " Labeling workers on $cluster..."
    while IFS= read -r node; do
      [[ -n "$node" ]] || continue
      KUBECONFIG="$kubeconfig" oc label "$node" \
        cluster.ocs.openshift.io/openshift-storage="" --overwrite 2>/dev/null || true
    done < <(KUBECONFIG="$kubeconfig" oc get nodes \
      -l node-role.kubernetes.io/worker -o name 2>/dev/null)

    labeled=$(KUBECONFIG="$kubeconfig" oc get nodes \
      -l cluster.ocs.openshift.io/openshift-storage \
      --no-headers 2>/dev/null | grep -c " Ready " || true)
    if [[ "$labeled" -lt "$min_nodes" ]]; then
      log " Compact cluster $cluster: labeling control-plane nodes for ODF..."
      while IFS= read -r node; do
        [[ -n "$node" ]] || continue
        KUBECONFIG="$kubeconfig" oc label "$node" \
          cluster.ocs.openshift.io/openshift-storage="" --overwrite 2>/dev/null || true
      done < <(KUBECONFIG="$kubeconfig" oc get nodes \
        -l node-role.kubernetes.io/control-plane -o name 2>/dev/null)
      labeled=$(KUBECONFIG="$kubeconfig" oc get nodes \
        -l cluster.ocs.openshift.io/openshift-storage \
        --no-headers 2>/dev/null | grep -c " Ready " || true)
    fi

    if [[ "$labeled" -lt "$min_nodes" ]]; then
      err " $cluster has $labeled ODF-labeled Ready nodes (need $min_nodes)."
      return 1
    fi
    log " $cluster: $labeled Ready nodes labeled for ODF."
  done
}
