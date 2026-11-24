#!/bin/bash
set -euo pipefail

# Script to clean up the gitops-vms namespace on the non-primary
# (failed-over-from) cluster.
#
# DR validation note: run ONLY after failover/relocate is complete. Active VMs and
# timestamp logs live on the current primary — do not run if primary detection is
# wrong. For data checks after DR, use: ./scripts/dr-validation/check-after-dr.sh
#
# Two cleanup modes:
#
#   Default (post-DR / teardown): wipe the namespace on the non-primary spoke —
#   VirtualMachines, VMIs, Services, Routes, ExternalSecrets, DataVolumes, *all*
#   PVCs (clearing Ramen/CDI finalizers on stuck Terminating claims) and the PVs
#   those claims were bound to.
#
#   --skip-pvcs (in-flight failover/relocate): remove the *workload* but preserve
#   the *storage*. Only the non-primary spoke is touched. Kubernetes GC cascades
#   VirtualMachine -> DataVolume -> PVC through ownerReferences, so a plain VM
#   delete destroys the protected replica. This mode deletes each VM with
#   --cascade=orphan — GC drops the ownerReferences on the VMI and the
#   dataVolumeTemplates DataVolumes in the same operation — then deletes the VMI
#   explicitly so the virt-launcher pod stops and the PVC is released. Patching
#   ownerReferences beforehand is NOT used: the VM controller re-applies them
#   from spec.dataVolumeTemplates, which is a race we have lost in practice.
#   The orphaned DataVolumes stay in place; KubeVirt re-uses them when GitOps
#   re-creates the VM on this cluster (e.g. on relocate back). Only genuinely
#   unmanaged leftovers are deleted: additionalPvcDisks PVCs that no DV/VM owns,
#   no pod mounts, and no VGR/Ramen/CDI finalizer protects (plus the PVs they
#   were bound to). This covers the ODF known issue "some PVCs remain on the
#   primary cluster after failover".
#
#   --list-stuck-pvcs (read-only): print the claims the stuck classification
#   would delete, then exit. Used by the sanity test before it escalates to
#   --cleanup-stuck-pvcs, so the test never duplicates this classification.
#
#   --cleanup-stuck-pvcs (optional, combine with --skip-pvcs): additionally delete
#   PVCs left stuck on the failed-over-from cluster — claims already in
#   Terminating, or unprotected claims whose VolumeGroupReplication is gone and
#   that no pod mounts. Claims that are still members of a LIVE
#   VolumeGroupReplication are never selected: a Terminating claim that Ramen is
#   still demoting is mid-transition, not stuck. Clears Ramen/CDI finalizers only
#   for the claims it does delete. Use this for the ODF known issue where PVCs
#   remain on the old primary and block the next DR action; do NOT use it while a
#   demotion is still settling.
#
# What the DR flow expects (Ramen semantics):
#   * The user removes the *workload* on the cluster they failed over from; for
#     KubeVirt that means the VM/VMIs must stop so the PVC is released. That is
#     what clears "Secondary transition failed as PVC is potentially in use by a
#     pod" and lets the DRPC leave WaitOnUserToCleanUp.
#   * PVCs/DataVolumes are protected data, not garbage: Ramen demotes them to
#     secondary. Delete them only when Ramen reports them stuck (see
#     --cleanup-stuck-pvcs) or when this script runs in default (post-DR) mode.
#   * vm-recipe protected apps are auto-cleaned by Ramen itself (VRG
#     AutoCleanup=True); this script is for the volrep/GitOps path where it is
#     not supported.
#   * The script verifies the PlacementDecision before touching the spoke: once
#     placement has moved, GitOps will not recreate the VMs it just deleted
#     (which would re-lock the PVCs). --force skips that guard — use with care.
#
# Steps:
# 1. Determine the non-primary cluster from the DRPC PlacementDecision (fallback:
#    DRPC preferredCluster; override with a positional <cluster-name> argument).
# 2. List VM-related resources directly from that cluster.
# 3. Delete the workload (VirtualMachines/VMIs/Services/Routes/ExternalSecrets);
#    with --skip-pvcs, VMs go with --cascade=orphan and the DVs/PVCs are kept.
# 4. Delete PVCs: all of them in default mode; only unmanaged leftovers (and
#    stuck/unreleased ones with --cleanup-stuck-pvcs) with --skip-pvcs.
# 5. Remove PVs bound to the deleted claim names (Retain reclaim policy).
#
# Usage:
#   ./scripts/cleanup-gitops-vms-non-primary.sh                    # interactive full wipe
#   ./scripts/cleanup-gitops-vms-non-primary.sh --yes              # non-interactive full wipe
#   ./scripts/cleanup-gitops-vms-non-primary.sh --yes --skip-pvcs  # in-flight failover/relocate
#   ./scripts/cleanup-gitops-vms-non-primary.sh --yes --skip-pvcs --cleanup-stuck-pvcs
#   ./scripts/cleanup-gitops-vms-non-primary.sh --skip-pvcs --list-stuck-pvcs   # read-only

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
CLEANUP_STUCK_PVCS=0
LIST_STUCK_PVCS=0
CLUSTER_OVERRIDE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --yes | -y) AUTO_CONFIRM=yes; shift ;;
    --force) CLEANUP_FORCE=1; shift ;;
    --skip-pvcs) SKIP_PVCS=1; shift ;;
    --cleanup-stuck-pvcs) CLEANUP_STUCK_PVCS=1; shift ;;
    --list-stuck-pvcs) LIST_STUCK_PVCS=1; shift ;;
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

if [[ "$LIST_STUCK_PVCS" -eq 0 ]]; then
  echo "Running DRPC safety checks before cleanup..."
  if ! assert_safe_to_cleanup_non_primary "$CLEANUP_FORCE"; then
    echo -e "${RED}Cleanup blocked. Wait for DR to finish or use --force if you accept the risk.${NC}"
    exit 1
  fi
  echo ""
fi

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
  if [[ "$SKIP_PVCS" -eq 1 ]]; then
    echo " - DataVolumes: $DV_COUNT (preserved — orphaned by the VM delete, not deleted)"
  else
    echo " - DataVolumes: $DV_COUNT"
  fi
  echo " - DataSources: $DS_COUNT"
  if [[ "$SKIP_PVCS" -eq 1 ]]; then
    echo " - PersistentVolumeClaims: $PVC_COUNT (preserved unless unmanaged/stuck)"
  else
    echo " - PersistentVolumeClaims: $PVC_COUNT"
  fi

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

  # --skip-pvcs preserves storage: DataVolumes are never deleted explicitly and
  # VMs are deleted with --cascade=orphan (see the loop below), so GC cannot
  # cascade into the protected PVCs.
  local delete_list="$WORK_DIR/resources-list.txt"
  if [[ "$SKIP_PVCS" -eq 1 ]]; then
    delete_list="$WORK_DIR/resources-to-delete.txt"
    grep -v '^DataVolume|' "$WORK_DIR/resources-list.txt" > "$delete_list" || true
    if [[ ! -s "$delete_list" ]]; then
      echo " No workload resources to delete (DataVolumes preserved)"
      return 0
    fi
  fi

  local deleted_count=0
  local error_count=0

  while IFS='|' read -r kind name; do
    if [[ -z "$kind" || -z "$name" ]]; then
      continue
    fi

    echo " Deleting: $kind/$name in namespace $VM_NAMESPACE"

    local ok=0
    if [[ "$SKIP_PVCS" -eq 1 && "$kind" == "VirtualMachine" ]]; then
      # Orphan dependents at delete time (one GC operation) so the
      # dataVolumeTemplates DataVolumes and their PVCs survive, then stop the
      # VMI explicitly. Patching ownerReferences before the delete races with
      # the VM controller, which re-applies them from spec.dataVolumeTemplates.
      if oc --kubeconfig="$KUBECONFIG" delete "$kind" "$name" -n "$VM_NAMESPACE" \
        --cascade=orphan --ignore-not-found &>/dev/null; then
        echo -e " ${GREEN}✅ Deleted (orphaned DV/PVC): $kind/$name${NC}"
        if oc --kubeconfig="$KUBECONFIG" delete vmi "$name" -n "$VM_NAMESPACE" \
          --ignore-not-found &>/dev/null; then
          echo -e " ${GREEN}✅ Stopped VMI: $name${NC}"
          ok=1
        else
          echo -e " ${RED}❌ Failed to stop VMI: $name${NC}"
        fi
      else
        echo -e " ${RED}❌ Failed to delete: $kind/$name${NC}"
      fi
    elif oc --kubeconfig="$KUBECONFIG" delete "$kind" "$name" -n "$VM_NAMESPACE" --ignore-not-found &>/dev/null; then
      echo -e " ${GREEN}✅ Deleted: $kind/$name${NC}"
      ok=1
    else
      echo -e " ${RED}❌ Failed to delete: $kind/$name${NC}"
    fi

    if [[ $ok -eq 1 ]]; then
      deleted_count=$((deleted_count + 1))
    else
      error_count=$((error_count + 1))
    fi
  done < "$delete_list"

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

# Print PVC names mounted by any pod in the namespace. Never delete these.
list_pvc_claims_in_use() {
  local pods
  if ! pods=$(oc --kubeconfig="$KUBECONFIG" get pods -n "$VM_NAMESPACE" -o json 2>/dev/null); then
    echo -e "${RED}❌ Could not list pods in $VM_NAMESPACE; refusing to guess PVC usage${NC}" >&2
    return 1
  fi

  printf '%s' "$pods" | python3 -c '
import json, sys

data = json.load(sys.stdin)
names = set()
for pod in data.get("items", []):
    for vol in (pod.get("spec", {}).get("volumes") or []):
        claim = (vol or {}).get("persistentVolumeClaim") or {}
        name = claim.get("claimName")
        if name:
            names.add(name)
for name in sorted(names):
    print(name)
'
}

# Print PVC names that are safe leftovers: mounted by no pod, not owned by a
# DataVolume/VirtualMachine, and not protected by a VGR/Ramen/CDI finalizer.
# These are the additionalPvcDisks orphans that can block WaitOnUserToCleanUp
# after failover once the VMs are gone.
list_unmanaged_pvcs() {
  local in_use="$1"
  local pvcs
  if ! pvcs=$(oc --kubeconfig="$KUBECONFIG" get pvc -n "$VM_NAMESPACE" -o json 2>/dev/null); then
    echo -e "${RED}❌ Could not list PVCs in $VM_NAMESPACE${NC}" >&2
    return 1
  fi

  printf '%s' "$pvcs" | python3 -c '
import json, sys

OWNED_KINDS = {"DataVolume", "VirtualMachine"}
# Finalizer substrings that mark DV-backed / replicated disks still needed by Ramen.
PROTECTED_FINALIZER_MARKERS = (
    "volumereplication",
    "vgr-protection",
    "ramendr",
    "cdi.kubevirt.io",
)

in_use = {n for n in sys.argv[1].splitlines() if n.strip()}
data = json.load(sys.stdin)
for item in data.get("items", []):
    md = item.get("metadata") or {}
    name = md.get("name") or ""
    if not name or name in in_use:
        continue
    refs = md.get("ownerReferences") or []
    if any((ref or {}).get("kind") in OWNED_KINDS for ref in refs):
        continue
    finals = md.get("finalizers") or []
    if any(any(marker in f for marker in PROTECTED_FINALIZER_MARKERS) for f in finals):
        continue
    print(name)
' "$in_use"
}

# Print PVCs left behind on the failed-over-from cluster (ODF known issue:
# "some PVCs remain in the primary cluster after failover"):
#   * claims already deleting that are NOT member of a live VolumeGroupReplication, or
#   * unprotected, pod-less claims whose VolumeGroupReplication is gone.
# Never returns claims a pod still mounts, nor live group members (a Terminating
# claim Ramen is still demoting is mid-transition, not stuck).
list_stuck_pvcs() {
  local in_use="$1"
  local live_vgrs="$2"
  local pvcs
  if ! pvcs=$(oc --kubeconfig="$KUBECONFIG" get pvc -n "$VM_NAMESPACE" -o json 2>/dev/null); then
    echo -e "${RED}❌ Could not list PVCs in $VM_NAMESPACE${NC}" >&2
    return 1
  fi

  printf '%s' "$pvcs" | python3 -c '
import json, sys

OWNED_KINDS = {"DataVolume", "VirtualMachine"}
PROTECTED_FINALIZER_MARKERS = (
    "volumereplication",
    "vgr-protection",
    "ramendr",
    "cdi.kubevirt.io",
)

in_use = {n for n in sys.argv[1].splitlines() if n.strip()}
live_vgrs = {n for n in sys.argv[2].splitlines() if n.strip()}
data = json.load(sys.stdin)
for item in data.get("items", []):
    md = item.get("metadata") or {}
    name = md.get("name") or ""
    if not name or name in in_use:
        continue
    labels = md.get("labels") or {}
    vgr_owner = labels.get("volumegroupreplication-owner", "")
    if md.get("deletionTimestamp"):
        # A Terminating claim that is still a member of a live VGR is being
        # demoted by Ramen; deleting it would destroy the replica mid-flight.
        if vgr_owner and vgr_owner in live_vgrs:
            continue
        print(name)
        continue
    if not labels.get("ramendr.openshift.io/consistency-group"):
        continue
    refs = md.get("ownerReferences") or []
    if any((ref or {}).get("kind") in OWNED_KINDS for ref in refs):
        continue
    if vgr_owner in live_vgrs:
        continue
    finals = md.get("finalizers") or []
    if any(any(marker in f for marker in PROTECTED_FINALIZER_MARKERS) for f in finals):
        continue
    print(name)
' "$in_use" "$live_vgrs"
}

# Read-only: print the claims the --cleanup-stuck-pvcs classification would
# delete, one "STUCK_PVC=<name>" line each. Never deletes anything.
report_stuck_pvcs() {
  echo ""
  echo "Stuck leftover PVCs in namespace $VM_NAMESPACE on cluster $NON_PRIMARY_CLUSTER:"

  local in_use live_vgrs pvcs count=0
  if ! in_use=$(list_pvc_claims_in_use); then
    return 1
  fi
  if ! live_vgrs=$(list_live_vgrs); then
    return 1
  fi
  if ! pvcs=$(list_stuck_pvcs "$in_use" "$live_vgrs"); then
    return 1
  fi

  while IFS= read -r pvc; do
    [[ -z "$pvc" ]] && continue
    echo "STUCK_PVC=$pvc"
    count=$((count + 1))
  done <<< "$pvcs"
  echo " Stuck PVC count: $count"
}

# Print the VolumeGroupReplication names that still exist in the namespace.
list_live_vgrs() {
  if ! oc --kubeconfig="$KUBECONFIG" get volumegroupreplication -n "$VM_NAMESPACE" \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null; then
    echo -e "${RED}❌ Could not list VolumeGroupReplications in $VM_NAMESPACE${NC}" >&2
    return 1
  fi
}

# Delete a specific set of PVC names; clear finalizers when stuck Terminating.
# Args: descriptive label, then PVC names (one per line via stdin or as "$@" after label).
delete_named_pvcs() {
  local label="$1"
  shift
  local pvcs="" pvc
  if [[ $# -gt 0 ]]; then
    pvcs=$(printf '%s\n' "$@")
  else
    pvcs=$(cat)
  fi

  local deleted_count=0 error_count=0
  if [[ -z "${pvcs//[$'\n']/}" ]]; then
    echo " No ${label} PVCs found"
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

  local pass stuck expected
  expected="$pvcs"
  for pass in 1 2 3 4 5 6; do
    stuck=$(oc --kubeconfig="$KUBECONFIG" get pvc -n "$VM_NAMESPACE" -o json 2>/dev/null \
      | python3 -c "
import json, sys
want = {n for n in sys.argv[1].splitlines() if n.strip()}
data = json.load(sys.stdin)
for item in data.get('items', []):
    name = item['metadata']['name']
    if name in want:
        print(name)
" "$expected" 2>/dev/null || true)
    if [[ -z "$stuck" ]]; then
      break
    fi
    if [[ $pass -gt 1 ]]; then
      echo " Pass $pass — $(echo "$stuck" | grep -c .) ${label} PVC(s) still present"
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
  remaining=$(oc --kubeconfig="$KUBECONFIG" get pvc -n "$VM_NAMESPACE" -o json 2>/dev/null \
    | python3 -c "
import json, sys
want = {n for n in sys.argv[1].splitlines() if n.strip()}
data = json.load(sys.stdin)
print(sum(1 for i in data.get('items', []) if i['metadata']['name'] in want))
" "$expected" 2>/dev/null || echo 0)
  remaining=${remaining:-0}
  if [[ "$remaining" -gt 0 ]]; then
    echo -e "${RED} ❌ $remaining ${label} PVC(s) still remain in $VM_NAMESPACE${NC}"
    oc --kubeconfig="$KUBECONFIG" get pvc -n "$VM_NAMESPACE" 2>/dev/null || true
    return 1
  fi

  echo -e "${GREEN} ✅ ${label} PVCs removed from $VM_NAMESPACE ($deleted_count delete requests)${NC}"
  [[ $error_count -eq 0 ]]
}

# Delete all PVCs in gitops-vms. Ramen DR finalizers often leave PVCs stuck in Terminating
# after VM/DataVolume deletion on the non-primary spoke; clear finalizers when needed.
cleanup_pvcs() {
  echo ""
  echo "Step 4: Deleting all PVCs in namespace $VM_NAMESPACE..."

  local pvcs
  pvcs=$(oc --kubeconfig="$KUBECONFIG" get pvc -n "$VM_NAMESPACE" \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null || true)
  delete_named_pvcs "all" <<< "$pvcs"
}

# Delete unmanaged leftover PVCs. Used with --skip-pvcs so failover cleanup can
# clear WaitOnUserToCleanUp without touching DV/VM-owned or VGR-protected disks.
# Args: PVC names (one per line).
cleanup_unmanaged_pvcs() {
  local pvcs="$1"
  echo ""
  echo "Step 4: Deleting unmanaged (pod-less, non-VM/DV-owned) leftover PVCs in $VM_NAMESPACE..."
  echo " (preserves DataVolume/VirtualMachine-owned and VGR/Ramen/CDI-protected PVCs)"

  if [[ -z "${pvcs//[$'\n']/}" ]]; then
    echo " No unmanaged leftover PVCs found"
    return 0
  fi
  echo " Unmanaged leftover PVC(s):"
  while IFS= read -r pvc; do
    [[ -z "$pvc" ]] && continue
    echo "  - $pvc"
  done <<< "$pvcs"

  delete_named_pvcs "unmanaged" <<< "$pvcs"
}

# Delete PVCs left stuck on the failed-over-from cluster (ODF known issue).
# Args: PVC names (one per line).
cleanup_stuck_leftover_pvcs() {
  local pvcs="$1"
  echo ""
  echo "Step 4b: Deleting PVCs left stuck on the failed-over-from cluster..."
  echo " (claims in Terminating, or unprotected claims whose VGR is gone)"

  if [[ -z "${pvcs//[$'\n']/}" ]]; then
    echo " No stuck leftover PVCs found"
    return 0
  fi
  echo " Stuck leftover PVC(s):"
  while IFS= read -r pvc; do
    [[ -z "$pvc" ]] && continue
    echo "  - $pvc"
  done <<< "$pvcs"

  delete_named_pvcs "stuck leftover" <<< "$pvcs"
}

# Remove PVs that were bound to specific PVC claim names in gitops-vms.
cleanup_pvs_for_claims() {
  local claims="$1"
  echo ""
  echo "Step 5: Removing orphan PVs for deleted standalone PVC claim(s)..."

  if [[ -z "${claims//[$'\n']/}" ]]; then
    echo " No claim names to match"
    return 0
  fi

  local pvs deleted_count=0
  pvs=$(oc --kubeconfig="$KUBECONFIG" get pv -o json 2>/dev/null \
    | python3 -c "
import json, sys
ns = sys.argv[1]
want = {n for n in sys.argv[2].splitlines() if n.strip()}
data = json.load(sys.stdin)
for item in data.get('items', []):
    ref = item.get('spec', {}).get('claimRef') or {}
    if ref.get('namespace') == ns and ref.get('name') in want:
        print(item['metadata']['name'])
" "$VM_NAMESPACE" "$claims" 2>/dev/null || true)

  if [[ -z "$pvs" ]]; then
    echo " No PVs bound to deleted standalone claims"
    return 0
  fi

  while IFS= read -r pv; do
    [[ -z "$pv" ]] && continue
    echo " Deleting PV: $pv"
    if oc --kubeconfig="$KUBECONFIG" delete pv "$pv" --ignore-not-found --wait=false &>/dev/null; then
      if oc --kubeconfig="$KUBECONFIG" get pv "$pv" &>/dev/null; then
        echo " Clearing finalizers on stuck PV: $pv"
        oc --kubeconfig="$KUBECONFIG" patch pv "$pv" \
          --type=merge -p '{"metadata":{"finalizers":null}}' &>/dev/null || true
      fi
      deleted_count=$((deleted_count + 1))
    else
      echo -e " ${YELLOW} ⚠️ Failed to delete PV: $pv${NC}"
    fi
  done <<< "$pvs"

  local remaining=0 try
  for try in 1 2 3 4 5 6; do
    remaining=$(oc --kubeconfig="$KUBECONFIG" get pv -o json 2>/dev/null \
      | python3 -c "
import json, sys
ns = sys.argv[1]
want = {n for n in sys.argv[2].splitlines() if n.strip()}
data = json.load(sys.stdin)
print(sum(1 for i in data.get('items', [])
    if (i.get('spec', {}).get('claimRef') or {}).get('namespace') == ns
    and (i.get('spec', {}).get('claimRef') or {}).get('name') in want))
" "$VM_NAMESPACE" "$claims" 2>/dev/null || echo 0)
    remaining=${remaining:-0}
    [[ "$remaining" -eq 0 ]] && break
    [[ "$try" -lt 6 ]] && sleep 5
  done
  if [[ "$remaining" -gt 0 ]]; then
    echo -e "${YELLOW} ⚠️ $remaining PV(s) for standalone claims still remain${NC}"
    return 1
  fi
  echo -e "${GREEN} ✅ Removed $deleted_count orphan PV(s) for standalone claims${NC}"
  return 0
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

  # Read-only mode: report what --cleanup-stuck-pvcs would delete and exit.
  if [[ "$LIST_STUCK_PVCS" -eq 1 ]]; then
    if ! report_stuck_pvcs; then
      echo -e "${RED}Error: could not classify stuck PVCs on $NON_PRIMARY_CLUSTER${NC}" >&2
      exit 1
    fi
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
  if [[ "$SKIP_PVCS" -eq 1 ]]; then
    echo " Mode: --skip-pvcs — workload only; DataVolumes/PVCs are preserved"
    if [[ "$CLEANUP_STUCK_PVCS" -eq 1 ]]; then
      echo "       plus --cleanup-stuck-pvcs (stuck/unreleased PVCs)"
    fi
  else
    echo " Mode: full wipe — workload + DataVolumes + all PVCs + orphan PVs"
  fi
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
  # --skip-pvcs: preserve DV/VM-owned and VGR-protected PVCs (needed for relocate /
  # demotion), but still delete unmanaged additionalPvcDisks leftovers that block
  # WaitOnUserToCleanUp after failover. Optionally also delete stuck/unreleased
  # PVCs left behind by a completed failover (ODF known issue).
  if [[ "$SKIP_PVCS" -eq 1 ]]; then
    local in_use unmanaged_pvcs stuck_pvcs live_vgrs
    if ! in_use=$(list_pvc_claims_in_use); then
      echo -e "${RED}Error: cannot determine which PVCs are in use on $NON_PRIMARY_CLUSTER${NC}"
      echo " Refusing to delete any PVC without that information."
      exit 1
    fi
    if ! unmanaged_pvcs=$(list_unmanaged_pvcs "$in_use"); then
      echo -e "${RED}Error: could not list PVCs on $NON_PRIMARY_CLUSTER${NC}"
      exit 1
    fi
    if ! cleanup_unmanaged_pvcs "$unmanaged_pvcs"; then
      echo -e "${RED}Error: unmanaged PVC cleanup incomplete on $NON_PRIMARY_CLUSTER${NC}"
      exit 1
    fi
    cleanup_pvs_for_claims "$unmanaged_pvcs" || \
      echo -e "${YELLOW}Warning: Some orphan PVs for unmanaged claims may remain${NC}"

    if [[ "$CLEANUP_STUCK_PVCS" -eq 1 ]]; then
      if ! in_use=$(list_pvc_claims_in_use) || ! live_vgrs=$(list_live_vgrs); then
        echo -e "${RED}Error: could not inspect PVC usage/VolumeGroupReplications on $NON_PRIMARY_CLUSTER${NC}"
        exit 1
      fi
      if ! stuck_pvcs=$(list_stuck_pvcs "$in_use" "$live_vgrs"); then
        echo -e "${RED}Error: could not list PVCs on $NON_PRIMARY_CLUSTER${NC}"
        exit 1
      fi
      if ! cleanup_stuck_leftover_pvcs "$stuck_pvcs"; then
        echo -e "${RED}Error: stuck PVC cleanup incomplete on $NON_PRIMARY_CLUSTER${NC}"
        exit 1
      fi
      cleanup_pvs_for_claims "$stuck_pvcs" || \
        echo -e "${YELLOW}Warning: Some orphan PVs for stuck claims may remain${NC}"
    fi
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
    echo " (VMs deleted with --cascade=orphan, VMIs stopped; DataVolumes/PVCs preserved"
    echo "  so VGR demotion/promotion can complete; unmanaged leftover PVCs and their"
    echo "  PVs removed)"
    if [[ "$CLEANUP_STUCK_PVCS" -eq 1 ]]; then
      echo " (stuck/unreleased PVCs left on the failed-over-from cluster also removed)"
    fi
  else
    echo " (includes all DataVolumes, PVCs and gitops-vms-bound PVs)"
  fi
}

# Run main function
main "$@"
