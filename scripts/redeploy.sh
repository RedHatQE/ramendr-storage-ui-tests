#!/usr/bin/env bash
set -euo pipefail

#
# Deploy pinned upstream ramendr-starter-kit with local overrides.
#
# This script is based on the deployment flow currently used in the forked
# starter kit's `redeploy.sh`, but it decouples upstream content by cloning:
#   https://github.com/validatedpatterns/ramendr-starter-kit
# at a pinned tag and applying overrides from this repository.
#

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

UPSTREAM_REPO="${UPSTREAM_REPO:-https://github.com/validatedpatterns/ramendr-starter-kit}"
UPSTREAM_REF="${UPSTREAM_REF:-v1.1}"

WORK_DIR="${WORK_DIR:-$REPO_ROOT/.work}"
UPSTREAM_DIR="${UPSTREAM_DIR:-$WORK_DIR/upstream/ramendr-starter-kit}"

UPSTREAM_OVERRIDES_DIR="${UPSTREAM_OVERRIDES_DIR:-$REPO_ROOT/upstream-overrides}"

HUB_INSTALL_DIR="${HUB_INSTALL_DIR:-$HOME/git/hub-cluster-install}"
PRIMARY_INSTALL_DIR="${PRIMARY_INSTALL_DIR:-$HOME/git/ocp-primary-install}"
SECONDARY_INSTALL_DIR="${SECONDARY_INSTALL_DIR:-$HOME/git/ocp-secondary-install}"

VALUES_SECRET="${VALUES_SECRET:-$HOME/values-secret.yaml}"

HOSTED_ZONE_ID="${HOSTED_ZONE_ID:-}"
BASE_DOMAIN="${BASE_DOMAIN:-}"

HUB_REGION="${HUB_REGION:-eu-north-1}"
PRIMARY_REGION="${PRIMARY_REGION:-eu-central-1}"
SECONDARY_REGION="${SECONDARY_REGION:-eu-west-1}"

# Target OCP version for all clusters � hub + spokes should use the same minor version
# to avoid ODF Multicluster Orchestrator incompatibilities.
HUB_OCP_VERSION="${HUB_OCP_VERSION:-4.20.6}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log() { echo -e "${GREEN}[$(date +%H:%M:%S)]${NC} $*"; }
warn() { echo -e "${YELLOW}[$(date +%H:%M:%S)] WARNING:${NC} $*"; }
err() { echo -e "${RED}[$(date +%H:%M:%S)] ERROR:${NC} $*"; }

check_prerequisites() {
  log "Checking prerequisites..."
  local missing=0
  for cmd in oc openshift-install aws podman git python3 curl; do
    if ! command -v "$cmd" &>/dev/null; then
      err "Missing: $cmd"
      missing=1
    fi
  done
  if [[ -z "$HOSTED_ZONE_ID" ]]; then
    err "HOSTED_ZONE_ID is not set. Export it or set a default in this script."
    missing=1
  fi
  if [[ -z "$BASE_DOMAIN" ]]; then
    err "BASE_DOMAIN is not set. Export it or set a default in this script."
    missing=1
  fi
  if [[ ! -f "$VALUES_SECRET" ]]; then
    err "Missing secrets file: $VALUES_SECRET"
    missing=1
  fi
  for dir_var in HUB_INSTALL_DIR PRIMARY_INSTALL_DIR SECONDARY_INSTALL_DIR; do
    local dir="${!dir_var}"
    if [[ ! -f "$dir/install-config.yaml.bak" ]]; then
      err "Missing install-config backup: $dir/install-config.yaml.bak"
      missing=1
    fi
  done
  [[ $missing -eq 1 ]] && { err "Prerequisites not met. Aborting."; exit 1; }
  log "All prerequisites met."
}

prepare_upstream() {
  log "Preparing upstream checkout at $UPSTREAM_REF..."
  mkdir -p "$WORK_DIR/upstream"

  if [[ ! -d "$UPSTREAM_DIR/.git" ]]; then
    rm -rf "$UPSTREAM_DIR"
    git clone "$UPSTREAM_REPO" "$UPSTREAM_DIR"
  fi

  (
    cd "$UPSTREAM_DIR"
    git fetch --tags --force origin
    git checkout --force "$UPSTREAM_REF"
  )

  log "Copying local overrides into upstream checkout..."
  mkdir -p "$UPSTREAM_DIR/overrides"
  cp -f "$REPO_ROOT/overrides/"*.yaml "$UPSTREAM_DIR/overrides/"

  if [[ -f "$UPSTREAM_OVERRIDES_DIR/values-hub.patch" ]]; then
    log "Applying values-hub.patch (ODF channel pins + values-aws-cost-optimized extra value file)..."
    if ! (cd "$UPSTREAM_DIR" && git apply --check "$UPSTREAM_OVERRIDES_DIR/values-hub.patch" 2>/dev/null); then
      err "values-hub.patch does not apply cleanly against upstream $UPSTREAM_REF."
      err "Upstream values-hub.yaml may have changed. Review and regenerate the patch:"
      err "  cd .work/upstream/ramendr-starter-kit"
      err "  # edit values-hub.yaml, then:"
      err "  git diff values-hub.yaml > \$REPO_ROOT/upstream-overrides/values-hub.patch"
      exit 1
    fi
    (cd "$UPSTREAM_DIR" && git apply "$UPSTREAM_OVERRIDES_DIR/values-hub.patch")
  fi

  # Upstream pattern.sh uses `podman run -it`, which fails when stdin/stdout are not a TTY (CI, automation).
  # Patch it to detect TTY availability at runtime and drop `-t` when not present.
  if [[ -f "$UPSTREAM_DIR/pattern.sh" ]] && ! grep -q "PODMAN_STDIO_ARGS" "$UPSTREAM_DIR/pattern.sh"; then
    log "Patching upstream pattern.sh for non-TTY automation..."
    (
      cd "$UPSTREAM_DIR"
      python3 - <<'PY'
from pathlib import Path

path = Path("pattern.sh")
text = path.read_text()

needle = "podman run -it --rm --pull=newer \\"
if needle not in text:
    raise SystemExit(0)

replacement = """# Podman requires a TTY for `-t`; CI and some automation shells have no TTY. Use `-i` only then.
PODMAN_STDIO_ARGS=(-it)
if [[ ! -t 0 ]] || [[ ! -t 1 ]]; then
 PODMAN_STDIO_ARGS=(-i)
fi

podman run "${PODMAN_STDIO_ARGS[@]}" --rm --pull=newer \\"""

path.write_text(text.replace(needle, replacement))
PY
    )
  fi
}

cleanup_dns() {
  log "Cleaning stale DNS records from Route53..."
  local stale
  stale=$(aws route53 list-resource-record-sets --hosted-zone-id "$HOSTED_ZONE_ID" \
    --no-paginate --max-items 1000 --output json 2>/dev/null \
    | python3 -c "
import json, sys
data = json.load(sys.stdin)
base = '${BASE_DOMAIN}.'
changes = []
for r in data.get('ResourceRecordSets', []):
  name = r['Name']
  rtype = r['Type']
  if rtype in ('SOA', 'NS'):
    continue
  if rtype in ('A', 'AAAA', 'CNAME') and name != base:
    changes.append({'Action': 'DELETE', 'ResourceRecordSet': r})
  elif rtype == 'TXT' and name != base and base in name:
    changes.append({'Action': 'DELETE', 'ResourceRecordSet': r})
if changes:
  print(json.dumps({'Comment': 'Cleanup stale records', 'Changes': changes}))
else:
  print('')
" 2>/dev/null)

  if [[ -n "$stale" ]]; then
    echo "$stale" > /tmp/dns-cleanup-batch.json
    local count
    count=$(python3 -c "import json; d=json.load(open('/tmp/dns-cleanup-batch.json')); print(len(d['Changes']))")
    aws route53 change-resource-record-sets \
      --hosted-zone-id "$HOSTED_ZONE_ID" \
      --change-batch file:///tmp/dns-cleanup-batch.json &>/dev/null
    log "Stale DNS records cleaned ($count records deleted)."
  else
    log "No stale DNS records found."
  fi
}

release_orphaned_eips() {
  log "Releasing orphaned Elastic IPs..."
  local hub_region primary_region secondary_region
  hub_region=$(python3 -c "import json; print(json.load(open('$HUB_INSTALL_DIR/metadata.json'))['aws']['region'])" 2>/dev/null || echo "$HUB_REGION")
  primary_region=$(python3 -c "import json; print(json.load(open('$PRIMARY_INSTALL_DIR/metadata.json'))['aws']['region'])" 2>/dev/null || echo "$PRIMARY_REGION")
  secondary_region=$(python3 -c "import json; print(json.load(open('$SECONDARY_INSTALL_DIR/metadata.json'))['aws']['region'])" 2>/dev/null || echo "$SECONDARY_REGION")

  local regions
  regions=$(echo -e "$hub_region\n$primary_region\n$secondary_region" | sort -u)

  for region in $regions; do
    local eips
    eips=$(aws ec2 describe-addresses --region "$region" \
      --query 'Addresses[?AssociationId==null].AllocationId' --output text 2>/dev/null)
    for eip in $eips; do
      aws ec2 release-address --region "$region" --allocation-id "$eip" 2>/dev/null
      log " Released EIP $eip in $region"
    done
  done
}

destroy_cluster() {
  local name="$1"
  local dir="$2"
  if [[ -f "$dir/metadata.json" ]]; then
    log "Destroying $name cluster..."
    openshift-install destroy cluster --dir "$dir" --log-level=info 2>&1 \
      || warn "$name destroy had errors (may already be destroyed)"
  else
    warn "No metadata found for $name � skipping (may already be destroyed)."
  fi
}

destroy_managed_clusters() {
  log "Destroying spoke clusters in parallel..."
  destroy_cluster "ocp-primary" "$PRIMARY_INSTALL_DIR" &
  destroy_cluster "ocp-secondary" "$SECONDARY_INSTALL_DIR" &
  wait
  log "Spoke clusters destroyed."
}

destroy_hub() {
  destroy_cluster "hub" "$HUB_INSTALL_DIR"
}

ensure_openshift_install_version() {
  local want="$HUB_OCP_VERSION"
  local got
  got=$(openshift-install version 2>/dev/null | awk 'NR==1{print $2}')
  if [[ "$got" == "$want" ]]; then
    log "openshift-install is already at $want."
    return 0
  fi
  log "openshift-install is at '$got', need $want � downloading..."
  local url="https://mirror.openshift.com/pub/openshift-v4/clients/ocp/${want}/openshift-install-linux.tar.gz"
  local tmp
  tmp=$(mktemp -d)
  curl -fsSL "$url" -o "$tmp/openshift-install.tar.gz"
  tar -xzf "$tmp/openshift-install.tar.gz" -C "$tmp" openshift-install
  chmod +x "$tmp/openshift-install"
  local install_dir
  install_dir=$(dirname "$(command -v openshift-install 2>/dev/null || echo "$HOME/bin/openshift-install")")
  mv "$tmp/openshift-install" "$install_dir/openshift-install"
  rm -rf "$tmp"
  log "openshift-install $want installed to $install_dir."
}

install_one_cluster() {
  local name="$1"
  local dir="$2"
  log "Installing $name cluster..."
  cd "$dir"
  rm -rf .clusterapi_output .openshift_install.log .openshift_install_state.json \
    auth metadata.json terraform* 2>/dev/null || true
  cp install-config.yaml.bak install-config.yaml
  openshift-install create cluster --dir . --log-level=info 2>&1
  log "$name cluster installed."
}

install_hub() {
  ensure_openshift_install_version
  install_one_cluster "hub" "$HUB_INSTALL_DIR"

  log "Hub cluster installed. Setting up kubeconfig..."
  mkdir -p "$HOME/.kube"
  cp "$HUB_INSTALL_DIR/auth/kubeconfig" "$HOME/.kube/config"
  export KUBECONFIG="$HUB_INSTALL_DIR/auth/kubeconfig"

  log "Hub console: https://console-openshift-console.apps.hub.${BASE_DOMAIN}"
  grep -o 'password: "[^"]*"' "$HUB_INSTALL_DIR/.openshift_install.log" | tail -1 || true
}

install_spokes() {
  log "Installing ocp-primary and ocp-secondary in parallel..."
  install_one_cluster "ocp-primary" "$PRIMARY_INSTALL_DIR" &
  install_one_cluster "ocp-secondary" "$SECONDARY_INSTALL_DIR" &
  wait
}

create_spoke_metal_machinesets() {
  log "Creating c5n.metal MachineSets on spoke clusters (300 GiB root disk)..."
  for entry in "ocp-primary:$PRIMARY_INSTALL_DIR" "ocp-secondary:$SECONDARY_INSTALL_DIR"; do
    local cluster="${entry%%:*}"
    local dir="${entry##*:}"
    local kubeconfig="$dir/auth/kubeconfig"
    [[ -f "$kubeconfig" ]] || { warn " No kubeconfig for $cluster � skipping metal MachineSet."; continue; }

    local infra_id
    infra_id=$(python3 -c "import json; print(json.load(open('$dir/metadata.json'))['infraID'])")

    local template_name
    template_name=$(KUBECONFIG="$kubeconfig" oc get machineset -n openshift-machine-api \
      --no-headers -o custom-columns=':.metadata.name' 2>/dev/null | sort | head -1)
    [[ -n "$template_name" ]] || { warn " No MachineSet template found for $cluster � skipping."; continue; }

    local metal_name="${infra_id}-metal"
    log " Cloning $template_name -> $metal_name (c5n.metal, 300 GiB) on $cluster..."

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
bdm = pv.get('blockDeviceMappings', [])
root_dev = bdm[0].get('deviceName', '/dev/xvda') if bdm else '/dev/xvda'
pv['blockDeviceMappings'] = [{'deviceName': root_dev, 'ebs': {
  'encrypted': True, 'kmsKey': {}, 'volumeSize': 300, 'volumeType': 'gp3'}}]
print(json.dumps(n))
" | KUBECONFIG="$kubeconfig" oc apply -f - 2>/dev/null && \
      log " MachineSet $metal_name created on $cluster." || \
      warn " MachineSet $metal_name may already exist on $cluster (apply failed � continuing)."
  done
}

wait_for_spoke_metal_nodes() {
  log "Waiting for c5n.metal nodes on spoke clusters and labeling workers for ODF..."
  for entry in "ocp-primary:$PRIMARY_INSTALL_DIR" "ocp-secondary:$SECONDARY_INSTALL_DIR"; do
    local cluster="${entry%%:*}"
    local dir="${entry##*:}"
    local kubeconfig="$dir/auth/kubeconfig"
    [[ -f "$kubeconfig" ]] || continue

    log " Waiting for c5n.metal node on $cluster (up to 30 min)..."
    local tries=0
    while [[ $tries -lt 60 ]]; do
      local ready
      ready=$(KUBECONFIG="$kubeconfig" oc get nodes \
        -l node.kubernetes.io/instance-type=c5n.metal \
        --no-headers 2>/dev/null | grep -c " Ready " || true)
      [[ "$ready" -ge 1 ]] && { log " c5n.metal node is Ready on $cluster."; break; }
      sleep 30
      tries=$((tries + 1))
    done
    [[ $tries -ge 60 ]] && \
      warn " Timeout waiting for c5n.metal node on $cluster � ODF may need manual intervention."

    log " Labeling worker nodes for ODF storage on $cluster..."
    while IFS= read -r node; do
      KUBECONFIG="$kubeconfig" oc label "$node" \
        cluster.ocs.openshift.io/openshift-storage="" --overwrite 2>/dev/null || true
    done < <(KUBECONFIG="$kubeconfig" oc get nodes \
      -l node-role.kubernetes.io/worker -o name 2>/dev/null)
    log " All workers labeled for ODF on $cluster."
  done
}

scale_hub_workers() {
  log "Scaling hub workers to 6 (required for ODF)..."
  export KUBECONFIG="$HUB_INSTALL_DIR/auth/kubeconfig"
  for ms in $(oc get machinesets.machine.openshift.io -n openshift-machine-api -o name 2>/dev/null); do
    oc scale "$ms" --replicas=2 -n openshift-machine-api 2>/dev/null
  done

  log "Waiting for workers to be Ready..."
  local tries=0
  while [[ $tries -lt 30 ]]; do
    local ready
    ready=$(oc get nodes -l node-role.kubernetes.io/worker --no-headers 2>/dev/null | grep -c " Ready " || true)
    if [[ "$ready" -ge 5 ]]; then
      log " $ready workers Ready."
      break
    fi
    log " $ready/6 workers Ready, waiting..."
    sleep 30
    tries=$((tries + 1))
  done

  log "Labeling workers for ODF storage..."
  for node in $(oc get nodes -l node-role.kubernetes.io/worker -o name 2>/dev/null); do
    oc label "$node" cluster.ocs.openshift.io/openshift-storage="" --overwrite 2>/dev/null
  done
}

store_spoke_kubeconfigs_in_vault() {
  log "[vault-kc] Storing spoke kubeconfigs in Vault..."
  export KUBECONFIG="$HUB_INSTALL_DIR/auth/kubeconfig"

  # Stage 1: wait for the vault-0 pod to be Running (up to 10 min).
  local tries=0
  log "[vault-kc] Waiting for vault-0 pod to be Running..."
  until oc get pod vault-0 -n vault --no-headers 2>/dev/null | grep -q " Running "; do
    [[ $tries -ge 40 ]] && { warn "[vault-kc] vault-0 pod not Running after 10 min -- skipping kubeconfig storage."; return 1; }
    sleep 15
    tries=$((tries + 1))
  done

  # Stage 2: wait for Vault to be initialised and unsealed (up to 20 min).
  tries=0
  log "[vault-kc] Waiting for Vault to be initialized and unsealed..."
  until oc exec -n vault vault-0 -- vault status 2>/dev/null | grep -q "Initialized.*true" && \
    oc exec -n vault vault-0 -- vault status 2>/dev/null | grep -q "Sealed.*false"; do
    [[ $tries -ge 80 ]] && { warn "[vault-kc] Vault not ready after 20 min -- skipping kubeconfig storage."; return 1; }
    sleep 15
    tries=$((tries + 1))
  done
  log "[vault-kc] Vault is ready."

  for entry in "ocp-primary:$PRIMARY_INSTALL_DIR" "ocp-secondary:$SECONDARY_INSTALL_DIR"; do
    local cluster="${entry%%:*}"
    local dir="${entry##*:}"
    local kc_file="$dir/auth/kubeconfig"
    [[ -f "$kc_file" ]] || { warn "[vault-kc] No kubeconfig at $kc_file -- skipping."; continue; }

    # Store the kubeconfig as-is, preserving certificate-authority-data.
    # Using insecure-skip-tls-verify instead of the real CA cert causes failures
    # in clients (e.g. Ansible kubernetes.core modules) that do not honour
    # that flag and perform TLS verification regardless.
    local vault_path="secret/hub/${cluster}_cluster_kubeconfig"
    local write_tries=0
    local stored=false
    while [[ $write_tries -lt 5 ]]; do
      if oc cp "$kc_file" "vault/vault-0:/tmp/${cluster}-kubeconfig.yaml" 2>/dev/null && \
        oc exec -n vault vault-0 -- \
          vault kv put "$vault_path" "kubeconfig=@/tmp/${cluster}-kubeconfig.yaml" 2>/dev/null; then
        oc exec -n vault vault-0 -- rm -f "/tmp/${cluster}-kubeconfig.yaml" 2>/dev/null || true
        log "[vault-kc] Stored kubeconfig for $cluster at $vault_path."
        stored=true
        break
      fi
      write_tries=$((write_tries + 1))
      warn "[vault-kc] Write attempt $write_tries/5 failed for $cluster -- retrying in 15s..."
      sleep 15
    done
    [[ "$stored" == "false" ]] && warn "[vault-kc] Failed to store kubeconfig for $cluster in Vault after 5 attempts."
  done
}

import_spoke_clusters() {
  # The regional-dr chart creates ClusterDeployments with installed:false, which
  # causes Hive to attempt provisioning and fail. Bypass that by creating an
  # auto-import-secret in each spoke namespace on the hub: ACM detects it and
  # deploys the klusterlet directly, with no Hive involvement.
  #
  # This function is idempotent and safe to call multiple times.
  log "[import] Creating auto-import-secret for spoke clusters..."
  local entries=(
    "ocp-primary:$PRIMARY_INSTALL_DIR"
    "ocp-secondary:$SECONDARY_INSTALL_DIR"
  )
  for entry in "${entries[@]}"; do
    local cluster="${entry%%:*}"
    local dir="${entry##*:}"
    local kc_file="$dir/auth/kubeconfig"

    if [[ ! -f "$kc_file" ]]; then
      warn "[import] No kubeconfig at $kc_file -- skipping $cluster."
      continue
    fi

    # Wait up to 20 min for ArgoCD to create the spoke namespace on the hub.
    # On a fresh install pattern.sh can take well over 10 min before regional-dr
    # syncs and the namespace appears; a short timeout causes silent skip which
    # leaves the spoke unregistered and blocks the odf-ssl-certificate-extractor job.
    # ensure_spoke_imports() acts as a safety net if this timeout is still exceeded.
    local tries=0
    until oc get namespace "$cluster" &>/dev/null || [[ $tries -ge 40 ]]; do
      tries=$((tries + 1))
      sleep 30
    done
    if ! oc get namespace "$cluster" &>/dev/null; then
      warn "[import] Namespace $cluster never appeared on hub after 20 min -- skipping auto-import."
      continue
    fi

    oc create secret generic auto-import-secret \
      -n "$cluster" \
      --from-file=kubeconfig="$kc_file" \
      --dry-run=client -o yaml \
      | oc apply -f - &>/dev/null \
      && log "[import] auto-import-secret created for $cluster." \
      || warn "[import] Failed to create auto-import-secret for $cluster (may already exist)."

    # Push the openshift-install kubeconfig into the spoke namespace under a
    # well-known name that sorts alphabetically before the ACM-generated secret
    # (ocp-primary-0-...-admin-kubeconfig). The odf-ssl-certificate-extractor
    # Ansible job picks the first matching secret; the ACM secret's CA does not
    # validate the spoke API server cert, but the openshift-install one does.
    _push_install_kubeconfig_to_namespace "$cluster" "$kc_file"
  done
}

_push_install_kubeconfig_to_namespace() {
  local cluster="$1" kc_file="$2"
  oc create secret generic admin-kubeconfig \
    -n "$cluster" \
    --from-file=kubeconfig="$kc_file" \
    --dry-run=client -o yaml \
    | oc apply -f - &>/dev/null \
    && log "[kc-push] admin-kubeconfig (install CA) created/updated for $cluster." \
    || warn "[kc-push] Failed to create admin-kubeconfig for $cluster."
}

ensure_spoke_imports() {
  # Safety-net: after pattern.sh returns, check whether each spoke is Joined
  # and create the auto-import-secret for any that are still missing.
  # Handles the race where import_spoke_clusters timed out waiting for the
  # spoke namespace to appear (namespace is always present by this point).
  log "[import] Verifying spoke cluster registration..."
  local entries=(
    "ocp-primary:$PRIMARY_INSTALL_DIR"
    "ocp-secondary:$SECONDARY_INSTALL_DIR"
  )
  local any_missing=false
  for entry in "${entries[@]}"; do
    local cluster="${entry%%:*}"
    local dir="${entry##*:}"
    local kc_file="$dir/auth/kubeconfig"

    local joined
    joined=$(oc get managedcluster "$cluster" \
      -o jsonpath='{.status.conditions[?(@.type=="ManagedClusterJoined")].status}' 2>/dev/null)
    if [[ "$joined" == "True" ]]; then
      log "[import] $cluster is already Joined -- nothing to do."
      continue
    fi

    log "[import] $cluster is not Joined -- creating auto-import-secret now..."
    any_missing=true
    if [[ ! -f "$kc_file" ]]; then
      warn "[import] No kubeconfig at $kc_file -- cannot import $cluster."
      continue
    fi
    if ! oc get namespace "$cluster" &>/dev/null; then
      warn "[import] Namespace $cluster does not exist on hub -- cannot import $cluster."
      continue
    fi
    oc create secret generic auto-import-secret \
      -n "$cluster" \
      --from-file=kubeconfig="$kc_file" \
      --dry-run=client -o yaml \
      | oc apply -f - \
      && log "[import] auto-import-secret created for $cluster." \
      || warn "[import] Failed to create auto-import-secret for $cluster."

    _push_install_kubeconfig_to_namespace "$cluster" "$kc_file"
  done
  if [[ "$any_missing" == "true" ]]; then
    log "[import] Waiting 60 s for klusterlet agents to register..."
    sleep 60
    oc get managedcluster ocp-primary ocp-secondary \
      -o custom-columns='NAME:.metadata.name,JOINED:.status.conditions[?(@.type=="ManagedClusterJoined")].status,AVAILABLE:.status.conditions[?(@.type=="ManagedClusterConditionAvailable")].status' \
      2>/dev/null || true
  fi
}

fix_cluster_deployments_for_byoc() {
  # The regional-dr Helm chart creates ClusterDeployment objects with spec fields
  # sourced from Helm values that do NOT necessarily match the real cluster state:
  #
  #   spec.clusterMetadata.infraID — set by Hive during its own (failed) provision
  #     attempt, which assigns a different random suffix than openshift-install used.
  #
  #   spec.platform.aws.region — comes from the upstream Helm defaults (e.g.
  #     us-west-1 / us-east-1) rather than the actual deployed regions.
  #
  # The submariner-sg-tagger Ansible job reads these fields first (ClusterDeployment
  # Method 1 in the script) and therefore:
  #   • searches for the Submariner AWS security group using the wrong infraID, AND
  #   • queries the wrong AWS region — finding nothing in both cases.
  # The job fails with BackoffLimitExceeded, which blocks ArgoCD sync wave 8 and
  # prevents all downstream resources (odf-ramen-trusted-ca, DRPlacementControl,
  # edge-gitops-vms ConfigMap, …) from ever being created — VMs are never deployed.
  #
  # Fix: patch both fields with the authoritative values before the sg-tagger job
  # first runs.  infraID comes from openshift-install's metadata.json; region comes
  # from the PRIMARY_REGION / SECONDARY_REGION variables already used elsewhere in
  # this script.  If the job already failed we also delete it so ArgoCD recreates it.
  log "[byoc-cd] Patching ClusterDeployment infraID+region with real installed values..."
  export KUBECONFIG="$HUB_INSTALL_DIR/auth/kubeconfig"

  local -A CLUSTER_REGION=(
    [ocp-primary]="$PRIMARY_REGION"
    [ocp-secondary]="$SECONDARY_REGION"
  )
  local -A CLUSTER_DIR=(
    [ocp-primary]="$PRIMARY_INSTALL_DIR"
    [ocp-secondary]="$SECONDARY_INSTALL_DIR"
  )

  local any_patched=false

  for cluster in ocp-primary ocp-secondary; do
    local dir="${CLUSTER_DIR[$cluster]}"
    local real_region="${CLUSTER_REGION[$cluster]}"
    local metadata_file="$dir/metadata.json"

    if [[ ! -f "$metadata_file" ]]; then
      warn "[byoc-cd] No metadata.json for $cluster at $metadata_file -- skipping."
      continue
    fi

    local real_infra_id
    real_infra_id=$(python3 -c "import json; print(json.load(open('$metadata_file'))['infraID'])" 2>/dev/null || echo "")
    if [[ -z "$real_infra_id" ]]; then
      warn "[byoc-cd] Could not read infraID from $metadata_file -- skipping $cluster."
      continue
    fi

    # Wait up to 10 min for the ClusterDeployment to be created by ArgoCD.
    local tries=0
    until oc get clusterdeployment "$cluster" -n "$cluster" &>/dev/null || [[ $tries -ge 20 ]]; do
      tries=$((tries + 1))
      sleep 30
    done
    if ! oc get clusterdeployment "$cluster" -n "$cluster" &>/dev/null; then
      warn "[byoc-cd] ClusterDeployment/$cluster not found after 10 min -- skipping."
      continue
    fi

    local current_infra_id current_region
    current_infra_id=$(oc get clusterdeployment "$cluster" -n "$cluster" \
      -o jsonpath='{.spec.clusterMetadata.infraID}' 2>/dev/null || echo "")
    current_region=$(oc get clusterdeployment "$cluster" -n "$cluster" \
      -o jsonpath='{.spec.platform.aws.region}' 2>/dev/null || echo "")

    local need_patch=false
    [[ "$current_infra_id" != "$real_infra_id" ]] && need_patch=true
    [[ "$current_region"   != "$real_region"   ]] && need_patch=true

    if [[ "$need_patch" == "false" ]]; then
      log "[byoc-cd] $cluster ClusterDeployment already correct (infraID=$real_infra_id region=$real_region)"
      continue
    fi

    log "[byoc-cd] Patching $cluster: infraID $current_infra_id→$real_infra_id  region $current_region→$real_region"
    if oc patch clusterdeployment "$cluster" -n "$cluster" \
      --type='merge' \
      -p "{\"spec\":{\"clusterMetadata\":{\"infraID\":\"$real_infra_id\"},\"platform\":{\"aws\":{\"region\":\"$real_region\"}}}}" \
      &>/dev/null; then
      log "[byoc-cd] $cluster ClusterDeployment patched."
      any_patched=true
    else
      warn "[byoc-cd] Failed to patch $cluster ClusterDeployment."
    fi
  done

  # If we patched anything and submariner-sg-tagger already hit BackoffLimitExceeded,
  # delete it so ArgoCD recreates it on its next sync with the corrected values.
  if [[ "$any_patched" == "true" ]]; then
    local job_status
    job_status=$(oc get job submariner-sg-tagger -n open-cluster-management \
      -o jsonpath='{.status.conditions[?(@.type=="Failed")].reason}' 2>/dev/null || echo "")
    if [[ "$job_status" == "BackoffLimitExceeded" ]]; then
      log "[byoc-cd] Deleting failed submariner-sg-tagger job so ArgoCD recreates it..."
      oc delete job submariner-sg-tagger -n open-cluster-management &>/dev/null || true
      oc patch applications.argoproj.io/regional-dr -n ramendr-starter-kit-hub \
        --type merge \
        -p '{"operation":{"initiatedBy":{"username":"redeploy-sh"},"sync":{}}}' \
        &>/dev/null || true
      log "[byoc-cd] regional-dr sync triggered."
    fi
  fi
}

deploy_pattern() {
  log "Deploying RamenDR pattern (upstream pinned, local overrides applied)..."
  export KUBECONFIG="$HUB_INSTALL_DIR/auth/kubeconfig"

  # Store spoke kubeconfigs while the pattern install runs, to avoid ExternalSecrets caching failures.
  store_spoke_kubeconfigs_in_vault &
  local store_pid=$!

  # Create auto-import-secret for each spoke concurrently with pattern.sh.
  # It waits for ArgoCD to create the spoke namespaces on the hub, then creates
  # the secret so ACM can import the klusterlet without relying on Hive.
  import_spoke_clusters &
  local import_pid=$!

  log "Running upstream pattern install (this takes time for operators to settle)..."
  (
    cd "$UPSTREAM_DIR"
    VALUES_SECRET="$VALUES_SECRET" ./pattern.sh make install 2>&1 || warn "Pattern install exited with warnings (expected during first sync)"
  )

  if ! wait "$store_pid"; then
    warn "store_spoke_kubeconfigs_in_vault background job failed -- retrying synchronously..."
    store_spoke_kubeconfigs_in_vault || true
  fi

  # Kill the background import job if it is still running (pattern.sh has returned,
  # namespace wait no longer makes sense to continue in background).
  kill "$import_pid" 2>/dev/null || true
  wait "$import_pid" 2>/dev/null || true

  # Always run the safety-net check synchronously after pattern.sh returns.
  # This catches any spoke that was skipped because the namespace appeared after
  # the background job's per-cluster timeout.
  ensure_spoke_imports

  # Patch ClusterDeployment infraID + region to match the real installed values.
  # Must run after ensure_spoke_imports so the ClusterDeployments exist on the hub.
  fix_cluster_deployments_for_byoc

  log "Force-refreshing kubeconfig ExternalSecrets..."
  for cluster in ocp-primary ocp-secondary; do
    oc annotate externalsecret -n "$cluster" --all \
      force-sync="$(date +%s)" --overwrite 2>/dev/null || true
  done
}

wait_for_convergence() {
  log "Waiting for environment convergence (ArgoCD Applications)..."
  export KUBECONFIG="$HUB_INSTALL_DIR/auth/kubeconfig"

  local tries=0
  while [[ $tries -lt 120 ]]; do
    local unhealthy
    unhealthy=$(oc get applications.argoproj.io -n ramendr-starter-kit-hub \
      -o custom-columns=':.status.sync.status,:.status.health.status' --no-headers 2>/dev/null \
      | grep -v "Synced.*Healthy" | grep -v "Synced.*Progressing" | wc -l | tr -d ' ')

    if [[ "$unhealthy" -eq 0 ]]; then
      log "All ArgoCD applications are Synced/Healthy!"
      break
    fi

    log " $unhealthy apps still converging (attempt $tries/120)..."
    sleep 60
    tries=$((tries + 1))

    if [[ $((tries % 10)) -eq 0 ]]; then
      for app in regional-dr opp-policy; do
        oc patch applications.argoproj.io "$app" -n ramendr-starter-kit-hub --type merge \
          -p '{"operation":{"initiatedBy":{"automated":true},"sync":{}}}' 2>/dev/null || true
      done

      # Recovery: if submariner-sg-tagger hit BackoffLimitExceeded (wrong infraID),
      # fix_cluster_deployment_infra_ids may not have caught it in time (e.g. on
      # --pattern-only runs where metadata.json is already present).  Re-run the
      # fix here as a belt-and-suspenders safety net.
      local sg_tagger_status
      sg_tagger_status=$(oc get job submariner-sg-tagger -n open-cluster-management \
        -o jsonpath='{.status.conditions[?(@.type=="Failed")].reason}' 2>/dev/null || echo "")
      if [[ "$sg_tagger_status" == "BackoffLimitExceeded" ]]; then
        warn "[convergence] submariner-sg-tagger BackoffLimitExceeded — re-running BYOC CD fix..."
        fix_cluster_deployments_for_byoc
      fi
    fi
  done
}

show_status() {
  export KUBECONFIG="$HUB_INSTALL_DIR/auth/kubeconfig"
  echo ""
  echo "============================================"
  echo " RamenDR Starter Kit � Environment Status"
  echo "============================================"
  echo ""
  echo "--- Clusters ---"
  oc get managedclusters 2>&1 || echo "Cannot reach hub cluster"
  echo ""
  echo "--- ArgoCD Applications ---"
  oc get applications.argoproj.io -n ramendr-starter-kit-hub \
    -o custom-columns='NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status' 2>&1
  echo ""
  echo "--- DR Status ---"
  oc get drpolicy 2>&1 || true
  oc get drplacementcontrol -A 2>&1 || true
  echo ""
  echo "--- Access ---"
  echo "Hub Console: https://console-openshift-console.apps.hub.${BASE_DOMAIN}"
  echo "KUBECONFIG: $HUB_INSTALL_DIR/auth/kubeconfig"
  echo ""
}

full_redeploy() {
  check_prerequisites
  prepare_upstream

  cleanup_dns
  release_orphaned_eips

  destroy_managed_clusters
  destroy_hub
  cleanup_dns

  log "Starting parallel install of hub + ocp-primary + ocp-secondary..."
  install_hub &
  install_spokes &
  wait
  log "All three clusters installed."

  create_spoke_metal_machinesets
  scale_hub_workers
  wait_for_spoke_metal_nodes

  deploy_pattern
  wait_for_convergence
  show_status
  log "Full redeploy complete!"
}

case "${1:-}" in
  --destroy-only)
    check_prerequisites
    destroy_managed_clusters
    destroy_hub
    cleanup_dns
    release_orphaned_eips
    log "Environment destroyed."
    ;;
  --pattern-only)
    check_prerequisites
    prepare_upstream
    create_spoke_metal_machinesets
    scale_hub_workers
    wait_for_spoke_metal_nodes
    deploy_pattern
    wait_for_convergence
    show_status
    ;;
  --status)
    show_status
    ;;
  --help|-h)
    echo "Usage: ./scripts/redeploy.sh [--destroy-only|--pattern-only|--status|--help]"
    echo ""
    echo " (no args) Full redeploy: destroy + install all 3 clusters in parallel + deploy pinned upstream pattern"
    echo " --destroy-only Destroy all clusters and clean up AWS resources"
    echo " --pattern-only Deploy pattern on an existing hub cluster"
    echo " --status Show current environment status"
    echo ""
    echo "Pinning:"
    echo " UPSTREAM_REPO           Upstream repo URL (default: $UPSTREAM_REPO)"
    echo " UPSTREAM_REF            Upstream git ref (default: $UPSTREAM_REF)"
    echo " UPSTREAM_OVERRIDES_DIR  Dir containing values-hub.patch (default: $UPSTREAM_OVERRIDES_DIR)"
    echo ""
    echo "Environment variables:"
    echo " HUB_INSTALL_DIR       Hub cluster install directory (default: ~/git/hub-cluster-install)"
    echo " PRIMARY_INSTALL_DIR   Primary spoke install directory (default: ~/git/ocp-primary-install)"
    echo " SECONDARY_INSTALL_DIR Secondary spoke install directory (default: ~/git/ocp-secondary-install)"
    echo " VALUES_SECRET         Path to values-secret.yaml (default: ~/values-secret.yaml)"
    echo " HUB_OCP_VERSION       OCP version for all clusters (default: 4.20.6)"
    echo " HOSTED_ZONE_ID        Route53 hosted zone ID"
    echo " BASE_DOMAIN           Base domain for the clusters (required, no default)"
    ;;
  *)
    full_redeploy
    ;;
esac

