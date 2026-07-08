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
WORK_DIR="${WORK_DIR:-$REPO_ROOT/.work}"
# shellcheck source=lib/spoke-metal.sh
source "$REPO_ROOT/scripts/lib/spoke-metal.sh"
# shellcheck source=lib/resilient-spokes.sh
source "$REPO_ROOT/scripts/lib/resilient-spokes.sh"
# shellcheck source=lib/odf-golden-images.sh
source "$REPO_ROOT/scripts/lib/odf-golden-images.sh"
# shellcheck source=lib/byoc-kubeconfig-secrets.sh
source "$REPO_ROOT/scripts/lib/byoc-kubeconfig-secrets.sh"
# shellcheck source=lib/byoc-import-wait.sh
source "$REPO_ROOT/scripts/lib/byoc-import-wait.sh"

UPSTREAM_REPO="${UPSTREAM_REPO:-https://github.com/elsapassaro/ramendr-starter-kit}"
UPSTREAM_REF="${UPSTREAM_REF:-7d24917bae80392615ed4877773260a7221d8d1a}"  # ocp-4.22 (merged add_pvc_disk)
# Branch name used to avoid detached-HEAD when UPSTREAM_REF is a bare SHA.
# The upstream pattern's Makefile derives target_branch from git and fails if HEAD is detached.
UPSTREAM_BRANCH="${UPSTREAM_BRANCH:-ocp-4.22}"

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
HUB_OCP_VERSION="${HUB_OCP_VERSION:-4.22.1}"

# Windows edge VMs are part of the protected gitops-vms fleet; fail redeploy if stabilize/OpenSSH fails.
: "${REQUIRE_WINDOWS_VMS:=1}"

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
    machine="${machine%\*}"
    if [[ -n "$machine" ]]; then
      log "Starting podman machine ${machine}..."
      podman machine start "$machine" &>/dev/null || true
      local socket
      socket=$(podman machine inspect "$machine" --format '{{.ConnectionInfo.PodmanSocket.Path}}' 2>/dev/null || true)
      if [[ -n "$socket" && -S "$socket" ]]; then
        export DOCKER_HOST="unix://${socket}"
      fi
      local tries=0
      while [[ $tries -lt 30 ]]; do
        if podman info &>/dev/null; then
          log "Podman is ready."
          return 0
        fi
        sleep 2
        tries=$((tries + 1))
      done
    fi
    err "Start Podman manually, then re-run: podman machine start"
    err "Or install the helper: sudo podman-mac-helper install && podman machine start"
    return 1
  fi

  err "Podman is not running. Start the Podman service/socket, then re-run deploy."
  return 1
}

hub_pattern_app_health() {
  oc get application.argoproj.io ramendr-starter-kit-hub \
    -n vp-gitops \
    -o jsonpath='{.status.health.status}' 2>/dev/null \
    || oc get application.argoproj.io ramendr-starter-kit-hub \
      -n ramendr-starter-kit-hub \
      -o jsonpath='{.status.health.status}' 2>/dev/null || true
}

pattern_install_recoverable() {
  local hub_health rdr_health joined acm_health
  hub_health="$(hub_pattern_app_health)"
  rdr_health=$(oc get application.argoproj.io regional-dr \
    -n ramendr-starter-kit-hub \
    -o jsonpath='{.status.health.status}' 2>/dev/null || true)
  acm_health=$(oc get application.argoproj.io acm \
    -n ramendr-starter-kit-hub \
    -o jsonpath='{.status.health.status}' 2>/dev/null || true)
  joined=$(oc get managedclusters --no-headers 2>/dev/null | wc -l | tr -d ' ' || true)
  [[ "$hub_health" == "Healthy" ]] || [[ "$rdr_health" == "Healthy" ]] \
    || [[ "$acm_health" == "Healthy" ]] || [[ "${joined:-0}" -ge 3 ]]
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
    # pattern-install derives target_origin from the branch upstream; checkout -B from
    # a bare SHA leaves no tracking branch unless we set it explicitly.
    if git show-ref --verify --quiet "refs/remotes/origin/${UPSTREAM_BRANCH}"; then
      git branch --set-upstream-to="origin/${UPSTREAM_BRANCH}" "$UPSTREAM_BRANCH"
    fi
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

deploy_pattern() {
  ensure_podman_ready || exit 1
  log "Deploying RamenDR pattern (BYOC: install-byoc with spoke kubeconfigs in values-secret)..."
  export KUBECONFIG="$HUB_INSTALL_DIR/auth/kubeconfig"

  prepare_byoc_values_secret || exit 1

  log "Running upstream pattern install-byoc (loads secrets to Vault, validates BYOC, deploys pattern)..."
  local pattern_exit=0
  ( cd "$UPSTREAM_DIR" && \
      KUBECONFIG="$HUB_INSTALL_DIR/auth/kubeconfig" \
      VALUES_SECRET="$BYOC_VALUES_SECRET" \
      TARGET_ORIGIN="${TARGET_ORIGIN:-origin}" \
      ./pattern.sh make install-byoc 2>&1 ) \
    || pattern_exit=$?

  if [[ $pattern_exit -ne 0 ]]; then
    # pattern.sh often times out because regional-dr and/or ramendr-starter-kit-hub
    # are OutOfSync/Healthy — expected drift that the fix-up functions below correct.
    warn "pattern.sh make install-byoc returned non-zero — checking whether this is recoverable drift..."
    local hub_health rdr_health
    hub_health="$(hub_pattern_app_health)"
    rdr_health=$(oc get application.argoproj.io regional-dr \
      -n ramendr-starter-kit-hub \
      -o jsonpath='{.status.health.status}' 2>/dev/null || true)
    if pattern_install_recoverable; then
      warn "Hub health=${hub_health:-unknown}, regional-dr health=${rdr_health:-unknown}."
      warn "Treating as recoverable drift — continuing with fix-up functions."
    else
      err "Pattern install failed and cluster appears non-recoverable."
      err "Hub health=${hub_health:-unknown}, regional-dr health=${rdr_health:-unknown}."
      exit 1
    fi
  fi

  if ! wait_for_byoc_spoke_import; then
    warn "BYOC spoke import did not complete within timeout; resilient GitOps and DR bootstrap may fail."
  fi

  prepare_spoke_argo_appprojects_on_all_spokes || \
    warn "[spoke-gitops] AppProject/default pre-create incomplete; resilient parent sync may wedge."

  ensure_resilient_spoke_gitops || warn "[placement] resilient-placement did not converge; spoke ODF may be delayed."
  prepare_spoke_argo_appprojects_on_all_spokes || true
  recover_all_spoke_resilient_apps || true
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
      if ! resilient_placement_satisfied 2; then
        refresh_resilient_placements
      fi
      prepare_spoke_argo_appprojects_on_all_spokes || true
      recover_all_spoke_resilient_apps || true
    fi
  done

  if [[ "$converged" -ne 1 ]]; then
    warn "Timed out waiting for all hub ArgoCD apps to be Synced/Healthy (continuing)."
  fi
}

run_post_pattern_steps() {
  if ! wait_for_spoke_resilient_gitops; then
    warn "Spoke resilient GitOps did not converge — spoke ODF may be missing; skipping golden image fix and DR validation."
    export SKIP_DR_VALIDATION=1
  else
    fix_spoke_golden_images_on_all_spokes || \
      warn "Golden image fix-up did not fully succeed — VM root disks may use slow EBS→ODF clones."
  fi

  wait_for_convergence
  stabilize_windows_edge_vms
  setup_dr_validation
  show_status
  log "Post-pattern deploy steps complete!"
}

stabilize_windows_edge_vms() {
  local script="$REPO_ROOT/scripts/stabilize-windows-vms.sh"
  if [[ ! -x "$script" ]]; then
    warn "Windows VM stabilization script not found: $script"
    if [[ "${REQUIRE_WINDOWS_VMS}" == "1" ]]; then
      return 1
    fi
    return 0
  fi
  log "Waiting for gitops-vms Windows VMs, then stabilizing (OS disk import + restart if needed)..."
  if ! HUB_INSTALL_DIR="$HUB_INSTALL_DIR" \
    PRIMARY_INSTALL_DIR="$PRIMARY_INSTALL_DIR" \
    SECONDARY_INSTALL_DIR="$SECONDARY_INSTALL_DIR" \
    REQUIRE_WINDOWS_VMS="$REQUIRE_WINDOWS_VMS" \
    "$script"; then
    warn "Windows VM stabilization failed (HammerDB bootstrap may still proceed on Linux VMs)."
    if [[ "${REQUIRE_WINDOWS_VMS}" == "1" ]]; then
      return 1
    fi
  fi
  return 0
}

setup_dr_validation() {
  if [[ "${SKIP_DR_VALIDATION:-0}" == "1" ]]; then
    log "SKIP_DR_VALIDATION=1 — skipping DR validation bootstrap and snapshots."
    return 0
  fi

  if ! spoke_resilient_gitops_all_ready; then
    warn "Spoke ODF prerequisites not met (${RESILIENT_PARENT_APP} not Synced or openshift-storage missing)."
    warn "Skipping DR validation — re-run with --dr-bootstrap-only after spoke GitOps converges."
    return 0
  fi

  local bootstrap="$REPO_ROOT/scripts/dr-validation/bootstrap.sh"
  if [[ ! -x "$bootstrap" ]]; then
    err "DR validation bootstrap not found: $bootstrap"
    return 1
  fi

  local max_attempts="${DR_VALIDATION_BOOTSTRAP_RETRIES:-6}"
  local retry_sleep="${DR_VALIDATION_BOOTSTRAP_RETRY_SLEEP:-120}"
  local attempt=1
  local bootstrap_ok=0

  log "Post-redeploy: starting DR validation (mode=${DR_VALIDATION_MODE:-hammerdb})..."
  export KUBECONFIG="$HUB_INSTALL_DIR/auth/kubeconfig"
  local ssh_key="${SSH_IDENTITY_FILE:-}"
  if [[ -z "$ssh_key" ]]; then
    if [[ -f "$HOME/.ssh/id_ed25519" ]]; then
      ssh_key="$HOME/.ssh/id_ed25519"
    else
      ssh_key="$HOME/.ssh/id_rsa"
    fi
  fi

  while [[ $attempt -le $max_attempts ]]; do
    log "DR validation bootstrap attempt ${attempt}/${max_attempts}..."
    if HUB_INSTALL_DIR="$HUB_INSTALL_DIR" \
      PRIMARY_INSTALL_DIR="$PRIMARY_INSTALL_DIR" \
      SECONDARY_INSTALL_DIR="$SECONDARY_INSTALL_DIR" \
      SSH_USER="${SSH_USER:-cloud-user}" \
      SSH_IDENTITY_FILE="$ssh_key" \
      "$bootstrap"; then
      if HUB_INSTALL_DIR="$HUB_INSTALL_DIR" \
        PRIMARY_INSTALL_DIR="$PRIMARY_INSTALL_DIR" \
        SECONDARY_INSTALL_DIR="$SECONDARY_INSTALL_DIR" \
        "$REPO_ROOT/scripts/dr-validation/status.sh"; then
        bootstrap_ok=1
        break
      fi
      warn "Bootstrap finished but status verification failed on attempt ${attempt}."
    else
      warn "DR validation bootstrap failed on attempt ${attempt}/${max_attempts}."
    fi
    if [[ $attempt -lt $max_attempts ]]; then
      log "Retrying DR validation bootstrap in ${retry_sleep}s..."
      sleep "$retry_sleep"
    fi
    attempt=$((attempt + 1))
  done

  if [[ "$bootstrap_ok" -ne 1 ]]; then
    if HUB_INSTALL_DIR="$HUB_INSTALL_DIR" \
      PRIMARY_INSTALL_DIR="$PRIMARY_INSTALL_DIR" \
      SECONDARY_INSTALL_DIR="$SECONDARY_INSTALL_DIR" \
      "$REPO_ROOT/scripts/dr-validation/status.sh"; then
      warn "Bootstrap did not finish cleanly, but DR validation workload looks healthy; continuing."
      bootstrap_ok=1
    else
      err "DR validation is not ready after ${max_attempts} automatic bootstrap attempt(s)."
      err "Fix edge VM SSH/cloud-init or HammerDB install logs, then re-run redeploy."
      return 1
    fi
  fi

  log "DR validation is running (mode=${DR_VALIDATION_MODE:-hammerdb})."
  if [[ "${DR_VALIDATION_MODE:-hammerdb}" != "hammerdb" ]] && \
    [[ "${SKIP_DR_VALIDATION_SNAPSHOTS:-0}" != "1" ]] && \
    [[ -x "$REPO_ROOT/scripts/dr-validation/start-snapshot-daemon.sh" ]]; then
    if ! HUB_INSTALL_DIR="$HUB_INSTALL_DIR" \
      PRIMARY_INSTALL_DIR="$PRIMARY_INSTALL_DIR" \
      SECONDARY_INSTALL_DIR="$SECONDARY_INSTALL_DIR" \
      "$REPO_ROOT/scripts/dr-validation/start-snapshot-daemon.sh"; then
      err "Could not start automatic timestamp snapshot daemon."
      return 1
    fi
  fi
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
    if [[ "${DR_VALIDATION_MODE:-hammerdb}" == "hammerdb" ]]; then
      local db_snapshot_root="${DR_VALIDATION_DB_SNAPSHOT_ROOT:-${REPO_ROOT}/.work/dr-validation-db/auto}"
      local db_baseline_link="${db_snapshot_root}/latest"
      baseline_dir=""
      if [[ -L "$db_baseline_link" ]]; then
        if baseline_dir="$(cd "$db_baseline_link" 2>/dev/null && pwd)"; then
          echo "DB baseline: ${baseline_dir} (${db_baseline_link})"
        else
          echo "DB baseline: dangling symlink (${db_baseline_link})"
        fi
      else
        echo "DB baseline: not set (./scripts/dr-validation/save-db-baseline-snapshot.sh)"
      fi
    elif [[ -f "$REPO_ROOT/.work/dr-validation-snapshot-daemon.pid" ]] && \
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
      echo "DR validation status check failed (re-run ./scripts/redeploy.sh --dr-bootstrap-only)."
  fi
  echo ""
  echo "--- Access ---"
  echo "Hub Console: https://console-openshift-console.apps.hub.${BASE_DOMAIN}"
  echo "KUBECONFIG: $HUB_INSTALL_DIR/auth/kubeconfig"
  echo "DR validation mode: ${DR_VALIDATION_MODE:-hammerdb}"
  if [[ "${DR_VALIDATION_MODE:-hammerdb}" == "hammerdb" ]]; then
    echo "HammerDB targets: all edge VMs in gitops-vms (automatic during redeploy when DR_VALIDATION_HAMMERDB_ALL_VMS=1)"
    echo "  Linux: PostgreSQL TPC-C | Windows: SQL Server TPC-C + audit table per VM"
  else
    echo "Timestamp log (each edge VM): /var/lib/ramendr-dr-validation/timestamps.log"
  fi
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
    echo " --dr-bootstrap-only Wait for convergence + automatic DR validation bootstrap (existing env)"
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
    echo " HUB_OCP_VERSION       OCP version for all clusters (default: 4.22.1)"
    echo " HOSTED_ZONE_ID        Route53 hosted zone ID (verified, never deleted)"
    echo " BASE_DOMAIN           Base domain for the clusters (required, no default)"
    echo " CLEANUP_DNS           Set to 1 to bulk-delete DNS records in the hosted zone before install"
    echo " DR_VALIDATION_MODE   hammerdb (default) or timestamp for legacy log validation"
    echo " DR_VALIDATION_HAMMERDB_ALL_VMS  Install on every edge VM (default 1; 0 = legacy single VM)"
    echo " DR_VALIDATION_HAMMERDB_VMS      Comma-separated VM name filter (overrides ALL_VMS)"
    echo " DR_VALIDATION_HAMMERDB_VM       Legacy single VM when ALL_VMS=0 (default rhel9-node-001)"
    echo " DR_VALIDATION_SQL_SSEI_URL       Direct URL for SQL2022-SSEI-Expr.exe (staged to Windows VMs)"
    echo " DR_VALIDATION_PYTHON_WINDOWS_URL Python amd64 installer URL (staged to Windows VMs)"
    echo " SKIP_DR_VALIDATION    Set to 1 to skip automatic DR validation bootstrap and snapshots"
    echo " SKIP_DR_VALIDATION_SNAPSHOTS  Set to 1 to skip only the 5-min snapshot daemon"
    echo " REQUIRE_WINDOWS_VMS   Fail redeploy if Windows stabilize/OpenSSH fails (default 1; set 0 to warn only)"
    echo " SKIP_WINDOWS_VM_STABILIZE  Set to 1 to skip stabilize-windows-vms.sh entirely"
    echo " DR_VALIDATION_BOOTSTRAP_RETRIES  Automatic bootstrap retries during redeploy (default 6)"
    echo " DR_VALIDATION_BOOTSTRAP_RETRY_SLEEP Seconds between bootstrap retries (default 120)"
    echo " SPOKE_RESILIENT_GITOPS_WAIT_ATTEMPTS  Wait for spoke vp-gitops parent app (default 60)"
    echo " SPOKE_RESILIENT_GITOPS_WAIT_SLEEP     Seconds between spoke GitOps polls (default 60)"
    echo " WINDOWS_VM_APPEAR_WAIT_TRIES          Wait for gitops-vms Windows VMs before stabilize (default 60)"
    echo " WINDOWS_VM_APPEAR_WAIT_SLEEP          Seconds between Windows VM appear polls (default 30)"
    echo " WINDOWS_SSH_WAIT_TRIES                Wait for Windows SSH reachability, all VMs (default 120)"
    echo " WINDOWS_SSH_WAIT_SLEEP                  Seconds between SSH verify polls (default 10)"
    echo " WINDOWS_SSH_USER                      Windows SSH user (default Administrator)"
    echo " WINDOWS_SSH_PASSWORD                  Override windows-admin password from VALUES_SECRET"
    echo " WINDOWS_VM_DV_WAIT_TRIES              Wait for Windows OS DataVolume clone/import (default 180)"
    echo " WINDOWS_VM_STABILIZE_WAIT_TRIES       Wait for Running/ready after restart (default 40)"
    echo " SPOKE_APPPROJECT_PREP_WAIT_ATTEMPTS    Wait for vp-gitops + AppProject/default per spoke (default 40)"
    echo " SPOKE_APPPROJECT_PREP_WAIT_SLEEP       Seconds between AppProject prep polls (default 15)"
    echo " SKIP_ODF_GOLDEN_IMAGE_FIX  Set to 1 to skip post-ODF CNV golden image re-import fix"
    echo " ODF_GOLDEN_PROTECTED_DATASOURCES  Never delete these os-images DataSources/PVCs (default: windows2k22,windows2k25)"
    echo " ODF_GOLDEN_IMAGE_WAIT_ATTEMPTS  Wait for golden image re-import per spoke (default 30)"
    echo " ODF_GOLDEN_IMAGE_WAIT_SLEEP     Seconds between golden image polls (default 60)"
    echo " SPOKE_ODF_STORAGE_WAIT_ATTEMPTS   Wait for ODF Available before golden image fix (default 30)"
    echo " SPOKE_ODF_STORAGE_WAIT_SLEEP      Seconds between ODF Available polls (default 30)"
    echo " BYOC_IMPORT_WAIT_ATTEMPTS      Wait for ESO/MC spoke import per step (default 40)"
    echo " BYOC_IMPORT_WAIT_SLEEP         Seconds between BYOC import polls (default 30)"
    ;;
  *)
    full_redeploy
    ;;
esac
