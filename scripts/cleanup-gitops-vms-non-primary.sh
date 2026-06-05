#!/bin/bash
set -euo pipefail

# Script to manually cleanup gitops-vms namespace on the non-primary cluster
#
# DR validation note: run ONLY after failover/relocate is complete. This deletes VM
# resources on the non-primary spoke (orphaned copies). Active VMs and timestamp logs
# live on the current primary — do not run if primary detection is wrong. For data
# checks after DR, use: ./scripts/dr-validation/check-after-dr.sh
#
# This script will:
# 1. Determine the non-primary cluster (discovered from DR policy; override with PRIMARY_CLUSTER/SECONDARY_CLUSTER env if needed)
# 2. List VM-related resources directly from the non-primary cluster
# 3. Delete them from the gitops-vms namespace
# 4. Delete all PVCs in gitops-vms (including stuck Terminating PVCs held by Ramen DR finalizers)
#    Skipped when --skip-pvcs is passed (use during relocate to preserve RBD mirror source images)
# 5. Remove orphan PVs that were bound to gitops-vms (Retain reclaim policy)
#    Skipped when --skip-pvcs is passed

# Configuration
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="/tmp/edge-gitops-vms-cleanup"
VM_NAMESPACE="gitops-vms"
DRPC_NAMESPACE="openshift-dr-ops"
DRPC_NAME="gitops-vm-protection"
PLACEMENT_NAME="gitops-vm-protection-placement-1"

# Colors for output (before arg parsing — used in Unknown option messages under set -u)
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

AUTO_CONFIRM="${AUTO_CONFIRM:-no}"
CLEANUP_FORCE=0
SKIP_PVCS=0
CLUSTER_OVERRIDE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --yes | -y) AUTO_CONFIRM=yes; shift ;;
    --force) CLEANUP_FORCE=1; shift ;;
    --skip-pvcs) SKIP_PVCS=1; shift ;;
    --) shift; break ;;
    -*)
      echo -e "${RED}Unknown option: $1${NC}" >&2
      exit 1
      ;;
    *)
      if [[ -z "$CLUSTER_OVERRIDE" ]]; then
        CLUSTER_OVERRIDE="$1"
      else
        echo -e "${RED}Unexpected argument: $1${NC}" >&2
        exit 1
      fi
      shift
      ;;
  esac
done

# shellcheck source=lib/drpc-guards.sh
source "${REPO_ROOT}/scripts/lib/drpc-guards.sh"

# Initialize variables
PRIMARY_CLUSTER=""
NON_PRIMARY_CLUSTER=""

# Create working directory
mkdir -p "$WORK_DIR"

# Function to determine current primary cluster from DRPC
determine_primary_cluster() {
  echo "Determining current primary cluster from DRPC..."

  # First, check PlacementDecision - this is the most reliable way to determine current primary
  # The PlacementDecision shows which cluster is currently selected by the Placement
  local placement_cluster
  placement_cluster=$(oc get placementdecision -n "$DRPC_NAMESPACE" \
    -l cluster.open-cluster-management.io/placement="$PLACEMENT_NAME" \
    -o jsonpath='{.items[0].status.decisions[0].clusterName}' 2>/dev/null || echo "")

  if [[ -n "$placement_cluster" ]]; then
    PRIMARY_CLUSTER="$placement_cluster"
    echo " ✅ Current primary cluster from PlacementDecision: $PRIMARY_CLUSTER"
    echo " (This is the cluster where VMs are currently deployed)"
    return 0
  fi

  # Fallback: Get preferred cluster from DRPC spec
  local preferred_cluster
  preferred_cluster=$(oc get drplacementcontrol "$DRPC_NAME" -n "$DRPC_NAMESPACE" \
    -o jsonpath='{.spec.preferredCluster}' 2>/dev/null || echo "")

  if [[ -n "$preferred_cluster" ]]; then
    PRIMARY_CLUSTER="$preferred_cluster"
    echo " ⚠️ Using preferred cluster from DRPC spec: $PRIMARY_CLUSTER"
    echo " (PlacementDecision not available - this may not reflect current state after failover)"
    return 0
  fi

  echo -e "${YELLOW} ⚠️ Warning: Could not determine primary cluster from DRPC${NC}"
  echo " - PlacementDecision not found for $PLACEMENT_NAME"
  echo " - DRPC preferredCluster not found"
  return 1
}

# Function to determine non-primary cluster
determine_non_primary_cluster() {
  echo "Determining non-primary cluster for cleanup..."

  # Get all clusters from DRPolicy
  local dr_policy_name
  dr_policy_name=$(oc get drplacementcontrol "$DRPC_NAME" -n "$DRPC_NAMESPACE" \
    -o jsonpath='{.spec.drPolicyRef.name}' 2>/dev/null || echo "")

  if [[ -z "$dr_policy_name" ]]; then
    echo -e "${YELLOW} ⚠️ Warning: Could not get DRPolicy name from DRPC${NC}"
    return 1
  fi

  # Get clusters from DRPolicy
  local dr_clusters
  dr_clusters=$(oc get drpolicy "$dr_policy_name" \
    -o jsonpath='{.spec.drClusters[*]}' 2>/dev/null || echo "")

  if [[ -z "$dr_clusters" ]]; then
    echo -e "${YELLOW} ⚠️ Warning: Could not get DR clusters from DRPolicy${NC}"
    return 1
  fi

  echo " DR clusters in policy: $dr_clusters"
  echo " Current primary cluster: $PRIMARY_CLUSTER"

  # Find the non-primary cluster
  NON_PRIMARY_CLUSTER=""
  for cluster in $dr_clusters; do
    if [[ "$cluster" != "$PRIMARY_CLUSTER" ]]; then
      NON_PRIMARY_CLUSTER="$cluster"
      break
    fi
  done

  if [[ -z "$NON_PRIMARY_CLUSTER" ]]; then
    echo -e "${RED} ❌ Error: Could not determine non-primary cluster${NC}"
    echo " Primary cluster: $PRIMARY_CLUSTER"
    echo " DR clusters: $dr_clusters"
    return 1
  fi

  echo " ✅ Non-primary cluster determined: $NON_PRIMARY_CLUSTER"
  return 0
}

# Main execution starts here
echo "=========================================="
echo "GitOps VMs Cleanup Script"
echo "=========================================="
echo "DRPC: $DRPC_NAME (namespace: $DRPC_NAMESPACE)"
echo ""

if [[ -z "${KUBECONFIG:-}" ]] && [[ -f "${HUB_INSTALL_DIR:-$HOME/git/hub-cluster-install}/auth/kubeconfig" ]]; then
  export KUBECONFIG="${HUB_INSTALL_DIR:-$HOME/git/hub-cluster-install}/auth/kubeconfig"
fi

if ! oc get managedclusters &>/dev/null; then
  echo -e "${RED}Error: Not connected to hub cluster (set KUBECONFIG to hub).${NC}"
  exit 1
fi

echo "Running DRPC safety checks before cleanup..."
if ! assert_safe_to_cleanup_non_primary "$CLEANUP_FORCE"; then
  echo -e "${RED}Cleanup blocked. Wait for DR to finish or use --force if you accept the risk.${NC}"
  exit 1
fi
echo ""

# Determine primary and non-primary clusters
if ! determine_primary_cluster; then
  echo -e "${YELLOW} ⚠️ Warning: Could not determine primary cluster from DRPC${NC}"
  echo " You can specify the non-primary cluster as an argument: $0 <cluster-name>"
  if [[ -n "${CLUSTER_OVERRIDE:-}" ]]; then
    NON_PRIMARY_CLUSTER="$CLUSTER_OVERRIDE"
    echo " Using provided cluster: $NON_PRIMARY_CLUSTER"
  else
    echo -e "${RED} ❌ Error: Cannot proceed without determining clusters${NC}"
    exit 1
  fi
else
  if ! determine_non_primary_cluster; then
    echo -e "${YELLOW} ⚠️ Warning: Could not determine non-primary cluster${NC}"
    if [[ -n "${CLUSTER_OVERRIDE:-}" ]]; then
      NON_PRIMARY_CLUSTER="$CLUSTER_OVERRIDE"
      echo " Using provided cluster: $NON_PRIMARY_CLUSTER"
    else
      echo -e "${RED} ❌ Error: Cannot proceed without determining non-primary cluster${NC}"
      exit 1
    fi
  fi
fi

echo ""
echo "=========================================="
echo "Cleanup Configuration"
echo "=========================================="
echo "Primary cluster: ${PRIMARY_CLUSTER:-}"
echo "Non-primary cluster (target for cleanup): $NON_PRIMARY_CLUSTER"
echo "Namespace: $VM_NAMESPACE"
echo ""

# Function to get kubeconfig for a managed cluster
get_cluster_kubeconfig() {
  local cluster="$1"
  local kubeconfig_path="$WORK_DIR/${cluster}-kubeconfig.yaml"

  echo "Getting kubeconfig for cluster: $cluster"

  # Try to get the kubeconfig data — prefer 'admin-kubeconfig' (BYOC) then fall back to
  # any secret whose name contains 'kubeconfig' (Hive-managed clusters).
  local kubeconfig_data=""

  # BYOC: ExternalSecret syncs the kubeconfig from Vault into a secret called admin-kubeconfig
  for field in kubeconfig raw-kubeconfig; do
    kubeconfig_data=$(oc get secret admin-kubeconfig -n "$cluster" \
      -o jsonpath="{.data.$field}" 2>/dev/null | base64 -d 2>/dev/null || echo "")
    [[ -n "$kubeconfig_data" ]] && break
  done

  # Hive fallback: look for any secret with 'kubeconfig' in the name
  if [[ -z "$kubeconfig_data" ]]; then
    local kubeconfig_secret
    kubeconfig_secret=$(oc get secret -n "$cluster" -o name 2>/dev/null \
      | grep "kubeconfig" | grep -v "admin-kubeconfig" | head -1)
    if [[ -n "$kubeconfig_secret" ]]; then
      echo " Found kubeconfig secret: $kubeconfig_secret"
      for field in kubeconfig raw-kubeconfig; do
        kubeconfig_data=$(oc get "$kubeconfig_secret" -n "$cluster" \
          -o jsonpath="{.data.$field}" 2>/dev/null | base64 -d 2>/dev/null || echo "")
        [[ -n "$kubeconfig_data" ]] && break
      done
    fi
  else
    echo " Found kubeconfig secret: secret/admin-kubeconfig"
  fi

  if [[ -z "$kubeconfig_data" ]]; then
    echo -e "${RED} ❌ Could not extract kubeconfig data for cluster $cluster${NC}"
    return 1
  fi

  # Write the kubeconfig to file
  echo "$kubeconfig_data" > "$kubeconfig_path"

  # Validate kubeconfig
  if oc --kubeconfig="$kubeconfig_path" get nodes --request-timeout=5s &>/dev/null; then
    echo -e "${GREEN} ✅ Kubeconfig downloaded and validated for $cluster${NC}"
    export KUBECONFIG="$kubeconfig_path"
    return 0
  else
    echo -e "${RED} ❌ Kubeconfig for $cluster is invalid or cluster is unreachable${NC}"
    return 1
  fi
}

# Function to list VM-related resources directly from the target cluster
list_cluster_resources() {
  echo ""
  echo "Step 1: Listing VM resources in namespace $VM_NAMESPACE on cluster $NON_PRIMARY_CLUSTER..."

  : > "$WORK_DIR/resources-list.txt"

  local resource_types=("VirtualMachine" "VirtualMachineInstance" "Service" "Route" "ExternalSecret" "DataVolume" "DataSource")

  for res_type in "${resource_types[@]}"; do
    local items
    items=$(oc --kubeconfig="$KUBECONFIG" get "$res_type" -n "$VM_NAMESPACE" \
      -o jsonpath='{range .items[*]}{.kind}{"|"}{.metadata.name}{"\n"}{end}' 2>/dev/null || echo "")
    if [[ -n "$items" ]]; then
      echo "$items" >> "$WORK_DIR/resources-list.txt"
    fi
  done

  local VM_COUNT VMI_COUNT SERVICE_COUNT ROUTE_COUNT ES_COUNT DV_COUNT DS_COUNT PVC_COUNT
  VM_COUNT=$(grep -c "^VirtualMachine|" "$WORK_DIR/resources-list.txt" 2>/dev/null || true)
  VMI_COUNT=$(grep -c "^VirtualMachineInstance|" "$WORK_DIR/resources-list.txt" 2>/dev/null || true)
  SERVICE_COUNT=$(grep -c "^Service|" "$WORK_DIR/resources-list.txt" 2>/dev/null || true)
  ROUTE_COUNT=$(grep -c "^Route|" "$WORK_DIR/resources-list.txt" 2>/dev/null || true)
  ES_COUNT=$(grep -c "^ExternalSecret|" "$WORK_DIR/resources-list.txt" 2>/dev/null || true)
  DV_COUNT=$(grep -c "^DataVolume|" "$WORK_DIR/resources-list.txt" 2>/dev/null || true)
  DS_COUNT=$(grep -c "^DataSource|" "$WORK_DIR/resources-list.txt" 2>/dev/null || true)
  PVC_COUNT=$(oc --kubeconfig="$KUBECONFIG" get pvc -n "$VM_NAMESPACE" --no-headers 2>/dev/null | wc -l | tr -d ' ')
  VM_COUNT=${VM_COUNT:-0}
  VMI_COUNT=${VMI_COUNT:-0}
  SERVICE_COUNT=${SERVICE_COUNT:-0}
  ROUTE_COUNT=${ROUTE_COUNT:-0}
  ES_COUNT=${ES_COUNT:-0}
  DV_COUNT=${DV_COUNT:-0}
  DS_COUNT=${DS_COUNT:-0}
  PVC_COUNT=${PVC_COUNT:-0}

  echo " Found resources on cluster:"
  echo " - VirtualMachines: $VM_COUNT"
  echo " - VirtualMachineInstances: $VMI_COUNT"
  echo " - Services: $SERVICE_COUNT"
  echo " - Routes: $ROUTE_COUNT"
  echo " - ExternalSecrets: $ES_COUNT"
  echo " - DataVolumes: $DV_COUNT"
  echo " - DataSources: $DS_COUNT"
  echo " - PersistentVolumeClaims: $PVC_COUNT"

  local total=$(( VM_COUNT + VMI_COUNT + SERVICE_COUNT + ROUTE_COUNT + ES_COUNT + DV_COUNT + DS_COUNT + PVC_COUNT ))
  if [[ $total -eq 0 ]]; then
    echo -e "${YELLOW} ⚠️ No resources found in namespace $VM_NAMESPACE${NC}"
    echo " Nothing to clean up"
    return 1
  fi

  return 0
}

# Function to delete resources
delete_resources() {
  echo ""
  echo "Step 2: Deleting resources from namespace $VM_NAMESPACE on cluster $NON_PRIMARY_CLUSTER..."

  if [[ ! -s "$WORK_DIR/resources-list.txt" ]]; then
    echo -e "${RED} ❌ No resources to delete (resources-list.txt is empty)${NC}"
    return 1
  fi

  local deleted_count=0
  local error_count=0

  while IFS='|' read -r kind name; do
    if [[ -z "$kind" || -z "$name" ]]; then
      continue
    fi

    echo " Deleting: $kind/$name in namespace $VM_NAMESPACE"

    if oc --kubeconfig="$KUBECONFIG" delete "$kind" "$name" -n "$VM_NAMESPACE" --ignore-not-found &>/dev/null; then
      echo -e " ${GREEN}✅ Deleted: $kind/$name${NC}"
      deleted_count=$((deleted_count + 1))
    else
      echo -e " ${RED}❌ Failed to delete: $kind/$name${NC}"
      error_count=$((error_count + 1))
    fi
  done < "$WORK_DIR/resources-list.txt"

  echo ""
  echo "Deletion summary:"
  echo " - Successfully deleted: $deleted_count"
  echo " - Errors: $error_count"

  if [[ $error_count -gt 0 ]]; then
    echo -e "${RED} ⚠️ Some resources failed to delete${NC}"
    return 1
  fi

  return 0
}

# Function to force-delete all virt-launcher pods.
# Uses the kubevirt.io=virt-launcher label selector with jsonpath output to avoid
# the text-parsing fragility of --no-headers|awk, which misses pods in certain
# transient states. Three passes with a 10s pause before each retry catch pods
# that transition state (Running→Error) after the VMs are deleted.
cleanup_virt_launcher_pods() {
  echo ""
  echo "Step 3: Cleaning up leftover virt-launcher pods in namespace $VM_NAMESPACE..."

  local total_deleted=0
  local pass

  for pass in 1 2 3; do
    [[ $pass -gt 1 ]] && sleep 10

    local pods
    pods=$(oc --kubeconfig="$KUBECONFIG" get pods -n "$VM_NAMESPACE" \
      -l kubevirt.io=virt-launcher \
      -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null || true)

    if [[ -z "$pods" ]]; then
      break
    fi

    echo " Pass $pass — found $(echo "$pods" | grep -c .) pod(s)"
    while IFS= read -r pod; do
      [[ -z "$pod" ]] && continue
      echo " Deleting pod: $pod"
      if oc --kubeconfig="$KUBECONFIG" delete pod "$pod" -n "$VM_NAMESPACE" \
        --grace-period=0 --force --ignore-not-found &>/dev/null; then
        echo -e " ${GREEN}✅ Deleted: $pod${NC}"
        total_deleted=$((total_deleted + 1))
      else
        echo -e " ${RED}❌ Failed to delete: $pod${NC}"
      fi
    done <<< "$pods"
  done

  if [[ $total_deleted -eq 0 ]]; then
    echo " No leftover virt-launcher pods found"
  else
    echo " Deleted $total_deleted leftover virt-launcher pod(s)"
  fi
}

# Delete all PVCs in gitops-vms. Ramen DR finalizers often leave PVCs stuck in Terminating
# after VM/DataVolume deletion on the non-primary spoke; clear finalizers when needed.
cleanup_pvcs() {
  echo ""
  echo "Step 4: Deleting all PVCs in namespace $VM_NAMESPACE..."

  local pvcs deleted_count=0 error_count=0
  pvcs=$(oc --kubeconfig="$KUBECONFIG" get pvc -n "$VM_NAMESPACE" \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null || true)

  if [[ -z "$pvcs" ]]; then
    echo " No PVCs found"
    return 0
  fi

  while IFS= read -r pvc; do
    [[ -z "$pvc" ]] && continue
    echo " Deleting PVC: $pvc"
    # --wait=false returns immediately so Ramen/CDI finalizers don't block here.
    # The retry loop below clears any remaining finalizers.
    if oc --kubeconfig="$KUBECONFIG" delete pvc "$pvc" -n "$VM_NAMESPACE" --ignore-not-found --wait=false &>/dev/null; then
      echo -e " ${GREEN}✅ Delete requested: $pvc${NC}"
      deleted_count=$((deleted_count + 1))
    else
      echo -e " ${RED}❌ Failed to delete PVC: $pvc${NC}"
      error_count=$((error_count + 1))
    fi
  done <<< "$pvcs"

  local pass stuck
  for pass in 1 2 3 4 5 6; do
    stuck=$(oc --kubeconfig="$KUBECONFIG" get pvc -n "$VM_NAMESPACE" -o json 2>/dev/null \
      | python3 -c "
import json, sys
data = json.load(sys.stdin)
for item in data.get('items', []):
    print(item['metadata']['name'])
" 2>/dev/null || true)
    if [[ -z "$stuck" ]]; then
      break
    fi
    if [[ $pass -gt 1 ]]; then
      echo " Pass $pass — $(echo "$stuck" | grep -c .) PVC(s) still present"
    fi
    while IFS= read -r pvc; do
      [[ -z "$pvc" ]] && continue
      local deletionTimestamp
      deletionTimestamp=$(oc --kubeconfig="$KUBECONFIG" get pvc "$pvc" -n "$VM_NAMESPACE" \
        -o jsonpath='{.metadata.deletionTimestamp}' 2>/dev/null || true)
      if [[ -n "$deletionTimestamp" ]] || [[ $pass -ge 3 ]]; then
        echo " Clearing finalizers on stuck PVC: $pvc"
        oc --kubeconfig="$KUBECONFIG" patch pvc "$pvc" -n "$VM_NAMESPACE" \
          --type=merge -p '{"metadata":{"finalizers":null}}' &>/dev/null || true
      fi
    done <<< "$stuck"
    sleep 5
  done

  local remaining
  remaining=$(oc --kubeconfig="$KUBECONFIG" get pvc -n "$VM_NAMESPACE" --no-headers 2>/dev/null | wc -l | tr -d ' ')
  remaining=${remaining:-0}
  if [[ "$remaining" -gt 0 ]]; then
    echo -e "${RED} ❌ $remaining PVC(s) still remain in $VM_NAMESPACE${NC}"
    oc --kubeconfig="$KUBECONFIG" get pvc -n "$VM_NAMESPACE" 2>/dev/null || true
    return 1
  fi

  echo -e "${GREEN} ✅ All PVCs removed from $VM_NAMESPACE ($deleted_count delete requests)${NC}"
  [[ $error_count -eq 0 ]]
}

# Remove cluster-scoped PVs that were bound to gitops-vms (common with Retain reclaim policy).
cleanup_gitops_pvs() {
  echo ""
  echo "Step 5: Removing orphan PVs for namespace $VM_NAMESPACE..."

  local pvs deleted_count=0
  pvs=$(oc --kubeconfig="$KUBECONFIG" get pv -o json 2>/dev/null \
    | python3 -c "
import json, sys
ns = sys.argv[1]
data = json.load(sys.stdin)
for item in data.get('items', []):
    ref = item.get('spec', {}).get('claimRef') or {}
    if ref.get('namespace') == ns:
        print(item['metadata']['name'])
" "$VM_NAMESPACE" 2>/dev/null || true)

  if [[ -z "$pvs" ]]; then
    echo " No PVs bound to $VM_NAMESPACE"
    return 0
  fi

  while IFS= read -r pv; do
    [[ -z "$pv" ]] && continue
    echo " Deleting PV: $pv"
    oc --kubeconfig="$KUBECONFIG" delete pv "$pv" --ignore-not-found --wait=false &>/dev/null || true
    if oc --kubeconfig="$KUBECONFIG" get pv "$pv" &>/dev/null; then
      echo " Clearing finalizers on stuck PV: $pv"
      oc --kubeconfig="$KUBECONFIG" patch pv "$pv" \
        --type=merge -p '{"metadata":{"finalizers":null}}' &>/dev/null || true
    fi
    deleted_count=$((deleted_count + 1))
  done <<< "$pvs"

  local remaining=0 try
  for try in 1 2 3 4 5 6; do
    remaining=$(oc --kubeconfig="$KUBECONFIG" get pv -o json 2>/dev/null \
      | python3 -c "
import json, sys
ns = sys.argv[1]
data = json.load(sys.stdin)
print(sum(1 for i in data.get('items', [])
    if (i.get('spec', {}).get('claimRef') or {}).get('namespace') == ns))
" "$VM_NAMESPACE" 2>/dev/null || echo 0)
    remaining=${remaining:-0}
    [[ "$remaining" -eq 0 ]] && break
    [[ "$try" -lt 6 ]] && sleep 5
  done
  if [[ "$remaining" -gt 0 ]]; then
    echo -e "${YELLOW} ⚠️ $remaining PV(s) still reference $VM_NAMESPACE (may need manual cleanup)${NC}"
    return 1
  fi

  echo -e "${GREEN} ✅ Removed $deleted_count orphan PV(s)${NC}"
  return 0
}

# Main execution
main() {
  # Check if we're connected to a hub cluster
  if ! oc get managedclusters &>/dev/null; then
    echo -e "${RED}Error: Not connected to a hub cluster or cannot access managedclusters${NC}"
    echo "Please ensure you're connected to the hub cluster and have proper permissions"
    exit 1
  fi

  # Verify the non-primary cluster exists
  if ! oc get managedcluster "$NON_PRIMARY_CLUSTER" &>/dev/null; then
    echo -e "${RED}Error: Managed cluster '$NON_PRIMARY_CLUSTER' not found${NC}"
    echo "Available managed clusters:"
    oc get managedclusters -o name 2>/dev/null | sed 's/^/ - /' || echo " (could not list clusters)"
    exit 1
  fi

  # Get kubeconfig for non-primary cluster
  if ! get_cluster_kubeconfig "$NON_PRIMARY_CLUSTER"; then
    echo -e "${RED}Error: Failed to get kubeconfig for cluster $NON_PRIMARY_CLUSTER${NC}"
    exit 1
  fi

  # Verify namespace exists
  if ! oc --kubeconfig="$KUBECONFIG" get namespace "$VM_NAMESPACE" &>/dev/null; then
    echo -e "${YELLOW} ⚠️ Namespace $VM_NAMESPACE does not exist on cluster $NON_PRIMARY_CLUSTER${NC}"
    echo " Nothing to clean up"
    exit 0
  fi

  # List resources directly from the target cluster (including orphaned PVCs)
  if ! list_cluster_resources; then
    exit 0
  fi

  # Confirm deletion
  echo ""
  echo "=========================================="
  echo -e "${YELLOW}WARNING: This will delete resources from namespace $VM_NAMESPACE on cluster $NON_PRIMARY_CLUSTER${NC}"
  echo "=========================================="
  echo ""
  if [[ "$AUTO_CONFIRM" == "yes" ]]; then
    echo "AUTO_CONFIRM=yes — proceeding with deletion (non-interactive)."
    confirm="yes"
  else
    read -r -p "Do you want to proceed with deletion? (yes/no): " confirm
  fi

  if [[ "$confirm" != "yes" ]]; then
    echo "Deletion cancelled"
    exit 0
  fi

  # Delete VM-related namespaced resources (PVCs handled in a dedicated step below)
  if [[ -s "$WORK_DIR/resources-list.txt" ]]; then
    if ! delete_resources; then
      echo -e "${RED}Error: Some resources failed to delete${NC}"
      exit 1
    fi
  else
    echo " No namespaced VM resources in list; proceeding with PVC/PV cleanup..."
  fi

  # Force-delete any leftover virt-launcher pods not in Running state
  cleanup_virt_launcher_pods

  # Remove PVCs and gitops-vms PVs on the non-primary spoke.
  # Skipped with --skip-pvcs: during a relocate the non-primary holds the active RBD
  # mirror source images; deleting them breaks VolumeGroupReplication promotion on the
  # returning primary. RamenDR demotes and cleans those PVCs itself once promotion
  # completes.
  if [[ "$SKIP_PVCS" -eq 1 ]]; then
    echo ""
    echo "Step 4: Skipping PVC deletion (--skip-pvcs). RamenDR will manage PVC cleanup."
    echo "Step 5: Skipping PV deletion (--skip-pvcs)."
  else
    if ! cleanup_pvcs; then
      echo -e "${RED}Error: PVC cleanup incomplete on $NON_PRIMARY_CLUSTER${NC}"
      exit 1
    fi

    if ! cleanup_gitops_pvs; then
      echo -e "${YELLOW}Warning: Some orphan PVs may remain on $NON_PRIMARY_CLUSTER${NC}"
      exit 1
    fi
  fi

  echo ""
  echo -e "${GREEN}✅ Cleanup completed successfully!${NC}"
  echo ""
  echo "Resources were deleted from:"
  echo " - Cluster: $NON_PRIMARY_CLUSTER"
  echo " - Namespace: $VM_NAMESPACE"
  if [[ "$SKIP_PVCS" -eq 1 ]]; then
    echo " (VMs/VMIs/Services/ExternalSecrets/DataVolumes only — PVCs/PVs preserved)"
  else
    echo " (includes all PVCs and gitops-vms-bound PVs)"
  fi
}

# Run main function
main "$@"
