#!/usr/bin/env bash
# Post-ODF golden image fix-up for spoke clusters.
#
# CNV may import common boot images to the cluster default SC (gp3-csi) before ODF
# is ready. After ODF converges, set the virt-default SC to ODF RBD and re-import
# golden images onto ODF. redeploy.sh runs this after spoke ODF GitOps converges and
# before wait_for_convergence (regional-dr / gitops-vms VM rollout).

: "${VIRT_SC_NAME:=ocs-storagecluster-ceph-rbd-virtualization}"
: "${OS_IMAGES_NS:=openshift-virtualization-os-images}"
: "${ODF_GOLDEN_IMAGE_WAIT_ATTEMPTS:=30}"
: "${ODF_GOLDEN_IMAGE_WAIT_SLEEP:=60}"
: "${ODF_GOLDEN_IMAGE_REFERENCE_DS:=rhel9}"
: "${SPOKE_ODF_STORAGE_WAIT_ATTEMPTS:=30}"
: "${SPOKE_ODF_STORAGE_WAIT_SLEEP:=30}"
: "${GITOPS_VMS_NS:=gitops-vms}"
: "${REPO_ROOT:?REPO_ROOT must be set}"
: "${HUB_OCP_VERSION:=4.22.1}"

_ogi_log() {
  if [[ $(type -t log) == function ]]; then
    log "$@"
  else
    echo "[golden-images] $*"
  fi
}

_ogi_warn() {
  if [[ $(type -t warn) == function ]]; then
    warn "$@"
  else
    echo "[golden-images] WARNING: $*" >&2
  fi
}

_ocp_minor_version() {
  echo "$HUB_OCP_VERSION" | cut -d. -f1,2
}

odf_storage_available() {
  local kubeconfig="$1"
  [[ "$(KUBECONFIG="$kubeconfig" oc get storagecluster ocs-storagecluster \
    -n openshift-storage \
    -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null || true)" == "True" ]]
}

virt_storage_class_exists() {
  local kubeconfig="$1"
  KUBECONFIG="$kubeconfig" oc get sc "$VIRT_SC_NAME" &>/dev/null
}

current_virt_default_storage_class() {
  local kubeconfig="$1"
  KUBECONFIG="$kubeconfig" oc get sc -o json 2>/dev/null | python3 -c "
import json, sys
for item in json.load(sys.stdin).get('items', []):
    ann = item.get('metadata', {}).get('annotations', {})
    if ann.get('storageclass.kubevirt.io/is-default-virt-class') == 'true':
        print(item['metadata']['name'])
        break
"
}

ensure_virt_default_storage_class() {
  local kubeconfig="$1" cluster="$2"
  local current

  if ! virt_storage_class_exists "$kubeconfig"; then
    _ogi_warn "[$cluster] StorageClass $VIRT_SC_NAME not found — skipping virt-default annotation."
    return 1
  fi

  current="$(current_virt_default_storage_class "$kubeconfig")"
  if [[ "$current" == "$VIRT_SC_NAME" ]]; then
    _ogi_log "[$cluster] Virt default storage class already $VIRT_SC_NAME."
    return 0
  fi

  _ogi_log "[$cluster] Setting virt default storage class to $VIRT_SC_NAME (was: ${current:-unset})."
  if [[ -n "$current" && "$current" != "$VIRT_SC_NAME" ]]; then
    KUBECONFIG="$kubeconfig" oc annotate sc "$current" \
      storageclass.kubevirt.io/is-default-virt-class- --overwrite 2>/dev/null || true
  fi
  KUBECONFIG="$kubeconfig" oc annotate sc "$VIRT_SC_NAME" \
    storageclass.kubevirt.io/is-default-virt-class=true --overwrite
}

golden_image_storage_class() {
  local kubeconfig="$1" datasource="$2"
  local pvc_name snap_name snap_class

  pvc_name="$(KUBECONFIG="$kubeconfig" oc get datasource "$datasource" -n "$OS_IMAGES_NS" \
    -o jsonpath='{.spec.source.pvc.name}' 2>/dev/null || true)"
  if [[ -n "$pvc_name" ]]; then
    KUBECONFIG="$kubeconfig" oc get pvc "$pvc_name" -n "$OS_IMAGES_NS" \
      -o jsonpath='{.spec.storageClassName}' 2>/dev/null
    return 0
  fi

  snap_name="$(KUBECONFIG="$kubeconfig" oc get datasource "$datasource" -n "$OS_IMAGES_NS" \
    -o jsonpath='{.spec.source.snapshot.name}' 2>/dev/null || true)"
  [[ -n "$snap_name" ]] || return 1
  snap_class="$(KUBECONFIG="$kubeconfig" oc get volumesnapshot "$snap_name" -n "$OS_IMAGES_NS" \
    -o jsonpath='{.spec.volumeSnapshotClassName}' 2>/dev/null || true)"
  if [[ "$snap_class" == "ocs-storagecluster-rbdplugin-snapclass" ]]; then
    echo "$VIRT_SC_NAME"
  else
    echo "$snap_class"
  fi
}

golden_image_pvc_storage_class() {
  golden_image_storage_class "$@"
}

datasource_ready_on_storage_class() {
  local kubeconfig="$1" datasource="$2" expected_sc="$3"
  local ready_msg sc

  ready_msg="$(KUBECONFIG="$kubeconfig" oc get datasource "$datasource" -n "$OS_IMAGES_NS" \
    -o jsonpath='{.status.conditions[?(@.type=="Ready")].message}' 2>/dev/null || true)"
  [[ "$ready_msg" == "DataSource is ready to be consumed" ]] || return 1

  sc="$(golden_image_storage_class "$kubeconfig" "$datasource")"
  [[ -n "$sc" && "$sc" == "$expected_sc" ]]
}

run_odf_fix_dataimportcrons_playbook() {
  local kubeconfig="$1" cluster="$2"
  local playbook="$REPO_ROOT/scripts/ansible/odf_fix_dataimportcrons.yml"
  local minor_version

  if [[ ! -f "$playbook" ]]; then
    _ogi_warn "[$cluster] Playbook not found: $playbook"
    return 1
  fi

  minor_version="$(_ocp_minor_version)"
  _ogi_log "[$cluster] Running odf_fix_dataimportcrons (OCP $minor_version)..."
  if ! command -v jq &>/dev/null; then
    _ogi_warn "[$cluster] jq not found — skipping ansible playbook step."
    return 0
  fi
  if KUBECONFIG="$kubeconfig" OCP_MINOR_VERSION="$minor_version" \
    ansible-playbook "$playbook" -e "cluster_version=${minor_version}"; then
    return 0
  fi

  _ogi_warn "[$cluster] odf_fix_dataimportcrons playbook failed."
  return 1
}

wait_for_golden_image_reimport() {
  local kubeconfig="$1" cluster="$2"
  local tries=0

  _ogi_log "[$cluster] Waiting for $ODF_GOLDEN_IMAGE_REFERENCE_DS golden image on $VIRT_SC_NAME..."
  while [[ $tries -lt $ODF_GOLDEN_IMAGE_WAIT_ATTEMPTS ]]; do
    if datasource_ready_on_storage_class "$kubeconfig" "$ODF_GOLDEN_IMAGE_REFERENCE_DS" "$VIRT_SC_NAME"; then
      _ogi_log "[$cluster] Golden image $ODF_GOLDEN_IMAGE_REFERENCE_DS is ready on $VIRT_SC_NAME."
      return 0
    fi
    tries=$((tries + 1))
    _ogi_log "[$cluster] Golden image not on $VIRT_SC_NAME yet (${tries}/${ODF_GOLDEN_IMAGE_WAIT_ATTEMPTS})..."
    sleep "$ODF_GOLDEN_IMAGE_WAIT_SLEEP"
  done

  _ogi_warn "[$cluster] Timed out waiting for golden image re-import on $VIRT_SC_NAME."
  return 1
}

force_golden_image_reimport() {
  local kubeconfig="$1" cluster="$2"
  local pvc_name pvc_sc

  _ogi_log "[$cluster] Removing golden images not on $VIRT_SC_NAME so CNV can re-import..."

  KUBECONFIG="$kubeconfig" oc delete dataimportcron --all -n "$OS_IMAGES_NS" --ignore-not-found --wait=false
  KUBECONFIG="$kubeconfig" oc delete datasource --all -n "$OS_IMAGES_NS" --ignore-not-found --wait=false
  KUBECONFIG="$kubeconfig" oc delete dv --all -n "$OS_IMAGES_NS" --ignore-not-found --wait=false
  KUBECONFIG="$kubeconfig" oc delete volumesnapshot --all -n "$OS_IMAGES_NS" --ignore-not-found --wait=false

  while read -r pvc_name pvc_sc; do
    [[ -n "$pvc_name" ]] || continue
    [[ "$pvc_sc" == "$VIRT_SC_NAME" ]] && continue
    _ogi_log "[$cluster] Deleting golden image PVC $pvc_name (storageClass=$pvc_sc)."
    KUBECONFIG="$kubeconfig" oc delete pvc "$pvc_name" -n "$OS_IMAGES_NS" --ignore-not-found --wait=false
  done < <(KUBECONFIG="$kubeconfig" oc get pvc -n "$OS_IMAGES_NS" \
    -o custom-columns=NAME:.metadata.name,SC:.spec.storageClassName --no-headers 2>/dev/null || true)
}

golden_images_need_cleanup() {
  local kubeconfig="$1"
  local pvc_name pvc_sc

  if datasource_ready_on_storage_class "$kubeconfig" "$ODF_GOLDEN_IMAGE_REFERENCE_DS" "$VIRT_SC_NAME"; then
    return 1
  fi

  while read -r pvc_name pvc_sc; do
    [[ -n "$pvc_name" ]] || continue
    [[ "$pvc_sc" != "$VIRT_SC_NAME" ]] && return 0
  done < <(KUBECONFIG="$kubeconfig" oc get pvc -n "$OS_IMAGES_NS" \
    -o custom-columns=NAME:.metadata.name,SC:.spec.storageClassName --no-headers 2>/dev/null || true)

  return 0
}

spoke_gitops_vms_exist() {
  local kubeconfig="$1"
  local count

  count="$(KUBECONFIG="$kubeconfig" oc get vm -n "$GITOPS_VMS_NS" --no-headers 2>/dev/null | wc -l)"
  count="${count// /}"
  [[ "${count:-0}" -gt 0 ]]
}

wait_for_spoke_odf_storage_available() {
  local kubeconfig="$1" cluster="$2"
  local tries=0

  while [[ $tries -lt $SPOKE_ODF_STORAGE_WAIT_ATTEMPTS ]]; do
    if odf_storage_available "$kubeconfig"; then
      _ogi_log "[$cluster] ODF StorageCluster is Available."
      return 0
    fi
    tries=$((tries + 1))
    _ogi_log "[$cluster] Waiting for ODF StorageCluster Available (${tries}/${SPOKE_ODF_STORAGE_WAIT_ATTEMPTS})..."
    sleep "$SPOKE_ODF_STORAGE_WAIT_SLEEP"
  done

  _ogi_warn "[$cluster] Timed out waiting for ODF StorageCluster Available."
  return 1
}

fix_spoke_golden_images() {
  local cluster="$1" install_dir="$2"
  local kubeconfig="$install_dir/auth/kubeconfig"

  if [[ ! -f "$kubeconfig" ]]; then
    _ogi_warn "[$cluster] Missing kubeconfig: $kubeconfig"
    return 1
  fi

  if ! wait_for_spoke_odf_storage_available "$kubeconfig" "$cluster"; then
    return 1
  fi

  if spoke_gitops_vms_exist "$kubeconfig"; then
    if datasource_ready_on_storage_class "$kubeconfig" "$ODF_GOLDEN_IMAGE_REFERENCE_DS" "$VIRT_SC_NAME"; then
      _ogi_log "[$cluster] gitops-vms VMs exist and golden images are already on $VIRT_SC_NAME — skipping."
      return 0
    fi
    _ogi_warn "[$cluster] gitops-vms VMs already exist — too late to re-import golden images on this spoke."
    _ogi_warn "[$cluster] Delete gitops-vms VMs first or redeploy from scratch to use ODF-backed golden images."
    return 1
  fi

  ensure_virt_default_storage_class "$kubeconfig" "$cluster" || return 1

  local cluster_default_sc
  cluster_default_sc="$(KUBECONFIG="$kubeconfig" oc get sc -o json 2>/dev/null | python3 -c "
import json, sys
for item in json.load(sys.stdin).get('items', []):
    ann = item.get('metadata', {}).get('annotations', {})
    if ann.get('storageclass.kubernetes.io/is-default-class') == 'true':
        print(item['metadata']['name'])
        break
")"

  if [[ "$cluster_default_sc" == "$VIRT_SC_NAME" ]]; then
    _ogi_log "[$cluster] Cluster default SC is already $VIRT_SC_NAME; verifying imported golden images."
  fi

  if datasource_ready_on_storage_class "$kubeconfig" "$ODF_GOLDEN_IMAGE_REFERENCE_DS" "$VIRT_SC_NAME"; then
    _ogi_log "[$cluster] Golden images already on $VIRT_SC_NAME — skipping cleanup."
    return 0
  fi

  run_odf_fix_dataimportcrons_playbook "$kubeconfig" "$cluster" || true
  if golden_images_need_cleanup "$kubeconfig" || \
    ! datasource_ready_on_storage_class "$kubeconfig" "$ODF_GOLDEN_IMAGE_REFERENCE_DS" "$VIRT_SC_NAME"; then
    force_golden_image_reimport "$kubeconfig" "$cluster"
  fi
  wait_for_golden_image_reimport "$kubeconfig" "$cluster" || return 1
}

fix_spoke_golden_images_on_all_spokes() {
  if [[ "${SKIP_ODF_GOLDEN_IMAGE_FIX:-0}" == "1" ]]; then
    _ogi_log "SKIP_ODF_GOLDEN_IMAGE_FIX=1 — skipping golden image fix-up."
    return 0
  fi

  if ! command -v ansible-playbook &>/dev/null; then
    _ogi_warn "ansible-playbook not found — using direct golden image cleanup only."
  fi

  if ! command -v jq &>/dev/null; then
    _ogi_warn "jq not found — ansible playbook step will be skipped if needed."
  fi

  local failed=0
  _ogi_log "Preparing spoke golden images on ODF before regional-dr deploys gitops-vms..."
  for entry in "ocp-primary:${PRIMARY_INSTALL_DIR}" "ocp-secondary:${SECONDARY_INSTALL_DIR}"; do
    local cluster="${entry%%:*}"
    local install_dir="${entry##*:}"
    if ! fix_spoke_golden_images "$cluster" "$install_dir"; then
      failed=1
    fi
  done

  if [[ "$failed" -ne 0 ]]; then
    _ogi_warn "Golden image fix-up did not fully succeed on all spokes (continuing redeploy)."
  fi
  return 0
}
