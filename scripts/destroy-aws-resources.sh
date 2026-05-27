#!/bin/bash
set -euo pipefail

#
# RamenDR Starter Kit — Fast AWS Resource Teardown
#
# Immediately terminates all costly AWS resources (EC2 instances, NAT gateways,
# load balancers, Elastic IPs) without waiting for openshift-install to finish,
# then launches the three openshift-install destroy cluster jobs in the background
# to clean up remaining infrastructure (VPC, subnets, SGs, Route53, S3, IAM).
#
# Usage:
# ./scripts/destroy-aws-resources.sh
#
# Environment overrides:
# HUB_INSTALL_DIR (default: ~/git/hub-cluster-install)
# PRIMARY_INSTALL_DIR (default: ~/git/ocp-primary-install)
# SECONDARY_INSTALL_DIR (default: ~/git/ocp-secondary-install)
#

HUB_INSTALL_DIR="${HUB_INSTALL_DIR:-$HOME/git/hub-cluster-install}"
PRIMARY_INSTALL_DIR="${PRIMARY_INSTALL_DIR:-$HOME/git/ocp-primary-install}"
SECONDARY_INSTALL_DIR="${SECONDARY_INSTALL_DIR:-$HOME/git/ocp-secondary-install}"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'

log() { echo -e "${GREEN}[destroy]${NC} $*"; }
warn() { echo -e "${YELLOW}[destroy]${NC} $*"; }
err() { echo -e "${RED}[destroy]${NC} $*" >&2; }

# ---------------------------------------------------------------------------
# Read infra ID + region from metadata.json for a given install directory
# ---------------------------------------------------------------------------
read_cluster_meta() {
  local dir="$1" var_id="$2" var_region="$3"
  local meta="$dir/metadata.json"
  if [[ ! -f "$meta" ]]; then
    err "metadata.json not found in $dir — skipping cluster"
    return 1
  fi
  local infra_id region
  infra_id=$(python3 -c "import sys,json; d=json.load(open('$meta')); print(d['infraID'])")
  region=$(python3 -c "import sys,json; d=json.load(open('$meta')); print(d['aws']['region'])")
  eval "$var_id='$infra_id'"
  eval "$var_region='$region'"
}

# ---------------------------------------------------------------------------
# Terminate all EC2 instances tagged to a cluster
# ---------------------------------------------------------------------------
terminate_instances() {
  local infra_id="$1" region="$2"
  log "[$infra_id] Querying EC2 instances in $region..."
  local ids
  ids=$(aws ec2 describe-instances --region "$region" \
    --filters \
    "Name=tag:kubernetes.io/cluster/${infra_id},Values=owned" \
    "Name=instance-state-name,Values=running,stopped,stopping,pending" \
    --query 'Reservations[*].Instances[*].InstanceId' \
    --output text 2>/dev/null | tr '\t' ' ')
  if [[ -z "$ids" || "$ids" == "None" ]]; then
    warn "[$infra_id] No EC2 instances found"
    return
  fi
  local count
  count=$(echo "$ids" | wc -w)
  log "[$infra_id] Terminating $count instance(s): $ids"
  # shellcheck disable=SC2086
  aws ec2 terminate-instances --region "$region" --instance-ids $ids \
    --query 'TerminatingInstances[*].[InstanceId,CurrentState.Name]' \
    --output text 2>/dev/null
}

# ---------------------------------------------------------------------------
# Delete all NAT gateways tagged to a cluster
# ---------------------------------------------------------------------------
delete_nat_gateways() {
  local infra_id="$1" region="$2"
  local ngws
  ngws=$(aws ec2 describe-nat-gateways --region "$region" \
    --filter \
    "Name=tag:kubernetes.io/cluster/${infra_id},Values=owned" \
    "Name=state,Values=available,pending" \
    --query 'NatGateways[*].NatGatewayId' \
    --output text 2>/dev/null | tr '\t' ' ')
  if [[ -z "$ngws" || "$ngws" == "None" ]]; then
    warn "[$infra_id] No NAT gateways found"
    return
  fi
  for ngw in $ngws; do
    aws ec2 delete-nat-gateway --region "$region" --nat-gateway-id "$ngw" \
      --query 'NatGateway.NatGatewayId' --output text 2>/dev/null \
      && log "[$infra_id] Deleted NAT gateway $ngw" &
  done
  wait
}

# ---------------------------------------------------------------------------
# Delete ELBv2 (ALB/NLB) load balancers tagged to a cluster
# ---------------------------------------------------------------------------
delete_load_balancers() {
  local infra_id="$1" region="$2"
  # Fetch ARNs of all LBs and then filter by tag
  local all_arns
  all_arns=$(aws elbv2 describe-load-balancers --region "$region" \
    --query 'LoadBalancers[*].LoadBalancerArn' --output text 2>/dev/null | tr '\t' '\n')
  if [[ -z "$all_arns" ]]; then
    warn "[$infra_id] No ELBv2 load balancers found"
    return
  fi
  for arn in $all_arns; do
    local tags
    tags=$(aws elbv2 describe-tags --region "$region" --resource-arns "$arn" \
      --query "TagDescriptions[*].Tags[?Key=='kubernetes.io/cluster/${infra_id}'].Value" \
      --output text 2>/dev/null)
    if [[ "$tags" == "owned" ]]; then
      aws elbv2 delete-load-balancer --region "$region" --load-balancer-arn "$arn" 2>/dev/null \
        && log "[$infra_id] Deleted LB $arn" &
    fi
  done
  wait
}

# ---------------------------------------------------------------------------
# Release Elastic IPs tagged to a cluster
# ---------------------------------------------------------------------------
release_elastic_ips() {
  local infra_id="$1" region="$2"
  local allocs
  allocs=$(aws ec2 describe-addresses --region "$region" \
    --filters "Name=tag:kubernetes.io/cluster/${infra_id},Values=owned" \
    --query 'Addresses[*].AllocationId' \
    --output text 2>/dev/null | tr '\t' ' ')
  if [[ -z "$allocs" || "$allocs" == "None" ]]; then
    warn "[$infra_id] No Elastic IPs found"
    return
  fi
  for alloc in $allocs; do
    aws ec2 release-address --region "$region" --allocation-id "$alloc" 2>/dev/null \
      && log "[$infra_id] Released EIP $alloc" &
  done
  wait
}

# ---------------------------------------------------------------------------
# Destroy a single cluster's expensive resources
# ---------------------------------------------------------------------------
destroy_cluster_resources() {
  local infra_id="$1" region="$2" label="$3"
  log "=== $label ($infra_id, $region) ==="
  terminate_instances "$infra_id" "$region"
  delete_nat_gateways "$infra_id" "$region"
  delete_load_balancers "$infra_id" "$region"
  release_elastic_ips "$infra_id" "$region"
  log "=== $label: immediate teardown done ==="
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
echo ""
echo "=============================================="
echo " RamenDR Starter Kit — AWS Resource Teardown"
echo "=============================================="
echo ""

# Read cluster metadata
HUB_INFRA_ID=""; HUB_REGION=""
PRI_INFRA_ID=""; PRI_REGION=""
SEC_INFRA_ID=""; SEC_REGION=""

read_cluster_meta "$HUB_INSTALL_DIR" HUB_INFRA_ID HUB_REGION || true
read_cluster_meta "$PRIMARY_INSTALL_DIR" PRI_INFRA_ID PRI_REGION || true
read_cluster_meta "$SECONDARY_INSTALL_DIR" SEC_INFRA_ID SEC_REGION || true

echo "Clusters detected:"
[[ -n "$HUB_INFRA_ID" ]] && echo " hub: $HUB_INFRA_ID ($HUB_REGION)"
[[ -n "$PRI_INFRA_ID" ]] && echo " primary: $PRI_INFRA_ID ($PRI_REGION)"
[[ -n "$SEC_INFRA_ID" ]] && echo " secondary: $SEC_INFRA_ID ($SEC_REGION)"
echo ""

# Terminate expensive resources on all clusters in parallel
if [[ -n "$HUB_INFRA_ID" ]]; then
  destroy_cluster_resources "$HUB_INFRA_ID" "$HUB_REGION" "hub" &
fi
if [[ -n "$PRI_INFRA_ID" ]]; then
  destroy_cluster_resources "$PRI_INFRA_ID" "$PRI_REGION" "primary" &
fi
if [[ -n "$SEC_INFRA_ID" ]]; then
  destroy_cluster_resources "$SEC_INFRA_ID" "$SEC_REGION" "secondary" &
fi
wait

echo ""
log "All expensive resources terminated/deleted."
echo ""
log "Launching openshift-install destroy cluster in background for remaining cleanup"
log "(VPCs, subnets, security groups, Route53, S3, IAM)..."
echo ""

if [[ -n "$HUB_INFRA_ID" ]]; then
  nohup openshift-install destroy cluster \
    --dir "$HUB_INSTALL_DIR" --log-level warn \
    > /tmp/destroy-hub.log 2>&1 &
  log "Hub destroy PID: $! (logs: /tmp/destroy-hub.log)"
fi

if [[ -n "$PRI_INFRA_ID" ]]; then
  nohup openshift-install destroy cluster \
    --dir "$PRIMARY_INSTALL_DIR" --log-level warn \
    > /tmp/destroy-primary.log 2>&1 &
  log "Primary destroy PID: $! (logs: /tmp/destroy-primary.log)"
fi

if [[ -n "$SEC_INFRA_ID" ]]; then
  nohup openshift-install destroy cluster \
    --dir "$SECONDARY_INSTALL_DIR" --log-level warn \
    > /tmp/destroy-secondary.log 2>&1 &
  log "Secondary destroy PID: $! (logs: /tmp/destroy-secondary.log)"
fi

echo ""
log "Done. Billing for EC2, NAT gateways, and LBs stops within minutes."
log "Run 'tail -f /tmp/destroy-*.log' to monitor full infrastructure cleanup."
