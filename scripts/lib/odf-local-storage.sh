#!/usr/bin/env bash
# shellcheck shell=bash
# Local-disk ODF for libvirt/baremetal: LSO LocalVolume on /dev/vdb, overlay copy,
# and StorageCluster patch away from gp3-csi.

: "${ODF_LOCAL_STORAGE_CLASS:=localblock}"
: "${ODF_LOCAL_DEVICE:=/dev/vdb}"
: "${ODF_LOCAL_OSD_SIZE:=100Gi}"
: "${ODF_LOCAL_OPERATOR_NAMESPACE:=openshift-local-storage}"

libvirt_odf_overlay_src() {
  echo "${REPO_ROOT}/overrides/libvirt"
}

install_libvirt_odf_overlays() {
  local src dest
  src="$(libvirt_odf_overlay_src)"
  dest="${UPSTREAM_DIR}/overrides"
  [[ -d "$src" ]] || { warn "No libvirt ODF overlays at $src"; return 0; }
  mkdir -p "$dest"
  local f
  for f in values-None.yaml values-BareMetal.yaml; do
    if [[ -f "$src/$f" ]]; then
      cp "$src/$f" "$dest/$f"
      log "Installed fork overlay $f into local checkout (Argo CD still needs this on the git remote)."
    fi
  done
}

ensure_lso_operator() {
  local kubeconfig="$1" cluster="$2"
  if KUBECONFIG="$kubeconfig" oc get crd localvolumes.local.storage.openshift.io >/dev/null 2>&1; then
    log "[odf-local][$cluster] Local Storage Operator CRD already present."
    return 0
  fi
  log "[odf-local][$cluster] Installing Local Storage Operator..."
  KUBECONFIG="$kubeconfig" oc apply -f - <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: ${ODF_LOCAL_OPERATOR_NAMESPACE}
---
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: local-storage
  namespace: ${ODF_LOCAL_OPERATOR_NAMESPACE}
spec:
  targetNamespaces:
    - ${ODF_LOCAL_OPERATOR_NAMESPACE}
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: local-storage-operator
  namespace: ${ODF_LOCAL_OPERATOR_NAMESPACE}
spec:
  channel: stable
  name: local-storage-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
EOF
  local tries=0
  while [[ $tries -lt 40 ]]; do
    if KUBECONFIG="$kubeconfig" oc get crd localvolumes.local.storage.openshift.io >/dev/null 2>&1; then
      log "[odf-local][$cluster] LocalVolume CRD is ready."
      return 0
    fi
    sleep 15
    tries=$((tries + 1))
  done
  err "[odf-local][$cluster] Local Storage Operator CRD did not appear."
  return 1
}

ensure_localvolume() {
  local kubeconfig="$1" cluster="$2"
  log "[odf-local][$cluster] Applying LocalVolume for ${ODF_LOCAL_DEVICE} -> ${ODF_LOCAL_STORAGE_CLASS}..."
  KUBECONFIG="$kubeconfig" oc apply -f - <<EOF
apiVersion: local.storage.openshift.io/v1
kind: LocalVolume
metadata:
  name: ${ODF_LOCAL_STORAGE_CLASS}
  namespace: ${ODF_LOCAL_OPERATOR_NAMESPACE}
spec:
  storageClassDevices:
    - storageClassName: ${ODF_LOCAL_STORAGE_CLASS}
      volumeMode: Block
      devicePaths:
        - ${ODF_LOCAL_DEVICE}
EOF
}

wait_local_storage_class() {
  local kubeconfig="$1" cluster="$2" tries=0
  while [[ $tries -lt 40 ]]; do
    if KUBECONFIG="$kubeconfig" oc get sc "$ODF_LOCAL_STORAGE_CLASS" >/dev/null 2>&1; then
      log "[odf-local][$cluster] StorageClass ${ODF_LOCAL_STORAGE_CLASS} is present."
      return 0
    fi
    sleep 15
    tries=$((tries + 1))
  done
  err "[odf-local][$cluster] StorageClass ${ODF_LOCAL_STORAGE_CLASS} did not appear. Attach unused ${ODF_LOCAL_DEVICE} on each node."
  return 1
}

fail_if_only_gp3() {
  local kubeconfig="$1" cluster="$2"
  local classes
  classes="$(KUBECONFIG="$kubeconfig" oc get sc -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || true)"
  if [[ "$classes" == *gp3-csi* && "$classes" != *"$ODF_LOCAL_STORAGE_CLASS"* ]]; then
    err "[odf-local][$cluster] Only cloud class gp3-csi is present; local ODF cannot proceed."
    return 1
  fi
  return 0
}

patch_odf_storagecluster_local() {
  local kubeconfig="$1" cluster="$2"
  if ! KUBECONFIG="$kubeconfig" oc get storagecluster ocs-storagecluster \
    -n openshift-storage >/dev/null 2>&1; then
    return 0
  fi
  log "[odf-local][$cluster] Patching StorageCluster to ${ODF_LOCAL_STORAGE_CLASS} portable=false + monDataDirHostPath..."
  # LSO localblock is volumeMode:Block (OSDs). Ceph mon PVCs are Filesystem and
  # never bind to those PVs — use hostPath for mons on compact libvirt nodes.
  KUBECONFIG="$kubeconfig" oc get storagecluster ocs-storagecluster \
    -n openshift-storage -o json | python3 -c "
import json, sys
sc = json.load(sys.stdin)
spec = sc.setdefault('spec', {})
spec['monDataDirHostPath'] = '/var/lib/rook'
sets = spec.setdefault('storageDeviceSets', [])
for ds in sets:
    ds['portable'] = False
    tpl = ds.setdefault('dataPVCTemplate', {}).setdefault('spec', {})
    tpl['storageClassName'] = '${ODF_LOCAL_STORAGE_CLASS}'
    tpl['volumeMode'] = 'Block'
    res = tpl.setdefault('resources', {}).setdefault('requests', {})
    res['storage'] = '${ODF_LOCAL_OSD_SIZE}'
# Drop monPVCTemplate if present — hostPath mons do not use PVCs.
spec.pop('monPVCTemplate', None)
print(json.dumps(sc))
" | KUBECONFIG="$kubeconfig" oc apply -f - >/dev/null

  # Pending Filesystem mon PVCs on localblock will never bind; delete so Rook
  # can switch to monDataDirHostPath.
  local mon_pvc
  while IFS= read -r mon_pvc; do
    [[ -n "$mon_pvc" ]] || continue
    local mode sc_name phase
    mode="$(KUBECONFIG="$kubeconfig" oc get pvc "$mon_pvc" -n openshift-storage \
      -o jsonpath='{.spec.volumeMode}' 2>/dev/null || true)"
    sc_name="$(KUBECONFIG="$kubeconfig" oc get pvc "$mon_pvc" -n openshift-storage \
      -o jsonpath='{.spec.storageClassName}' 2>/dev/null || true)"
    phase="$(KUBECONFIG="$kubeconfig" oc get pvc "$mon_pvc" -n openshift-storage \
      -o jsonpath='{.status.phase}' 2>/dev/null || true)"
    if [[ "$phase" == "Pending" && "$sc_name" == "$ODF_LOCAL_STORAGE_CLASS" && "$mode" == "Filesystem" ]]; then
      log "[odf-local][$cluster] Deleting stuck mon PVC ${mon_pvc} (Filesystem on Block class)..."
      KUBECONFIG="$kubeconfig" oc delete pvc "$mon_pvc" -n openshift-storage --wait=false >/dev/null 2>&1 || true
    fi
  done < <(KUBECONFIG="$kubeconfig" oc get pvc -n openshift-storage \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null | grep '^rook-ceph-mon-' || true)
}

bootstrap_odf_local_storage_cluster() {
  local kubeconfig="$1" cluster="$2"
  [[ -f "$kubeconfig" ]] || { warn "[odf-local] No kubeconfig for $cluster"; return 0; }
  ensure_lso_operator "$kubeconfig" "$cluster"
  ensure_localvolume "$kubeconfig" "$cluster" || true
  wait_local_storage_class "$kubeconfig" "$cluster" || return 1
  fail_if_only_gp3 "$kubeconfig" "$cluster" || return 1
  patch_odf_storagecluster_local "$kubeconfig" "$cluster" || true
}

bootstrap_odf_local_storage_all() {
  [[ "${REDEPLOY_PLATFORM:-aws}" == "libvirt" ]] || return 0
  log "Bootstrapping local-disk ODF (LSO ${ODF_LOCAL_STORAGE_CLASS} on ${ODF_LOCAL_DEVICE})..."
  local entry cluster dir
  for entry in "hub:$HUB_INSTALL_DIR" "ocp-primary:$PRIMARY_INSTALL_DIR" "ocp-secondary:$SECONDARY_INSTALL_DIR"; do
    cluster="${entry%%:*}"
    dir="${entry##*:}"
    bootstrap_odf_local_storage_cluster "$dir/auth/kubeconfig" "$cluster" || return 1
  done
}

# StorageCluster appears only after GitOps syncs odf. Patch monDataDirHostPath as
# soon as the CR exists so install-byoc's Argo wait is not blocked on Pending mon PVCs.
libvirt_odf_storagecluster_patch_watch() {
  [[ "${REDEPLOY_PLATFORM:-aws}" == "libvirt" ]] || return 0
  (
    local entry cluster dir
    for _ in $(seq 1 120); do
      for entry in "hub:$HUB_INSTALL_DIR" "ocp-primary:$PRIMARY_INSTALL_DIR" "ocp-secondary:$SECONDARY_INSTALL_DIR"; do
        cluster="${entry%%:*}"
        dir="${entry##*:}"
        [[ -f "$dir/auth/kubeconfig" ]] || continue
        patch_odf_storagecluster_local "$dir/auth/kubeconfig" "$cluster" >/dev/null 2>&1 || true
      done
      sleep 15
    done
  ) &
  log "[odf-local] Background StorageCluster mon/OSD patcher armed (pid $!)."
}

copy_libvirt_odf_overlays_if_needed() {
  [[ "${REDEPLOY_PLATFORM:-aws}" == "libvirt" ]] || return 0
  install_libvirt_odf_overlays
}

# Vault (and other RWO filesystem PVCs) cannot use LSO localblock (volumeMode:
# Block, for ODF OSDs). Until ODF ceph-rbd/cephfs exists, provide a hostPath
# default StorageClass + a pre-bound-size PV so vault-0 can schedule.
: "${LIBVIRT_FILESYSTEM_STORAGE_CLASS:=ramendr-hostpath}"
: "${LIBVIRT_VAULT_PV_SIZE:=10Gi}"
: "${LIBVIRT_VAULT_HOSTPATH:=/var/lib/ramendr-vault/data}"

# hostPath DirectoryOrCreate makes root:root 0755 + container_var_lib_t. Vault runs
# as the namespace arbitrary UID and cannot mkdir /vault/data/core → never
# initializes → install-byoc sees "Vault is sealed". Seed every hub node before
# the chart creates the pod (we do not know the schedule target yet).
seed_libvirt_vault_hostpath_on_hub_nodes() {
  local kubeconfig="${1:-$HUB_INSTALL_DIR/auth/kubeconfig}"
  local hp node
  hp="${LIBVIRT_VAULT_HOSTPATH}"

  log "[libvirt-fs] Seeding vault hostPath ${hp} on all hub nodes (0777 + container_file_t)..."
  while IFS= read -r node; do
    [[ -n "$node" ]] || continue
    if ! KUBECONFIG="$kubeconfig" oc debug "node/${node}" --to-namespace=default -- \
      chroot /host sh -c "
        mkdir -p '${hp}'
        chmod 0777 '${hp}'
        chcon -R -t container_file_t '${hp}' 2>/dev/null || true
        ls -laZ '${hp}'
      "; then
      warn "[libvirt-fs] Failed to seed vault hostPath on ${node}"
    fi
  done < <(KUBECONFIG="$kubeconfig" oc get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null)
}

ensure_libvirt_hub_filesystem_storage() {
  local kubeconfig="${1:-$HUB_INSTALL_DIR/auth/kubeconfig}"
  [[ "${REDEPLOY_PLATFORM:-aws}" == "libvirt" ]] || return 0
  [[ -f "$kubeconfig" ]] || { warn "[libvirt-fs] No hub kubeconfig"; return 0; }

  local default_sc
  default_sc="$(KUBECONFIG="$kubeconfig" oc get sc \
    -o jsonpath='{range .items[?(@.metadata.annotations.storageclass\.kubernetes\.io/is-default-class=="true")]}{.metadata.name}{"\n"}{end}' \
    2>/dev/null | head -1 || true)"

  if [[ -n "$default_sc" && "$default_sc" != "$LIBVIRT_FILESYSTEM_STORAGE_CLASS" ]]; then
    log "[libvirt-fs] Default StorageClass already set: $default_sc"
  else
    log "[libvirt-fs] Ensuring filesystem StorageClass ${LIBVIRT_FILESYSTEM_STORAGE_CLASS} (default)..."
    KUBECONFIG="$kubeconfig" oc apply -f - <<EOF
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: ${LIBVIRT_FILESYSTEM_STORAGE_CLASS}
  annotations:
    storageclass.kubernetes.io/is-default-class: "true"
provisioner: kubernetes.io/no-provisioner
reclaimPolicy: Delete
volumeBindingMode: Immediate
EOF
  fi

  if ! KUBECONFIG="$kubeconfig" oc get pv data-vault-0-ramendr-hostpath >/dev/null 2>&1; then
    log "[libvirt-fs] Creating hostPath PV for vault (${LIBVIRT_VAULT_PV_SIZE})..."
    KUBECONFIG="$kubeconfig" oc apply -f - <<EOF
apiVersion: v1
kind: PersistentVolume
metadata:
  name: data-vault-0-ramendr-hostpath
  labels:
    ramendr.validatedpatterns.io/libvirt-vault: "true"
spec:
  capacity:
    storage: ${LIBVIRT_VAULT_PV_SIZE}
  accessModes:
    - ReadWriteOnce
  persistentVolumeReclaimPolicy: Retain
  storageClassName: ${LIBVIRT_FILESYSTEM_STORAGE_CLASS}
  volumeMode: Filesystem
  hostPath:
    path: ${LIBVIRT_VAULT_HOSTPATH}
    type: DirectoryOrCreate
EOF
  fi

  # Must run before install-byoc: vault is not scheduled yet, so the old wait
  # for vault-0 always timed out and never fixed permissions.
  seed_libvirt_vault_hostpath_on_hub_nodes "$kubeconfig" || true

  # Pending vault PVC was created with no storageClassName (immutable). Recreate
  # so the STS picks up the default filesystem class and binds the hostPath PV.
  local pvc_phase pvc_sc
  pvc_phase="$(KUBECONFIG="$kubeconfig" oc get pvc data-vault-0 -n vault \
    -o jsonpath='{.status.phase}' 2>/dev/null || true)"
  pvc_sc="$(KUBECONFIG="$kubeconfig" oc get pvc data-vault-0 -n vault \
    -o jsonpath='{.spec.storageClassName}' 2>/dev/null || true)"
  if [[ "$pvc_phase" == "Pending" && -z "$pvc_sc" ]]; then
    log "[libvirt-fs] Recreating pending vault PVC (was missing storageClassName)..."
    KUBECONFIG="$kubeconfig" oc delete pod vault-0 -n vault --wait=false >/dev/null 2>&1 || true
    KUBECONFIG="$kubeconfig" oc delete pvc data-vault-0 -n vault --wait=true >/dev/null 2>&1 || true
  fi

  # If vault already exists (re-run), tighten ownership/MCS and bounce if needed.
  if KUBECONFIG="$kubeconfig" oc get pod vault-0 -n vault >/dev/null 2>&1; then
    local tries=0
    while [[ $tries -lt 30 ]]; do
      if KUBECONFIG="$kubeconfig" oc get pod vault-0 -n vault \
        -o jsonpath='{.status.phase}' 2>/dev/null | grep -qx Running; then
        log "[libvirt-fs] vault-0 is Running."
        if ! fix_libvirt_vault_hostpath_permissions "$kubeconfig"; then
          warn "[libvirt-fs] hostPath still not writable; restarting vault-0..."
          KUBECONFIG="$kubeconfig" oc delete pod vault-0 -n vault --wait=false >/dev/null 2>&1 || true
          sleep 15
          fix_libvirt_vault_hostpath_permissions "$kubeconfig" || true
        fi
        return 0
      fi
      if KUBECONFIG="$kubeconfig" oc get sts vault -n vault >/dev/null 2>&1 && \
        ! KUBECONFIG="$kubeconfig" oc get pvc data-vault-0 -n vault >/dev/null 2>&1; then
        KUBECONFIG="$kubeconfig" oc delete pod vault-0 -n vault --wait=false >/dev/null 2>&1 || true
      fi
      sleep 10
      tries=$((tries + 1))
    done
    pvc_phase="$(KUBECONFIG="$kubeconfig" oc get pvc data-vault-0 -n vault \
      -o jsonpath='{.status.phase}' 2>/dev/null || echo missing)"
    warn "[libvirt-fs] vault-0 not Running yet (pvc=$pvc_phase); install-byoc may still wait on Vault."
  fi
  return 0
}

# hostPath DirectoryOrCreate makes root:root 0755 dirs. OpenShift vault runs as an
# arbitrary UID with MCS; without chown+container_file_t+MCS, vault init fails with
# "mkdir /vault/data/core: permission denied" and install-byoc sees Vault sealed.
fix_libvirt_vault_hostpath_permissions() {
  local kubeconfig="${1:-$HUB_INSTALL_DIR/auth/kubeconfig}"
  local node vault_uid vault_fsg mcs hp
  hp="${LIBVIRT_VAULT_HOSTPATH}"

  node="$(KUBECONFIG="$kubeconfig" oc get pod vault-0 -n vault \
    -o jsonpath='{.spec.nodeName}' 2>/dev/null || true)"
  vault_uid="$(KUBECONFIG="$kubeconfig" oc get pod vault-0 -n vault \
    -o jsonpath='{.spec.containers[0].securityContext.runAsUser}' 2>/dev/null || true)"
  vault_fsg="$(KUBECONFIG="$kubeconfig" oc get pod vault-0 -n vault \
    -o jsonpath='{.spec.securityContext.fsGroup}' 2>/dev/null || true)"
  mcs="$(KUBECONFIG="$kubeconfig" oc get pod vault-0 -n vault \
    -o jsonpath='{.spec.securityContext.seLinuxOptions.level}' 2>/dev/null || true)"
  # Prefer namespace SCC annotations when the pod omits explicit fields.
  if [[ -z "$vault_uid" ]]; then
    vault_uid="$(KUBECONFIG="$kubeconfig" oc get ns vault \
      -o jsonpath='{.metadata.annotations.openshift\.io/sa\.scc\.uid-range}' 2>/dev/null \
      | cut -d/ -f1 || true)"
  fi
  if [[ -z "$mcs" ]]; then
    mcs="$(KUBECONFIG="$kubeconfig" oc get ns vault \
      -o jsonpath='{.metadata.annotations.openshift\.io/sa\.scc\.mcs}' 2>/dev/null || true)"
  fi

  if [[ -z "$node" || -z "$vault_uid" ]]; then
    warn "[libvirt-fs] Cannot fix vault hostPath perms (node=${node:-none} uid=${vault_uid:-none})."
    return 1
  fi
  vault_fsg="${vault_fsg:-$vault_uid}"

  if KUBECONFIG="$kubeconfig" oc exec -n vault vault-0 -- \
    sh -c "touch /vault/data/.ramendr-write-test && rm -f /vault/data/.ramendr-write-test" \
    >/dev/null 2>&1; then
    log "[libvirt-fs] vault hostPath already writable."
    return 0
  fi

  log "[libvirt-fs] Fixing vault hostPath ownership/SELinux on ${node} (${vault_uid}:${vault_fsg} ${mcs})..."
  # Avoid bash readonly UID; pass numeric ids into the debug node shell.
  if ! KUBECONFIG="$kubeconfig" oc debug "node/${node}" --to-namespace=default -- \
    chroot /host sh -c "
      mkdir -p '${hp}'
      chown -R '${vault_uid}:${vault_fsg}' '${hp}'
      chmod 0770 '${hp}'
      chcon -R -t container_file_t '${hp}' || true
      if [ -n '${mcs}' ]; then chcon -R -l '${mcs}' '${hp}' || true; fi
      ls -laZ '${hp}'
    "; then
    warn "[libvirt-fs] Failed to fix vault hostPath permissions on ${node}."
    return 1
  fi

  if KUBECONFIG="$kubeconfig" oc exec -n vault vault-0 -- \
    sh -c "touch /vault/data/.ramendr-write-test && rm -f /vault/data/.ramendr-write-test" \
    >/dev/null 2>&1; then
    log "[libvirt-fs] vault hostPath is writable."
    return 0
  fi
  warn "[libvirt-fs] vault hostPath still not writable after chmod/chcon."
  return 1
}
