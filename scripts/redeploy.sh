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

UPSTREAM_REPO="${UPSTREAM_REPO:-https://github.com/elsapassaro/ramendr-starter-kit}"
UPSTREAM_REF="${UPSTREAM_REF:-c025108811561fef71b59f797123d9e1066d93b0}"
# Branch name used to avoid detached-HEAD when UPSTREAM_REF is a bare SHA.
# The upstream pattern's Makefile derives target_branch from git and fails if HEAD is detached.
UPSTREAM_BRANCH="${UPSTREAM_BRANCH:-v1.1}"

WORK_DIR="${WORK_DIR:-$REPO_ROOT/.work}"
UPSTREAM_DIR="${UPSTREAM_DIR:-$WORK_DIR/upstream/ramendr-starter-kit}"

HUB_INSTALL_DIR="${HUB_INSTALL_DIR:-$HOME/git/hub-cluster-install}"
PRIMARY_INSTALL_DIR="${PRIMARY_INSTALL_DIR:-$HOME/git/ocp-primary-install}"
SECONDARY_INSTALL_DIR="${SECONDARY_INSTALL_DIR:-$HOME/git/ocp-secondary-install}"

VALUES_SECRET="${VALUES_SECRET:-$HOME/values-secret.yaml}"

HOSTED_ZONE_ID="${HOSTED_ZONE_ID:-}"
BASE_DOMAIN="${BASE_DOMAIN:-}"
# Set CLEANUP_DNS=1 to opt into bulk Route53 record deletion in the public hosted zone.
# Default preserves the hosted zone and its records across redeploys.
CLEANUP_DNS="${CLEANUP_DNS:-0}"

HUB_REGION="${HUB_REGION:-eu-north-1}"
PRIMARY_REGION="${PRIMARY_REGION:-eu-central-1}"
SECONDARY_REGION="${SECONDARY_REGION:-eu-west-1}"

# Target OCP version for all clusters � hub + spokes should use the same minor version
# to avoid ODF Multicluster Orchestrator incompatibilities.
HUB_OCP_VERSION="${HUB_OCP_VERSION:-4.21.14}"

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

  local account_id
  account_id=$(current_aws_account_id) || { err "Cannot determine AWS account (check credentials)."; exit 1; }
  log "Using AWS account: $account_id"

  if ! verify_hosted_zone_in_account; then
    err "HOSTED_ZONE_ID ($HOSTED_ZONE_ID) is not accessible in the current AWS account."
    exit 1
  fi
  log "Route53 hosted zone $HOSTED_ZONE_ID verified in current account (zone will be preserved)."
  log "All prerequisites met."
}

current_aws_account_id() {
  aws sts get-caller-identity --query Account --output text 2>/dev/null
}

verify_hosted_zone_in_account() {
  [[ -n "$HOSTED_ZONE_ID" ]] || return 1
  aws route53 get-hosted-zone --id "$HOSTED_ZONE_ID" \
    --query 'HostedZone.Id' --output text &>/dev/null
}

read_cluster_metadata() {
  local dir="$1"
  local meta="$dir/metadata.json"
  [[ -f "$meta" ]] || return 1
  python3 -c "
import json, sys
d = json.load(open('$meta'))
print(d.get('infraID', ''))
print(d.get('aws', {}).get('region', ''))
" 2>/dev/null
}

cluster_infra_exists() {
  local infra_id="$1"
  local region="$2"
  [[ -n "$infra_id" && -n "$region" ]] || return 1

  local vpc_count
  vpc_count=$(aws ec2 describe-vpcs \
    --region "$region" \
    --filters "Name=tag:kubernetes.io/cluster/${infra_id},Values=owned" \
    --query 'length(Vpcs)' \
    --output text 2>/dev/null || echo "")
  [[ "$vpc_count" =~ ^[1-9][0-9]*$ ]]
}

cluster_install_dirs() {
  echo "hub:$HUB_INSTALL_DIR"
  echo "ocp-primary:$PRIMARY_INSTALL_DIR"
  echo "ocp-secondary:$SECONDARY_INSTALL_DIR"
}

clusters_with_infra_in_account() {
  local entry name dir meta infra_id region
  while IFS= read -r entry; do
    name="${entry%%:*}"
    dir="${entry#*:}"
    meta=$(read_cluster_metadata "$dir") || continue
    infra_id=$(echo "$meta" | sed -n '1p')
    region=$(echo "$meta" | sed -n '2p')
    if cluster_infra_exists "$infra_id" "$region"; then
      echo "$name:$dir:$infra_id:$region"
    fi
  done < <(cluster_install_dirs)
}

ensure_podman_ready() {
  # pattern.sh runs the utility container via podman. On macOS the binary can exist
  # while the podman machine VM is stopped (common after long cluster installs).
  if podman info &>/dev/null; then
    return 0
  fi

  warn "Podman is installed but not reachable (daemon/VM may be stopped)."

  if [[ "$(uname -s)" == "Darwin" ]] && command -v podman &>/dev/null; then
    local machine
    machine=$(podman machine list --format '{{.Name}}' 2>/dev/null | head -1 || true)
    if [[ -n "$machine" ]]; then
      log "Starting podman machine ${machine}..."
      if podman machine start "$machine" &>/dev/null; then
        sleep 3
        podman info &>/dev/null && { log "Podman is ready."; return 0; }
      fi
    fi
    err "Start Podman manually, then re-run: podman machine start"
    err "Or install the helper: sudo podman-mac-helper install && podman machine start"
    return 1
  fi

  err "Podman is not running. Start the Podman service/socket, then re-run deploy."
  return 1
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
    # Use `checkout -B` so HEAD lands on a named local branch even when UPSTREAM_REF
    # is a bare commit SHA. Without a branch name the upstream pattern's Makefile
    # cannot derive target_branch and aborts with "Could not determine target branch".
    git checkout -B "$UPSTREAM_BRANCH" "$UPSTREAM_REF"
  )

  # Patch upstream pattern.sh for automation (non-TTY) and Apple Silicon (amd64 container).
  if [[ -f "$UPSTREAM_DIR/pattern.sh" ]]; then
    log "Patching upstream pattern.sh for automation and platform compatibility..."
    (
      cd "$UPSTREAM_DIR"
      python3 - <<'PY'
from pathlib import Path

path = Path("pattern.sh")
text = path.read_text()

# 1) Non-TTY: replace stock podman invocation if not already patched.
if "PODMAN_STDIO_ARGS" not in text:
    needle = "podman run -it --rm --pull=newer \\"
    replacement = """# Podman requires a TTY for `-t`; CI and some automation shells have no TTY. Use `-i` only then.
PODMAN_STDIO_ARGS=(-it)
if [[ ! -t 0 ]] || [[ ! -t 1 ]]; then
 PODMAN_STDIO_ARGS=(-i)
fi

podman run "${PODMAN_STDIO_ARGS[@]}" --rm --pull=newer \\"""
    if needle in text:
        text = text.replace(needle, replacement)

# 2) Apple Silicon: utility-container is amd64; native arm64 pull causes "Illegal instruction".
if "PODMAN_PLATFORM_ARGS" not in text:
    platform_block = """# utility-container is amd64-only; run under emulation on Darwin arm64.
PODMAN_PLATFORM_ARGS=()
if [[ "$(uname -s)" == "Darwin" && "$(uname -m)" == "arm64" ]]; then
 PODMAN_PLATFORM_ARGS=(--platform linux/amd64)
fi

"""
    run_needle = 'podman run "${PODMAN_STDIO_ARGS[@]}" --rm --pull=newer \\'
    run_replacement = (
        platform_block
        + 'podman run "${PODMAN_STDIO_ARGS[@]}" "${PODMAN_PLATFORM_ARGS[@]}" --rm --pull=newer \\'
    )
    if run_needle in text:
        text = text.replace(run_needle, run_replacement)
    else:
        run_needle = "podman run --rm --pull=newer \\"
        if run_needle in text:
            text = text.replace(
                run_needle,
                platform_block + 'podman run "${PODMAN_PLATFORM_ARGS[@]}" --rm --pull=newer \\',
            )

path.write_text(text)
PY
    )
  fi
}

cleanup_dns() {
  if [[ "$CLEANUP_DNS" != "1" ]]; then
    log "Skipping Route53 record cleanup (hosted zone preserved; set CLEANUP_DNS=1 to enable)."
    return 0
  fi
  log "Cleaning stale DNS records from Route53 (CLEANUP_DNS=1)..."
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

release_cluster_orphaned_eips() {
  log "Releasing unassociated Elastic IPs owned by installed clusters..."
  local entry name dir infra_id region rest released=0
  while IFS= read -r entry; do
    name="${entry%%:*}"
    rest="${entry#*:}"
    region="${rest##*:}"
    rest="${rest%:"$region"}"
    infra_id="${rest##*:}"
    dir="${rest%:"$infra_id"}"

    local eips
    eips=$(aws ec2 describe-addresses --region "$region" \
      --filters \
        "Name=tag:kubernetes.io/cluster/${infra_id},Values=owned" \
        "Name=domain,Values=vpc" \
      --query 'Addresses[?AssociationId==null].AllocationId' \
      --output text 2>/dev/null | tr '\t' ' ')
    for eip in $eips; do
      [[ -z "$eip" || "$eip" == "None" ]] && continue
      aws ec2 release-address --region "$region" --allocation-id "$eip" 2>/dev/null \
        && log " Released cluster EIP $eip for $name ($infra_id) in $region" \
        && released=$((released + 1))
    done
  done < <(clusters_with_infra_in_account)
  if [[ "$released" -eq 0 ]]; then
    log "No unassociated cluster-owned EIPs found."
  fi
}

destroy_cluster() {
  local name="$1"
  local dir="$2"

  if [[ ! -f "$dir/metadata.json" ]]; then
    warn "No metadata found for $name -- skipping (not installed in this workspace)."
    return
  fi

  local infra_id region
  infra_id=$(python3 -c "import json; print(json.load(open('$dir/metadata.json'))['infraID'])" 2>/dev/null || echo "")
  region=$(python3 -c "import json; print(json.load(open('$dir/metadata.json'))['aws']['region'])" 2>/dev/null || echo "")

  if [[ -z "$infra_id" || -z "$region" ]]; then
    warn "Incomplete metadata for $name -- skipping destroy."
    return
  fi

  if ! cluster_infra_exists "$infra_id" "$region"; then
    log "$name has no VPC in the current AWS account ($infra_id in $region) -- skipping destroy."
    return
  fi

  log "Destroying $name cluster in current AWS account ($infra_id in $region)..."
  log "Public Route53 hosted zone $HOSTED_ZONE_ID will be preserved (cluster DNS records may still be removed by openshift-install)."
  openshift-install destroy cluster --dir "$dir" --log-level=info 2>&1 \
    || warn "$name destroy had errors (may already be destroyed)"
}

destroy_existing_clusters() {
  local account_id found=0 entry name dir infra_id region rest hub_dir=""
  local -a spoke_pids=()
  account_id=$(current_aws_account_id || echo "unknown")
  log "Destroying only clusters with live infrastructure in AWS account $account_id..."

  while IFS= read -r entry; do
    found=1
    name="${entry%%:*}"
    rest="${entry#*:}"
    region="${rest##*:}"
    rest="${rest%:"$region"}"
    infra_id="${rest##*:}"
    dir="${rest%:"$infra_id"}"
    if [[ "$name" == "hub" ]]; then
      hub_dir="$dir"
    else
      destroy_cluster "$name" "$dir" &
      spoke_pids+=($!)
    fi
  done < <(clusters_with_infra_in_account)

  if [[ "$found" -eq 0 ]]; then
    log "No cluster infrastructure found in the current AWS account -- nothing to destroy."
    return
  fi

  if [[ ${#spoke_pids[@]} -gt 0 ]]; then
    wait "${spoke_pids[@]}"
  fi
  if [[ -n "$hub_dir" ]]; then
    destroy_cluster "hub" "$hub_dir"
  fi
  log "Cluster destroy pass complete."
}

_openshift_install_tarball() {
  local want="$1"
  local os_name arch_suffix=""
  case "$(uname -s)" in
    Darwin) os_name=mac ;;
    Linux) os_name=linux ;;
    *)
      err "Unsupported OS for openshift-install: $(uname -s)"
      return 1
      ;;
  esac
  case "$(uname -m)" in
    arm64 | aarch64) arch_suffix="-arm64" ;;
    x86_64 | amd64) ;;
    *)
      err "Unsupported CPU arch for openshift-install: $(uname -m)"
      return 1
      ;;
  esac
  echo "openshift-install-${os_name}${arch_suffix}-${want}.tar.gz"
}

ensure_openshift_install_version() {
  local want="$HUB_OCP_VERSION"
  local got
  got=$(openshift-install version 2>/dev/null | awk 'NR==1{print $2}')
  if [[ "$got" == "$want" ]] && openshift-install version &>/dev/null; then
    log "openshift-install is already at $want."
    return 0
  fi
  log "openshift-install is at '$got', need $want � downloading..."
  local tarball
  tarball=$(_openshift_install_tarball "$want") || return 1
  local url="https://mirror.openshift.com/pub/openshift-v4/clients/ocp/${want}/${tarball}"
  local tmp
  tmp=$(mktemp -d)
  curl -fsSL "$url" -o "$tmp/openshift-install.tar.gz"
  tar -xzf "$tmp/openshift-install.tar.gz" -C "$tmp" openshift-install
  chmod +x "$tmp/openshift-install"
  local install_dir
  install_dir=$(dirname "$(command -v openshift-install 2>/dev/null || echo "$HOME/.local/bin/openshift-install")")
  mkdir -p "$install_dir"
  mv "$tmp/openshift-install" "$install_dir/openshift-install"
  rm -rf "$tmp"
  log "openshift-install $want installed to $install_dir (${tarball})."
}

install_one_cluster() {
  local name="$1"
  local dir="$2"
  log "Installing $name cluster..."
  cd "$dir"
  rm -rf .clusterapi_output .openshift_install.log .openshift_install_state.json \
    auth metadata.json terraform* 2>/dev/null || true
  cp install-config.yaml.bak install-config.yaml
  if ! openshift-install create cluster --dir . --log-level=info 2>&1; then
    err "$name cluster install failed (see $dir/.openshift_install.log)"
    return 1
  fi
  log "$name cluster installed."
}

install_hub() {
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
  local primary_pid secondary_pid failed=0
  install_one_cluster "ocp-primary" "$PRIMARY_INSTALL_DIR" &
  primary_pid=$!
  install_one_cluster "ocp-secondary" "$SECONDARY_INSTALL_DIR" &
  secondary_pid=$!
  wait "$primary_pid" || failed=1
  wait "$secondary_pid" || failed=1
  [[ "$failed" -eq 0 ]]
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

prepull_odf_images() {
  # Pre-pull the large ODF CSI image (~1.4 GB) on all hub workers before ArgoCD
  # deploys ODF DaemonSets. Concurrent pulls from registry.redhat.io across 6 nodes
  # frequently stall TCP connections on 1-2 nodes, blocking Nooba initialization
  # for hours (AWS NAT gateway 350s idle TCP timeout kills long-running downloads).
  # The image is pulled into each node's local cache here so the ODF DaemonSet
  # finds it already present (imagePullPolicy: IfNotPresent skips the pull).
  log "Pre-pulling ODF CSI image on all hub workers (prevents concurrent-pull stalls)..."
  export KUBECONFIG="$HUB_INSTALL_DIR/auth/kubeconfig"

  local image="registry.redhat.io/odf4/cephcsi-rhel9:latest"
  local ns="odf-prepull"

  # Use a temporary namespace so this works before openshift-storage exists.
  oc create namespace "$ns" 2>/dev/null || true

  oc apply -n "$ns" -f - <<EOF
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: odf-image-prepull
  namespace: ${ns}
  labels:
    app: odf-image-prepull
spec:
  selector:
    matchLabels:
      app: odf-image-prepull
  template:
    metadata:
      labels:
        app: odf-image-prepull
    spec:
      nodeSelector:
        node-role.kubernetes.io/worker: ""
      tolerations:
        - operator: Exists
      initContainers:
        - name: pull
          image: ${image}
          command: ["/bin/true"]
          imagePullPolicy: IfNotPresent
      containers:
        - name: done
          image: registry.access.redhat.com/ubi9/ubi-minimal:latest
          command: ["sleep", "infinity"]
          imagePullPolicy: IfNotPresent
      terminationGracePeriodSeconds: 5
EOF

  log "Waiting up to 20 min for ODF image pre-pull to complete on all nodes..."
  local tries=0
  while [[ $tries -lt 40 ]]; do
    local desired ready
    desired=$(oc get daemonset odf-image-prepull -n "$ns" \
      -o jsonpath='{.status.desiredNumberScheduled}' 2>/dev/null || echo 0)
    ready=$(oc get daemonset odf-image-prepull -n "$ns" \
      -o jsonpath='{.status.numberReady}' 2>/dev/null || echo 0)
    if [[ "$desired" -gt 0 && "$ready" -ge "$desired" ]]; then
      log "ODF image pre-pull complete on all $ready nodes."
      break
    fi
    # Restart pods stuck in ContainerCreating for >5 min (stalled pull).
    oc get pods -n "$ns" -l app=odf-image-prepull --no-headers 2>/dev/null \
      | awk '$4~/^([5-9]|[1-9][0-9]+)m/ && $3=="ContainerCreating" {print $1}' \
      | xargs -r oc delete pod -n "$ns" 2>/dev/null || true
    log "  $ready/$desired nodes ready (attempt $((tries+1))/40)..."
    sleep 30
    tries=$((tries + 1))
  done

  oc delete namespace "$ns" --wait=false 2>/dev/null || true
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

  # Pre-pull the large ODF CSI image on every hub node before ArgoCD deploys the
  # ODF DaemonSets. Without this, all 6 nodes pull the ~1.4 GB cephcsi image
  # simultaneously; nodes that get slow/stalled TCP connections to registry.redhat.io
  # can hang for hours, blocking Nooba and downstream apps (opp-policy, regional-dr).
  prepull_odf_images
}

finalize_byoc_cluster_deployments() {
  # BYOC: clusters are already installed. Hive may still run provision jobs when
  # private-key secrets appear; mark deployments installed from openshift-install metadata.
  export KUBECONFIG="$HUB_INSTALL_DIR/auth/kubeconfig"
  local entries=(
    "ocp-primary:$PRIMARY_INSTALL_DIR"
    "ocp-secondary:$SECONDARY_INSTALL_DIR"
  )
  for entry in "${entries[@]}"; do
    local cluster="${entry%%:*}"
    local dir="${entry##*:}"
    local meta="$dir/metadata.json"
    [[ -f "$meta" ]] || continue
    oc get clusterdeployment "$cluster" -n "$cluster" &>/dev/null || continue

    local cluster_id infra_id region
    cluster_id=$(python3 -c "import json; print(json.load(open('$meta'))['clusterID'])" 2>/dev/null) || continue
    infra_id=$(python3 -c "import json; print(json.load(open('$meta'))['infraID'])" 2>/dev/null) || continue
    region=$(python3 -c "import json; print(json.load(open('$meta'))['aws']['region'])" 2>/dev/null) || continue

    oc patch clusterdeployment "$cluster" -n "$cluster" --type merge -p "{
      \"spec\": {
        \"installed\": true,
        \"clusterMetadata\": {
          \"clusterID\": \"${cluster_id}\",
          \"infraID\": \"${infra_id}\"
        },
        \"platform\": {
          \"aws\": {
            \"region\": \"${region}\"
          }
        }
      }
    }" &>/dev/null || warn "[byoc] Could not patch ClusterDeployment $cluster."

    oc delete job -n "$cluster" -l "hive.openshift.io/cluster-deployment-name=${cluster}" --ignore-not-found &>/dev/null || true
    log "[byoc] ClusterDeployment $cluster marked installed (clusterID ${cluster_id})."
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

    _ensure_managedcluster_registered "$cluster"

    # Push the openshift-install kubeconfig into the spoke namespace under a
    # well-known name that sorts alphabetically before the ACM-generated secret
    # (ocp-primary-0-...-admin-kubeconfig). The odf-ssl-certificate-extractor
    # Ansible job picks the first matching secret; the ACM secret's CA does not
    # validate the spoke API server cert, but the openshift-install one does.
    _push_install_kubeconfig_to_namespace "$cluster" "$kc_file"
  done
}

_ensure_managedcluster_registered() {
  local cluster="$1"
  if oc get managedcluster "$cluster" &>/dev/null; then
    return 0
  fi
  oc apply -f - <<EOF
apiVersion: cluster.open-cluster-management.io/v1
kind: ManagedCluster
metadata:
  name: ${cluster}
spec:
  hubAcceptsClient: true
EOF
  log "[import] Registered ManagedCluster ${cluster} for BYOC import."
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

    _ensure_managedcluster_registered "$cluster"
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


deploy_pattern() {
  ensure_podman_ready || exit 1
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

  # Run pattern.sh in the background so a parallel watcher can cut it short when only
  # known-stable drift remains, instead of waiting the full 60-minute convergence loop.
  ( cd "$UPSTREAM_DIR" && VALUES_SECRET="$VALUES_SECRET" ./pattern.sh make install 2>&1 ) &
  local pattern_pid=$!

  # Background watcher: once ALL apps except the two known-drift apps
  # (regional-dr and ramendr-starter-kit-hub) are Synced/Healthy, and those
  # two are Healthy for 3 consecutive 30-second checks, terminate pattern.sh early.
  _stable_drift_exit() {
    local pid=$1
    local consecutive=0
    while kill -0 "$pid" 2>/dev/null; do
      sleep 30
      [[ -n "${KUBECONFIG:-}" ]] || return
      local rdr_health hub_health other_bad
      rdr_health=$(oc get application.argoproj.io regional-dr \
        -n ramendr-starter-kit-hub \
        -o jsonpath='{.status.health.status}' 2>/dev/null || true)
      hub_health=$(oc get application.argoproj.io ramendr-starter-kit-hub \
        -n ramendr-starter-kit-hub \
        -o jsonpath='{.status.health.status}' 2>/dev/null || true)
      # Count apps that are neither Synced/Healthy nor one of the two known-drift apps.
      other_bad=$(oc get application.argoproj.io -A \
        -o jsonpath='{range .items[*]}{.metadata.name}|{.status.sync.status}|{.status.health.status}{"\n"}{end}' \
        2>/dev/null \
        | grep -v "^regional-dr|" \
        | grep -v "^ramendr-starter-kit-hub|" \
        | grep -cv "Synced|Healthy" || true)
      if [[ "$rdr_health" == "Healthy" ]] && [[ "$hub_health" == "Healthy" ]] \
          && [[ "${other_bad:-1}" == "0" ]]; then
        consecutive=$((consecutive + 1))
        log "[early-exit] Stable drift detected (attempt $consecutive/3): only regional-dr + hub are OutOfSync/Healthy."
        if [[ $consecutive -ge 3 ]]; then
          log "[early-exit] Cutting pattern.sh short — all other apps converged, known drift remains."
          kill "$pid" 2>/dev/null || true
          return
        fi
      else
        consecutive=0
      fi
    done
  }
  _stable_drift_exit "$pattern_pid" &
  local drift_exit_pid=$!

  local pattern_exit=0
  wait "$pattern_pid" || pattern_exit=$?
  kill "$drift_exit_pid" 2>/dev/null || true
  wait "$drift_exit_pid" 2>/dev/null || true

  if [[ $pattern_exit -ne 0 ]]; then
    # pattern.sh often times out (or is killed by our early-exit watcher) because
    # regional-dr and/or ramendr-starter-kit-hub are OutOfSync/Healthy — expected
    # drift that the fix-up functions below correct. Continue if both are Healthy;
    # only hard-exit for genuine install failures (no hub app, operators missing).
    warn "pattern.sh make install returned non-zero — checking whether this is recoverable drift..."
    local hub_health rdr_health
    hub_health=$(oc get application.argoproj.io ramendr-starter-kit-hub \
      -n ramendr-starter-kit-hub \
      -o jsonpath='{.status.health.status}' 2>/dev/null || true)
    rdr_health=$(oc get application.argoproj.io regional-dr \
      -n ramendr-starter-kit-hub \
      -o jsonpath='{.status.health.status}' 2>/dev/null || true)
    if [[ "$hub_health" == "Healthy" ]] || [[ "$rdr_health" == "Healthy" ]]; then
      warn "Hub health=${hub_health:-unknown}, regional-dr health=${rdr_health:-unknown}."
      warn "Treating as recoverable OutOfSync/Healthy drift — continuing with fix-up functions."
    else
      err "Pattern install failed and cluster appears non-recoverable."
      err "Hub health=${hub_health:-unknown}, regional-dr health=${rdr_health:-unknown}."
      exit 1
    fi
  fi

  if ! wait "$store_pid"; then
    warn "store_spoke_kubeconfigs_in_vault background job failed -- retrying synchronously..."
    store_spoke_kubeconfigs_in_vault || true
  fi

  kill "$import_pid" 2>/dev/null || true
  wait "$import_pid" 2>/dev/null || true

  # Always run the safety-net check synchronously after pattern.sh returns.
  # This catches any spoke that was skipped because the namespace appeared after
  # the background job's per-cluster timeout.
  ensure_spoke_imports
  finalize_byoc_cluster_deployments

  log "Force-refreshing kubeconfig ExternalSecrets..."
  for cluster in ocp-primary ocp-secondary; do
    oc annotate externalsecret -n "$cluster" --all \
      force-sync="$(date +%s)" --overwrite 2>/dev/null || true
  done
}


wait_for_convergence() {
  log "Waiting for environment convergence (ArgoCD Applications)..."
  export KUBECONFIG="$HUB_INSTALL_DIR/auth/kubeconfig"

  local tries=0 converged=0
  while [[ $tries -lt 120 ]]; do
    local unhealthy
    unhealthy=$(oc get applications.argoproj.io -n ramendr-starter-kit-hub \
      -o custom-columns=':.status.sync.status,:.status.health.status' --no-headers 2>/dev/null \
      | grep -Evc 'Synced.*Healthy|Synced.*Progressing' || true)

    if [[ "${unhealthy:-0}" -eq 0 ]]; then
      log "All ArgoCD applications are Synced/Healthy!"
      converged=1
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
    fi
  done

  if [[ "$converged" -ne 1 ]]; then
    warn "Timed out waiting for all hub ArgoCD apps to be Synced/Healthy (continuing)."
  fi
}

run_post_pattern_steps() {
  wait_for_convergence
  setup_dr_validation
  show_status
  log "Post-pattern deploy steps complete!"
}

setup_dr_validation() {
  if [[ "${SKIP_DR_VALIDATION:-0}" == "1" ]]; then
    log "SKIP_DR_VALIDATION=1 — skipping timestamp writers (redeploy unchanged from main)."
    return 0
  fi

  local bootstrap="$REPO_ROOT/scripts/dr-validation/bootstrap.sh"
  if [[ ! -x "$bootstrap" ]]; then
    warn "DR validation bootstrap not found: $bootstrap"
    return 0
  fi

  log "Post-redeploy: starting DR timestamp validation on edge VMs..."
  export KUBECONFIG="$HUB_INSTALL_DIR/auth/kubeconfig"
  local ssh_key="${SSH_IDENTITY_FILE:-}"
  if [[ -z "$ssh_key" ]]; then
    if [[ -f "$HOME/.ssh/id_ed25519" ]]; then
      ssh_key="$HOME/.ssh/id_ed25519"
    else
      ssh_key="$HOME/.ssh/id_rsa"
    fi
  fi

  if HUB_INSTALL_DIR="$HUB_INSTALL_DIR" \
    PRIMARY_INSTALL_DIR="$PRIMARY_INSTALL_DIR" \
    SECONDARY_INSTALL_DIR="$SECONDARY_INSTALL_DIR" \
    SSH_USER="${SSH_USER:-cloud-user}" \
    SSH_IDENTITY_FILE="$ssh_key" \
    "$bootstrap"; then
    log "DR timestamp validation is running on edge VMs."
    if [[ "${SKIP_DR_VALIDATION_SNAPSHOTS:-0}" != "1" ]] && \
      [[ -x "$REPO_ROOT/scripts/dr-validation/start-snapshot-daemon.sh" ]]; then
      HUB_INSTALL_DIR="$HUB_INSTALL_DIR" \
        PRIMARY_INSTALL_DIR="$PRIMARY_INSTALL_DIR" \
        SECONDARY_INSTALL_DIR="$SECONDARY_INSTALL_DIR" \
        "$REPO_ROOT/scripts/dr-validation/start-snapshot-daemon.sh" || \
        warn "Could not start automatic log snapshot daemon (every 5 min)."
    fi
    return 0
  fi

  warn "Redeploy finished but DR timestamp validation is not ready yet."
  warn "When VMs are up: ./scripts/dr-validation/bootstrap.sh"
  [[ "${REQUIRE_DR_VALIDATION:-0}" == "1" ]] && return 1
  return 0
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
  echo "--- DR data validation (QA) ---"
  if [[ "${SKIP_DR_VALIDATION:-0}" == "1" ]]; then
    echo "Skipped (SKIP_DR_VALIDATION=1)"
  else
    if [[ -f "$REPO_ROOT/.work/dr-validation-snapshot-daemon.pid" ]] && \
      kill -0 "$(cat "$REPO_ROOT/.work/dr-validation-snapshot-daemon.pid")" 2>/dev/null; then
      echo "Auto snapshots: running every 5 min -> .work/dr-validation-logs/auto/latest"
    else
      echo "Auto snapshots: not running (./scripts/dr-validation/start-snapshot-daemon.sh)"
    fi
    echo "After DR + UI cleanup: ./scripts/dr-validation/post-dr-automation.sh"
  fi
  if [[ "${SKIP_DR_VALIDATION:-0}" != "1" ]] && [[ -x "$REPO_ROOT/scripts/dr-validation/status.sh" ]]; then
    HUB_INSTALL_DIR="$HUB_INSTALL_DIR" \
      PRIMARY_INSTALL_DIR="$PRIMARY_INSTALL_DIR" \
      SECONDARY_INSTALL_DIR="$SECONDARY_INSTALL_DIR" \
      "$REPO_ROOT/scripts/dr-validation/status.sh" 2>&1 || \
      echo "Writers not verified. Run: ./scripts/dr-validation/bootstrap.sh"
  fi
  echo ""
  echo "--- Access ---"
  echo "Hub Console: https://console-openshift-console.apps.hub.${BASE_DOMAIN}"
  echo "KUBECONFIG: $HUB_INSTALL_DIR/auth/kubeconfig"
  echo "Timestamp log (each edge VM): /var/lib/ramendr-dr-validation/timestamps.log"
  echo ""
}

full_redeploy() {
  check_prerequisites
  prepare_upstream

  destroy_existing_clusters
  release_cluster_orphaned_eips
  cleanup_dns

  ensure_openshift_install_version
  log "Starting parallel install of hub + ocp-primary + ocp-secondary..."
  local install_failed=0
  install_hub &
  local hub_pid=$!
  install_spokes &
  local spokes_pid=$!
  wait "$hub_pid" || install_failed=1
  wait "$spokes_pid" || install_failed=1
  if [[ "$install_failed" -ne 0 ]]; then
    err "One or more cluster installs failed."
    exit 1
  fi
  log "All three clusters installed."

  create_spoke_metal_machinesets
  scale_hub_workers
  wait_for_spoke_metal_nodes

  deploy_pattern
  run_post_pattern_steps
  log "Full redeploy complete!"
}

case "${1:-}" in
  --destroy-only)
    check_prerequisites
    [[ -x "$REPO_ROOT/scripts/dr-validation/stop-snapshot-daemon.sh" ]] && \
      "$REPO_ROOT/scripts/dr-validation/stop-snapshot-daemon.sh" || true
    destroy_existing_clusters
    release_cluster_orphaned_eips
    log "Environment destroyed (Route53 hosted zone preserved)."
    ;;
  --pattern-only)
    check_prerequisites
    prepare_upstream
    create_spoke_metal_machinesets
    scale_hub_workers
    wait_for_spoke_metal_nodes
    deploy_pattern
    run_post_pattern_steps
    ;;
  --dr-bootstrap-only)
    check_prerequisites
    run_post_pattern_steps
    ;;
  --status)
    show_status
    ;;
  --help|-h)
    echo "Usage: ./scripts/redeploy.sh [--destroy-only|--pattern-only|--dr-bootstrap-only|--status|--help]"
    echo ""
    echo " (no args) Full redeploy: destroy clusters in current AWS account + install all 3 + deploy pinned upstream pattern"
    echo " --destroy-only Destroy clusters that exist in the current AWS account (hosted zone preserved)"
    echo " --pattern-only Deploy pattern on an existing hub cluster"
    echo " --dr-bootstrap-only Wait for convergence + install/verify timestamp writers (existing env)"
    echo " --status Show current environment status"
    echo ""
    echo "Pinning:"
    echo " UPSTREAM_REPO           Upstream repo URL (default: $UPSTREAM_REPO)"
    echo " UPSTREAM_REF            Upstream git ref / commit SHA (default: $UPSTREAM_REF)"
    echo " UPSTREAM_BRANCH         Local branch name to create at UPSTREAM_REF (default: $UPSTREAM_BRANCH)"
    echo ""
    echo "Environment variables:"
    echo " HUB_INSTALL_DIR       Hub cluster install directory (default: ~/git/hub-cluster-install)"
    echo " PRIMARY_INSTALL_DIR   Primary spoke install directory (default: ~/git/ocp-primary-install)"
    echo " SECONDARY_INSTALL_DIR Secondary spoke install directory (default: ~/git/ocp-secondary-install)"
    echo " VALUES_SECRET         Path to values-secret.yaml (default: ~/values-secret.yaml)"
    echo " HUB_OCP_VERSION       OCP version for all clusters (default: 4.21.14)"
    echo " HOSTED_ZONE_ID        Route53 hosted zone ID (verified, never deleted)"
    echo " BASE_DOMAIN           Base domain for the clusters (required, no default)"
    echo " CLEANUP_DNS           Set to 1 to bulk-delete DNS records in the hosted zone before install"
    echo " SKIP_DR_VALIDATION    Set to 1 to skip timestamp writers and auto snapshots"
    echo " SKIP_DR_VALIDATION_SNAPSHOTS  Set to 1 to skip only the 5-min snapshot daemon"
    echo " REQUIRE_DR_VALIDATION Set to 1 to fail redeploy if writers are not recording"
    echo " SSH_USER / SSH_IDENTITY_FILE  SSH access to edge VMs (default: cloud-user, ~/.ssh/id_rsa)"
    ;;
  *)
    full_redeploy
    ;;
esac
