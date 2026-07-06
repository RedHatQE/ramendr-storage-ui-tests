#!/usr/bin/env bash
# c5n.metal MachineSets for spoke clusters (sourced by redeploy.sh).

create_spoke_metal_machinesets() {
  local replicas="${SPOKE_METAL_REPLICAS:-2}"
  log "Creating c5n.metal MachineSets on spoke clusters (${replicas} node(s) per spoke, 300 GiB root disk)..."
  for entry in "ocp-primary:$PRIMARY_INSTALL_DIR" "ocp-secondary:$SECONDARY_INSTALL_DIR"; do
    local cluster="${entry%%:*}"
    local dir="${entry##*:}"
    local kubeconfig="$dir/auth/kubeconfig"
    [[ -f "$kubeconfig" ]] || { warn " No kubeconfig for $cluster - skipping metal MachineSet."; continue; }

    local infra_id
    [[ -f "$dir/metadata.json" ]] || { warn " No metadata.json for $cluster - skipping metal MachineSet."; continue; }
    infra_id=$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['infraID'])" "$dir/metadata.json" 2>/dev/null) \
      || { warn " Could not read infraID for $cluster - skipping."; continue; }

    mapfile -t template_names < <(
      KUBECONFIG="$kubeconfig" oc get machineset -n openshift-machine-api -o json 2>/dev/null | \
        python3 -c "
import json, sys
limit = int('${replicas}')
items = json.load(sys.stdin).get('items', [])
workers = []
for ms in items:
    name = ms['metadata']['name']
    if 'worker' not in name or 'submariner' in name or 'metal' in name:
        continue
    workers.append(name)
for name in sorted(workers)[:limit]:
    print(name)
"
    )
    if [[ ${#template_names[@]} -eq 0 ]]; then
      warn " No worker MachineSet templates found for $cluster - skipping metal MachineSets."
      continue
    fi

    local template_name metal_name az_suffix
    for template_name in "${template_names[@]}"; do
      az_suffix="${template_name##*-}"
      metal_name="${infra_id}-metal-${az_suffix}"
      log " Cloning $template_name -> $metal_name (c5n.metal) on $cluster..."

      KUBECONFIG="$kubeconfig" oc get machineset "$template_name" \
        -n openshift-machine-api -o json 2>/dev/null | \
        python3 -c "
import sys, json, copy
ms = json.load(sys.stdin)
new_name = '${metal_name}'
n = copy.deepcopy(ms)
for k in ('resourceVersion','uid','generation','creationTimestamp','managedFields','annotations'):
  n['metadata'].pop(k, None)
n['metadata']['name'] = new_name
n.pop('status', None)
n['spec']['replicas'] = 1
n['spec']['selector']['matchLabels']['machine.openshift.io/cluster-api-machineset'] = new_name
n['spec']['template']['metadata']['labels']['machine.openshift.io/cluster-api-machineset'] = new_name
pv = n['spec']['template']['spec']['providerSpec']['value']
pv['instanceType'] = 'c5n.metal'
existing = pv.get('blockDevices') or pv.get('blockDeviceMappings') or []
vol = (existing[0].get('ebs') if existing else {}) or {}
pv['blockDevices'] = [{'ebs': {
  'encrypted': vol.get('encrypted', True),
  'kmsKey': vol.get('kmsKey', {}),
  'volumeSize': 300,
  'volumeType': vol.get('volumeType', 'gp3'),
}}]
pv.pop('blockDeviceMappings', None)
print(json.dumps(n))
" | KUBECONFIG="$kubeconfig" oc apply -f - 2>/dev/null && \
        log " MachineSet $metal_name created on $cluster." || \
        warn " MachineSet $metal_name may already exist on $cluster (apply failed - continuing)."
    done
  done
}

wait_for_spoke_metal_nodes() {
  local replicas="${SPOKE_METAL_REPLICAS:-2}"
  log "Waiting for ${replicas} c5n.metal node(s) per spoke and labeling workers for ODF..."
  for entry in "ocp-primary:$PRIMARY_INSTALL_DIR" "ocp-secondary:$SECONDARY_INSTALL_DIR"; do
    local cluster="${entry%%:*}"
    local dir="${entry##*:}"
    local kubeconfig="$dir/auth/kubeconfig"
    [[ -f "$kubeconfig" ]] || continue

    log " Waiting for ${replicas} c5n.metal node(s) on $cluster (up to 30 min)..."
    local tries=0
    while [[ $tries -lt 60 ]]; do
      local ready
      ready=$(KUBECONFIG="$kubeconfig" oc get nodes \
        -l node.kubernetes.io/instance-type=c5n.metal \
        --no-headers 2>/dev/null | grep -c " Ready " || true)
      if [[ "$ready" -ge "$replicas" ]]; then
        log " ${ready}/${replicas} c5n.metal node(s) Ready on $cluster."
        break
      fi
      log "  ${ready}/${replicas} c5n.metal node(s) Ready on $cluster..."
      sleep 30
      tries=$((tries + 1))
    done
    [[ $tries -ge 60 ]] && \
      warn " Timeout waiting for ${replicas} c5n.metal node(s) on $cluster - ODF/VMs may need manual intervention."

    log " Labeling worker nodes for ODF storage on $cluster..."
    while IFS= read -r node; do
      KUBECONFIG="$kubeconfig" oc label "$node" \
        cluster.ocs.openshift.io/openshift-storage="" --overwrite 2>/dev/null || true
    done < <(KUBECONFIG="$kubeconfig" oc get nodes \
      -l node-role.kubernetes.io/worker -o name 2>/dev/null)
    log " All workers labeled for ODF on $cluster."
  done
}
