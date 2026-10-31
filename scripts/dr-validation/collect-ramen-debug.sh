#!/usr/bin/env bash
# Capture a Ramen / VGR failover debug bundle (no secret values).
#
# Intended for CI PVC + local repro when DRPC sticks in WaitForReadiness or
# secondary PV/PVC restore fails (Lost/Pending, Total/Restored N/0).
#
# Usage:
#   ./scripts/dr-validation/collect-ramen-debug.sh [--tag LABEL] [--out-dir DIR]
#   RAMENDR_DR_DEBUG=0 …   # no-op (exit 0)
#
# Env (kubeconfigs — same as redeploy / sanity):
#   KUBECONFIG / HUB_INSTALL_DIR / RAMENDR_HUB_KUBECONFIG
#   PRIMARY_INSTALL_DIR / RAMENDR_PRIMARY_KUBECONFIG
#   SECONDARY_INSTALL_DIR / RAMENDR_SECONDARY_KUBECONFIG
#   WORK_DIR                 default dump parent when --out-dir unset
#   RAMENDR_DR_DEBUG_DIR     explicit dump root (tag subdir created under it)
#   RAMENDR_DR_DEBUG_LOG_SINCE  oc logs --since (default 2h)
#   STORAGE_NAMESPACE           ODF/NooBaa/RGW ns (default openshift-storage)
#   DRPC_NAMESPACE / DRPC_NAME / VM_NAMESPACE  (defaults below)
#
# Bundle also streams NooBaa endpoint + Ceph RGW pod logs (and CR status) from
# hub/primary/secondary — useful when a PV never landed in the Ramen S3 profile.
# Never prints kubeconfig or S3 credential / access-key contents.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TAG="manual"
OUT_ROOT=""
DRPC_NAMESPACE="${DRPC_NAMESPACE:-openshift-dr-ops}"
DRPC_NAME="${DRPC_NAME:-gitops-vm-protection}"
VM_NAMESPACE="${VM_NAMESPACE:-gitops-vms}"
STORAGE_NS="${STORAGE_NAMESPACE:-openshift-storage}"
LOG_SINCE="${RAMENDR_DR_DEBUG_LOG_SINCE:-2h}"
# Cap per-pod log size so a noisy NooBaa endpoint cannot blow the PVC.
# Set RAMENDR_DR_DEBUG_LOG_TAIL=-1 to disable the cap.
LOG_TAIL="${RAMENDR_DR_DEBUG_LOG_TAIL:-20000}"

usage() {
  sed -n '2,28p' "$0" | sed 's/^# \?//'
  exit 0
}

log() { printf '[ramen-debug] %s\n' "$*" >&2; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h | --help) usage ;;
    --tag)
      [[ $# -ge 2 ]] || { log "error: --tag requires a value"; exit 2; }
      TAG="$2"
      shift 2
      ;;
    --out-dir)
      [[ $# -ge 2 ]] || { log "error: --out-dir requires a value"; exit 2; }
      OUT_ROOT="$2"
      shift 2
      ;;
    *)
      log "error: unknown argument: $1"
      exit 2
      ;;
  esac
done

if [[ "${RAMENDR_DR_DEBUG:-1}" =~ ^(0|false|no|off)$ ]]; then
  log "skipped (RAMENDR_DR_DEBUG=${RAMENDR_DR_DEBUG})"
  exit 0
fi

resolve_kc() {
  local explicit_env="$1" install_env="$2" default_rel="$3"
  local explicit install_dir
  explicit="$(eval "printf '%s' \"\${${explicit_env}:-}\"")"
  if [[ -n "$explicit" ]]; then
    printf '%s\n' "${explicit/#\~/$HOME}"
    return
  fi
  install_dir="$(eval "printf '%s' \"\${${install_env}:-}\"")"
  if [[ -n "$install_dir" ]]; then
    printf '%s\n' "${install_dir%/}/auth/kubeconfig"
    return
  fi
  printf '%s\n' "${default_rel/#\~/$HOME}"
}

HUB_KC="$(resolve_kc RAMENDR_HUB_KUBECONFIG HUB_INSTALL_DIR "${KUBECONFIG:-$HOME/git/hub-cluster-install/auth/kubeconfig}")"
PRI_KC="$(resolve_kc RAMENDR_PRIMARY_KUBECONFIG PRIMARY_INSTALL_DIR "$HOME/git/ocp-primary-install/auth/kubeconfig")"
SEC_KC="$(resolve_kc RAMENDR_SECONDARY_KUBECONFIG SECONDARY_INSTALL_DIR "$HOME/git/ocp-secondary-install/auth/kubeconfig")"

if [[ -z "$OUT_ROOT" ]]; then
  if [[ -n "${RAMENDR_DR_DEBUG_DIR:-}" ]]; then
    OUT_ROOT="$RAMENDR_DR_DEBUG_DIR"
  elif [[ -d /workspace/data/artifacts ]]; then
    # Tekton PVC layout (junit lives here too).
    OUT_ROOT="/workspace/data/artifacts/dr-debug"
  elif [[ -n "${WORK_DIR:-}" ]]; then
    OUT_ROOT="${WORK_DIR%/}/artifacts/dr-debug"
  else
    OUT_ROOT="${REPO_ROOT}/.work/artifacts/dr-debug"
  fi
fi

SAFE_TAG="$(printf '%s' "$TAG" | tr -c 'A-Za-z0-9._-' '_' )"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
OUT_DIR="${OUT_ROOT%/}/${SAFE_TAG}-${STAMP}"
mkdir -p "$OUT_DIR"/{hub,primary,secondary,logs,summary}
mkdir -p "$OUT_DIR/logs"/{hub,primary,secondary}/{noobaa,rgw}

oc_hub() { oc --kubeconfig="$HUB_KC" "$@"; }
oc_pri() { oc --kubeconfig="$PRI_KC" "$@"; }
oc_sec() { oc --kubeconfig="$SEC_KC" "$@"; }

dump_cmd() {
  local outfile="$1"
  shift
  # Best-effort: capture stdout/stderr; never fail the whole dump.
  {
    printf '+ %s\n' "$*"
    "$@" 2>&1 || printf '(exit %s)\n' "$?"
  } >"$outfile" || true
}

{
  echo "tag=$TAG"
  echo "stamp_utc=$STAMP"
  echo "out_dir=$OUT_DIR"
  echo "drpc=${DRPC_NAMESPACE}/${DRPC_NAME}"
  echo "vm_namespace=$VM_NAMESPACE"
  echo "log_since=$LOG_SINCE"
  echo "log_tail=$LOG_TAIL"
  echo "storage_namespace=$STORAGE_NS"
  echo "hub_kc_exists=$([[ -f $HUB_KC ]] && echo yes || echo no)"
  echo "primary_kc_exists=$([[ -f $PRI_KC ]] && echo yes || echo no)"
  echo "secondary_kc_exists=$([[ -f $SEC_KC ]] && echo yes || echo no)"
  # Paths only — never cat kubeconfigs.
  echo "hub_kc_path=$HUB_KC"
  echo "primary_kc_path=$PRI_KC"
  echo "secondary_kc_path=$SEC_KC"
} >"$OUT_DIR/MANIFEST.txt"

log "writing bundle → $OUT_DIR"

# --- Hub ---
dump_cmd "$OUT_DIR/hub/drpc-wide.txt" oc_hub get drpc -A -o wide
dump_cmd "$OUT_DIR/hub/drpc.yaml" oc_hub get drpc -n "$DRPC_NAMESPACE" "$DRPC_NAME" -o yaml
dump_cmd "$OUT_DIR/hub/drpc-json.json" oc_hub get drpc -n "$DRPC_NAMESPACE" "$DRPC_NAME" -o json
dump_cmd "$OUT_DIR/hub/drpolicy-wide.txt" oc_hub get drpolicy -A -o wide
dump_cmd "$OUT_DIR/hub/manifestworks-gitops.txt" \
  bash -lc "oc --kubeconfig='$HUB_KC' get manifestwork -A -o wide 2>&1 | grep -iE 'NAME|gitops|vrg|ramen' || true"
dump_cmd "$OUT_DIR/hub/managedclusters.txt" oc_hub get managedclusters -o wide

# --- Spokes: VRG / VM / PVC / PV ---
dump_spoke() {
  local name="$1" kc="$2"
  local oc_spoke=(oc --kubeconfig="$kc")
  dump_cmd "$OUT_DIR/$name/vrg-wide.txt" "${oc_spoke[@]}" get volumereplicationgroups.ramendr.openshift.io -A -o wide
  dump_cmd "$OUT_DIR/$name/vrg.yaml" "${oc_spoke[@]}" get volumereplicationgroups.ramendr.openshift.io -n "$DRPC_NAMESPACE" "$DRPC_NAME" -o yaml
  dump_cmd "$OUT_DIR/$name/vgr-vr-wide.txt" "${oc_spoke[@]}" get volumegroupreplication,volumereplication -A -o wide
  dump_cmd "$OUT_DIR/$name/vm-vmi-svc-wide.txt" "${oc_spoke[@]}" get vm,vmi,svc -n "$VM_NAMESPACE" -o wide
  dump_cmd "$OUT_DIR/$name/pvc-wide.txt" "${oc_spoke[@]}" get pvc -n "$VM_NAMESPACE" -o wide
  dump_cmd "$OUT_DIR/$name/pvc.yaml" "${oc_spoke[@]}" get pvc -n "$VM_NAMESPACE" -o yaml
  {
    printf '+ oc get pv -o wide | grep gitops-vms|ramen\n'
    "${oc_spoke[@]}" get pv -o wide 2>&1 | grep -iE 'NAME|gitops-vms|ramen' || true
  } >"$OUT_DIR/$name/pv-related.txt" || true
  dump_cmd "$OUT_DIR/$name/pv.yaml" "${oc_spoke[@]}" get pv -o yaml
}

dump_spoke primary "$PRI_KC"
dump_spoke secondary "$SEC_KC"

# Annotation / volumeHandle summary (no secret data).
python3 - "$OUT_DIR" "$PRI_KC" "$SEC_KC" "$VM_NAMESPACE" <<'PY' || true
import json, os, subprocess, sys

out_dir, pri_kc, sec_kc, vm_ns = sys.argv[1:5]

def oc_json(kc, *args):
    r = subprocess.run(
        ["oc", f"--kubeconfig={kc}", *args, "-o", "json"],
        capture_output=True, text=True, check=False,
    )
    if r.returncode != 0 or not r.stdout.strip():
        return None
    try:
        return json.loads(r.stdout)
    except json.JSONDecodeError:
        return None

def pv_rows(kc, label):
    data = oc_json(kc, "get", "pv")
    rows = []
    if not data:
        return rows
    for item in data.get("items") or []:
        md = item.get("metadata") or {}
        sp = item.get("spec") or {}
        st = item.get("status") or {}
        ann = md.get("annotations") or {}
        csi = (sp.get("csi") or {})
        claim = sp.get("claimRef") or {}
        if claim.get("namespace") != vm_ns and "ramen" not in json.dumps(ann).lower():
            # keep only gitops-vms claims or ramen-annotated restores
            if "ramen-restore" not in ann and "vr-retained" not in str(ann) and "vr-archived" not in str(ann):
                continue
        rows.append({
            "cluster": label,
            "pv": md.get("name"),
            "phase": st.get("phase"),
            "claim_ns": claim.get("namespace"),
            "claim_name": claim.get("name"),
            "claim_uid": claim.get("uid"),
            "volumeHandle_suffix": (csi.get("volumeHandle") or "")[-48:],
            "volumeHandle_len": len(csi.get("volumeHandle") or ""),
            "DestinationVolumeHandle": ann.get(
                "replication.storage.openshift.io/destination-volume-handle"
            ) or ann.get("DestinationVolumeHandle") or ann.get(
                "volumereplicationgroups.ramendr.openshift.io/destination-volume-handle"
            ),
            "ramen_restore": ann.get("volumereplicationgroups.ramendr.openshift.io/ramen-restore"),
            "vr_retained": ann.get("volumereplicationgroups.ramendr.openshift.io/vr-retained"),
            "vr_archived": ann.get("volumereplicationgroups.ramendr.openshift.io/vr-archived"),
            "annotation_keys": sorted(ann.keys()),
        })
    return rows

def pvc_rows(kc, label):
    data = oc_json(kc, "get", "pvc", "-n", vm_ns)
    rows = []
    if not data:
        return rows
    for item in data.get("items") or []:
        md = item.get("metadata") or {}
        sp = item.get("spec") or {}
        st = item.get("status") or {}
        rows.append({
            "cluster": label,
            "pvc": md.get("name"),
            "phase": st.get("phase"),
            "volumeName": sp.get("volumeName"),
            "uid": md.get("uid"),
        })
    return rows

summary = {
    "primary_pvs": pv_rows(pri_kc, "primary"),
    "secondary_pvs": pv_rows(sec_kc, "secondary"),
    "primary_pvcs": pvc_rows(pri_kc, "primary"),
    "secondary_pvcs": pvc_rows(sec_kc, "secondary"),
}
path = os.path.join(out_dir, "summary", "pv-pvc-annotation-summary.json")
with open(path, "w", encoding="utf-8") as fh:
    json.dump(summary, fh, indent=2, sort_keys=True)

# Same-name PV volumeHandle equality primary vs secondary (smoking gun for VGR restore).
pri_by_name = {r["pv"]: r for r in summary["primary_pvs"] if r.get("pv")}
sec_by_name = {r["pv"]: r for r in summary["secondary_pvs"] if r.get("pv")}
cmp_rows = []
for name in sorted(set(pri_by_name) | set(sec_by_name)):
    p, s = pri_by_name.get(name), sec_by_name.get(name)
    if not p or not s:
        cmp_rows.append({"pv": name, "on_primary": bool(p), "on_secondary": bool(s)})
        continue
    # Re-fetch full handles via earlier suffix+len equality is weak; load YAML again cheaply.
    cmp_rows.append({
        "pv": name,
        "primary_phase": p.get("phase"),
        "secondary_phase": s.get("phase"),
        "primary_handle_len": p.get("volumeHandle_len"),
        "secondary_handle_len": s.get("volumeHandle_len"),
        "same_handle_len": p.get("volumeHandle_len") == s.get("volumeHandle_len"),
        "primary_dest_handle_set": bool(p.get("DestinationVolumeHandle")),
        "secondary_claim_uid": s.get("claim_uid"),
    })
with open(os.path.join(out_dir, "summary", "pv-handle-compare.json"), "w", encoding="utf-8") as fh:
    json.dump(cmp_rows, fh, indent=2)
PY

# Full volumeHandle compare (names only + equal bool) without dumping full handles to stdout.
python3 - "$OUT_DIR" "$PRI_KC" "$SEC_KC" <<'PY' || true
import hashlib, json, subprocess, sys, os
out_dir, pri_kc, sec_kc = sys.argv[1:4]

def handles(kc):
    r = subprocess.run(
        ["oc", f"--kubeconfig={kc}", "get", "pv", "-o", "json"],
        capture_output=True, text=True, check=False,
    )
    if r.returncode != 0:
        return {}
    data = json.loads(r.stdout)
    out = {}
    for item in data.get("items") or []:
        name = item["metadata"]["name"]
        h = ((item.get("spec") or {}).get("csi") or {}).get("volumeHandle") or ""
        if h:
            out[name] = hashlib.sha256(h.encode()).hexdigest()
    return out

pri, sec = handles(pri_kc), handles(sec_kc)
rows = []
for name in sorted(set(pri) | set(sec)):
    ph, sh = pri.get(name), sec.get(name)
    rows.append({
        "pv": name,
        "primary_sha256": ph,
        "secondary_sha256": sh,
        "same_handle": bool(ph and sh and ph == sh),
    })
with open(os.path.join(out_dir, "summary", "pv-handle-sha256-compare.json"), "w", encoding="utf-8") as fh:
    json.dump(rows, fh, indent=2)
print(f"same_handle_count={sum(1 for r in rows if r.get('same_handle'))} compared={len(rows)}", file=sys.stderr)
PY

# Operator logs (best-effort; may be empty if rotated).
dump_cmd "$OUT_DIR/logs/ramen-dr-cluster-primary.txt" \
  oc_pri logs -n openshift-dr-system deploy/ramen-dr-cluster-operator --since="$LOG_SINCE" --tail="$LOG_TAIL"
dump_cmd "$OUT_DIR/logs/ramen-dr-cluster-secondary.txt" \
  oc_sec logs -n openshift-dr-system deploy/ramen-dr-cluster-operator --since="$LOG_SINCE" --tail="$LOG_TAIL"
# Hub operator deploy name varies by RHDR vs upstream.
for dep in ramen-hub-operator-manager ramen-hub-operator hub-operator; do
  if oc_hub get deploy -n openshift-operators "$dep" >/dev/null 2>&1; then
    dump_cmd "$OUT_DIR/logs/ramen-hub-${dep}.txt" \
      oc_hub logs -n openshift-operators "deploy/${dep}" --since="$LOG_SINCE" --tail="$LOG_TAIL"
  fi
done
for ns in openshift-operators openshift-dr-system rhdr-operator; do
  dump_cmd "$OUT_DIR/logs/hub-deploys-${ns}.txt" oc_hub get deploy -n "$ns" -o wide
done

# --- NooBaa (MCG) + Ceph RGW endpoint log streams (S3 upload path for VRG) ---
# Ramen archives PV kube objects to the s3Profile; missing objects often show up
# here as 403/404/5xx on noobaa-endpoint or rook-ceph-rgw before ramen logs rotate.
dump_s3_endpoint_logs() {
  local cluster="$1" kc="$2"
  local oc_s=(oc --kubeconfig="$kc")
  local ns="$STORAGE_NS"
  local base="$OUT_DIR/logs/$cluster"
  local pod safe_pod

  mkdir -p "$base"/{noobaa,rgw}

  if ! "${oc_s[@]}" get ns "$ns" >/dev/null 2>&1; then
    printf 'namespace %s missing on %s\n' "$ns" "$cluster" >"$base/storage-ns-missing.txt"
    return 0
  fi

  dump_cmd "$base/pods-wide.txt" "${oc_s[@]}" get pods -n "$ns" -o wide
  dump_cmd "$base/svc-wide.txt" "${oc_s[@]}" get svc -n "$ns" -o wide
  dump_cmd "$base/routes.txt" "${oc_s[@]}" get route -n "$ns" -o wide

  # NooBaa / MCG inventory (no Secret data).
  dump_cmd "$base/noobaa/noobaa-wide.txt" "${oc_s[@]}" get noobaa -n "$ns" -o wide
  dump_cmd "$base/noobaa/noobaa.yaml" "${oc_s[@]}" get noobaa -n "$ns" -o yaml
  dump_cmd "$base/noobaa/backingstore-bucketclass.txt" \
    "${oc_s[@]}" get backingstore,bucketclass,namespacestore -n "$ns" -o wide
  dump_cmd "$base/noobaa/obc-ob.txt" \
    "${oc_s[@]}" get objectbucketclaim,objectbucket -A -o wide
  # Endpoint deploy/pods — the S3 front-door Ramen talks to.
  dump_cmd "$base/noobaa/endpoint-deploy.txt" \
    "${oc_s[@]}" get deploy,pods -n "$ns" -l noobaa-s3=true -o wide
  dump_cmd "$base/noobaa/endpoint-deploy-alt.txt" \
    "${oc_s[@]}" get deploy,pods -n "$ns" -l app=noobaa -o wide

  # CephObjectStore / RGW (ODF may use RGW instead of or beside NooBaa).
  dump_cmd "$base/rgw/cephobjectstore.txt" \
    "${oc_s[@]}" get cephobjectstore,cephobjectstoreuser -n "$ns" -o wide
  dump_cmd "$base/rgw/cephobjectstore.yaml" \
    "${oc_s[@]}" get cephobjectstore -n "$ns" -o yaml

  # Stream current (+ previous, if present) logs from endpoint / RGW pods.
  while IFS= read -r pod; do
    [[ -z "$pod" ]] && continue
    safe_pod="$(printf '%s' "$pod" | tr -c 'A-Za-z0-9._-' '_')"
    {
      printf '+ oc logs -n %s %s --all-containers --since=%s --tail=%s\n' \
        "$ns" "$pod" "$LOG_SINCE" "$LOG_TAIL"
      "${oc_s[@]}" logs -n "$ns" "$pod" --all-containers \
        --since="$LOG_SINCE" --tail="$LOG_TAIL" 2>&1 || true
      printf '\n--- previous (if any) ---\n'
      "${oc_s[@]}" logs -n "$ns" "$pod" --all-containers --previous \
        --tail=500 2>&1 || true
    } >"$base/noobaa/pod-${safe_pod}.log" || true
  done < <(
    "${oc_s[@]}" get pods -n "$ns" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null \
      | grep -E 'noobaa-endpoint|noobaa-core|noobaa-db' || true
  )

  while IFS= read -r pod; do
    [[ -z "$pod" ]] && continue
    safe_pod="$(printf '%s' "$pod" | tr -c 'A-Za-z0-9._-' '_')"
    {
      printf '+ oc logs -n %s %s --all-containers --since=%s --tail=%s\n' \
        "$ns" "$pod" "$LOG_SINCE" "$LOG_TAIL"
      "${oc_s[@]}" logs -n "$ns" "$pod" --all-containers \
        --since="$LOG_SINCE" --tail="$LOG_TAIL" 2>&1 || true
      printf '\n--- previous (if any) ---\n'
      "${oc_s[@]}" logs -n "$ns" "$pod" --all-containers --previous \
        --tail=500 2>&1 || true
    } >"$base/rgw/pod-${safe_pod}.log" || true
  done < <(
    "${oc_s[@]}" get pods -n "$ns" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null \
      | grep -E 'rook-ceph-rgw|ceph-rgw' || true
  )

  # Grep-friendly error slice (no credentials expected in these lines).
  {
    printf '# aggregated NooBaa/RGW error-ish lines (best-effort)\n'
    grep -Ehi 'error|fail|denied|forbidden|403|404|500|503|nosuch|accessdenied|slowdown|timeout' \
      "$base"/noobaa/pod-*.log "$base"/rgw/pod-*.log 2>/dev/null \
      | head -n 2000 || true
  } >"$base/s3-errors-grep.txt" || true
}

log "streaming NooBaa/RGW endpoint logs (since=$LOG_SINCE)…"
dump_s3_endpoint_logs hub "$HUB_KC"
dump_s3_endpoint_logs primary "$PRI_KC"
dump_s3_endpoint_logs secondary "$SEC_KC"

# Ramen ConfigMaps: keep s3Profile endpoints / secretRef *names*; redact key-like values.
dump_ramen_cm_redacted() {
  local outfile="$1" kc="$2" ns="$3"
  {
    printf '+ oc get configmap -n %s -o yaml (redacted)\n' "$ns"
    oc --kubeconfig="$kc" get configmap -n "$ns" -o yaml 2>&1 \
      | sed -E \
        -e 's/(AWS_ACCESS_KEY_ID|AWS_SECRET_ACCESS_KEY|accessKey|secretKey|AccessKey|SecretKey)([[:space:]]*:[[:space:]]*).*/\1\2***REDACTED***/g' \
        -e 's/(access_key|secret_key|accesskeyid|secretaccesskey)([[:space:]]*:[[:space:]]*).*/\1\2***REDACTED***/Ig' \
      || true
  } >"$outfile" || true
}
dump_cmd "$OUT_DIR/summary/ramen-config-hub-names.txt" \
  oc_hub get configmap -n openshift-operators -o name
dump_ramen_cm_redacted "$OUT_DIR/summary/ramen-config-dr-system-primary.yaml" "$PRI_KC" openshift-dr-system
dump_ramen_cm_redacted "$OUT_DIR/summary/ramen-config-dr-system-secondary.yaml" "$SEC_KC" openshift-dr-system
# Secret *names* for s3 / noobaa (never values).
dump_cmd "$OUT_DIR/summary/s3-secret-names-primary.txt" \
  bash -lc "oc --kubeconfig='$PRI_KC' get secret -n '$STORAGE_NS' -o custom-columns=NAME:.metadata.name,TYPE:.type --no-headers 2>&1 | grep -iE 'noobaa|s3|rgw|aws|bucket' || true"
dump_cmd "$OUT_DIR/summary/s3-secret-names-secondary.txt" \
  bash -lc "oc --kubeconfig='$SEC_KC' get secret -n '$STORAGE_NS' -o custom-columns=NAME:.metadata.name,TYPE:.type --no-headers 2>&1 | grep -iE 'noobaa|s3|rgw|aws|bucket' || true"

# Events that often outlive container logs a bit longer.
dump_cmd "$OUT_DIR/summary/events-secondary-gitops-vms.txt" \
  oc_sec get events -n "$VM_NAMESPACE" --sort-by=.lastTimestamp
dump_cmd "$OUT_DIR/summary/events-claimmisbound.txt" \
  bash -lc "oc --kubeconfig='$SEC_KC' get events -A --field-selector reason=ClaimMisbound 2>&1 | tail -100"
dump_cmd "$OUT_DIR/summary/events-storage-primary.txt" \
  oc_pri get events -n "$STORAGE_NS" --sort-by=.lastTimestamp
dump_cmd "$OUT_DIR/summary/events-storage-secondary.txt" \
  oc_sec get events -n "$STORAGE_NS" --sort-by=.lastTimestamp

# Index
{
  echo "files:"
  (cd "$OUT_DIR" && find . -type f | sort)
} >"$OUT_DIR/INDEX.txt"

log "done: $OUT_DIR"
printf '%s\n' "$OUT_DIR"
exit 0
