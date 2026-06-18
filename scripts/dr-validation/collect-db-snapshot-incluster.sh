#!/usr/bin/env bash
# Collect PostgreSQL DR validation snapshots from the HammerDB edge VM via in-cluster SSH.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

OUT_DIR="${1:-${REPO_ROOT}/.work/dr-validation-db/manual/$(date +%Y%m%d-%H%M%S)}"
require_cmd oc python3
ensure_hub_kubeconfig

PRIMARY="$(determine_primary_cluster)"
[[ -z "$PRIMARY" ]] && PRIMARY="ocp-primary"
SPOKE_KC="$(resolve_spoke_kubeconfig "$PRIMARY")"

cleanup_collect_secret() {
  KUBECONFIG="$SPOKE_KC" oc delete secret ramendr-dr-db-collect-ssh -n "$VM_NAMESPACE" --ignore-not-found &>/dev/null || true
}

HOSTS="$(get_hammerdb_vm_host "$SPOKE_KC")"
[[ -n "$HOSTS" ]] || exit 1

PASS="${DR_VALIDATION_SSH_PASSWORD:-}"
if [[ -z "$PASS" ]]; then
  PASS="$(cloud_init_password_from_vault)"
fi

TMP_DIR="$(mktemp -d)"
printf '%s\n' "$HOSTS" > "$TMP_DIR/hosts.tsv"

collect_db_cleanup() {
  [[ -n "${TMP_DIR:-}" && -d "$TMP_DIR" ]] && rm -rf "$TMP_DIR"
  cleanup_collect_secret
}
trap collect_db_cleanup EXIT

COLLECT_SECRET_CREATE=(oc create secret generic ramendr-dr-db-collect-ssh
  --from-file=hosts.tsv="$TMP_DIR/hosts.tsv"
  -n "$VM_NAMESPACE" --dry-run=client -o yaml)
[[ -n "$PASS" ]] && COLLECT_SECRET_CREATE+=(--from-literal=password="$PASS")
SSH_KEY_FILE="${SSH_IDENTITY_FILE:-}"
if [[ -z "$SSH_KEY_FILE" || ! -f "$SSH_KEY_FILE" ]]; then
  [[ -f "$HOME/.ssh/id_ed25519" ]] && SSH_KEY_FILE="$HOME/.ssh/id_ed25519"
fi
if [[ -n "$SSH_KEY_FILE" && -f "$SSH_KEY_FILE" ]]; then
  COLLECT_SECRET_CREATE+=(--from-file=ssh-privatekey="$SSH_KEY_FILE")
fi
KUBECONFIG="$SPOKE_KC" "${COLLECT_SECRET_CREATE[@]}" | KUBECONFIG="$SPOKE_KC" oc apply -f -

KUBECONFIG="$SPOKE_KC" oc delete job ramendr-dr-db-collect -n "$VM_NAMESPACE" --ignore-not-found
if KUBECONFIG="$SPOKE_KC" oc get job ramendr-dr-db-collect -n "$VM_NAMESPACE" >/dev/null 2>&1; then
  KUBECONFIG="$SPOKE_KC" oc wait --for=delete job/ramendr-dr-db-collect \
    -n "$VM_NAMESPACE" --timeout=120s
fi
KUBECONFIG="$SPOKE_KC" oc apply -f - <<EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: ramendr-dr-db-collect
  namespace: ${VM_NAMESPACE}
spec:
  backoffLimit: 0
  template:
    spec:
      restartPolicy: Never
      containers:
      - name: collect
        image: ${DR_VALIDATION_UTILITY_CONTAINER_IMAGE}
        env:
        - name: SSH_USER
          value: "${SSH_USER}"
        - name: DR_VALIDATION_HAMMERDB_VM
          value: "${DR_VALIDATION_HAMMERDB_VM}"
        volumeMounts:
        - name: ssh
          mountPath: /ssh
          readOnly: true
        command: ["bash", "-c"]
        args:
          - |
            set -euo pipefail
            dnf install -y sshpass openssh-clients >/dev/null 2>&1 || true
            PASS="\$(tr -d '\n' < /ssh/password 2>/dev/null || true)"
            test -f /ssh/ssh-privatekey && cp /ssh/ssh-privatekey /tmp/ssh-privatekey && chmod 600 /tmp/ssh-privatekey || true
            cp /ssh/hosts.tsv /tmp/hosts.tsv
            while IFS=\$'\t' read -r name host port; do
              [[ -z "\$name" ]] && continue
              port="\${port:-22}"
              echo "===SNAPSHOT:\${name}==="
              remote_cmd='sudo /usr/local/bin/ramendr-dr-db-snapshot --vm-name '"${DR_VALIDATION_HAMMERDB_VM}"''
              if [[ -f /tmp/ssh-privatekey ]] && ssh -i /tmp/ssh-privatekey -n -p "\$port" \
                  -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
                  "\${SSH_USER}@\${host}" "\$remote_cmd" 2>/dev/null; then
                continue
              fi
              if [[ -n "\$PASS" ]]; then
                sshpass -p "\$PASS" ssh -n -p "\$port" \
                  -o StrictHostKeyChecking=no -o PreferredAuthentications=password -o PubkeyAuthentication=no \
                  -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
                  "\${SSH_USER}@\${host}" "\$remote_cmd" 2>/dev/null || true
              fi
            done < /tmp/hosts.tsv
      volumes:
      - name: ssh
        secret:
          secretName: ramendr-dr-db-collect-ssh
          items:
          - key: hosts.tsv
            path: hosts.tsv
          - key: password
            path: password
            optional: true
          - key: ssh-privatekey
            path: ssh-privatekey
            optional: true
EOF

collect_failed=0
job_done=0
for _ in $(seq 1 120); do
  if KUBECONFIG="$SPOKE_KC" oc get job ramendr-dr-db-collect -n "$VM_NAMESPACE" -o jsonpath='{.status.succeeded}' 2>/dev/null | grep -q 1; then
    job_done=1
    break
  fi
  if KUBECONFIG="$SPOKE_KC" oc get job ramendr-dr-db-collect -n "$VM_NAMESPACE" -o jsonpath='{.status.failed}' 2>/dev/null | grep -q 1; then
    KUBECONFIG="$SPOKE_KC" oc logs -n "$VM_NAMESPACE" job/ramendr-dr-db-collect
    collect_failed=1
    job_done=1
    break
  fi
  sleep 10
done

cleanup_collect_secret

if [[ "$collect_failed" -eq 1 ]]; then
  exit 1
fi
if [[ "$job_done" -ne 1 ]]; then
  err "Timed out waiting for ramendr-dr-db-collect job."
  exit 1
fi

mkdir -p "$OUT_DIR"
KUBECONFIG="$SPOKE_KC" oc logs -n "$VM_NAMESPACE" job/ramendr-dr-db-collect > "$TMP_DIR/collect.raw"

snapshot_count="$(
python3 <<PY
import json
import re
import sys
from pathlib import Path

raw = Path("$TMP_DIR/collect.raw").read_text()
out = Path("$OUT_DIR")
out.mkdir(parents=True, exist_ok=True)
parts = re.split(r'^===SNAPSHOT:(.+?)===\n', raw, flags=re.M)
i = 1
count = 0
while i + 1 < len(parts):
    name, content = parts[i], parts[i + 1]
    start = content.find("{")
    end = content.rfind("}")
    if start < 0 or end < start:
        i += 2
        continue
    try:
        payload = json.loads(content[start : end + 1])
    except json.JSONDecodeError as exc:
        print(f"WARN: invalid JSON for snapshot {name}: {exc}", file=sys.stderr)
        i += 2
        continue
    (out / f"{name}.db-snapshot.json").write_text(json.dumps(payload, indent=2) + "\n")
    count += 1
    i += 2
print(count)
PY
)"

cat >"${OUT_DIR}/metadata.json" <<META
{
  "collected_at_utc": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "primary_cluster": "${PRIMARY}",
  "validation_mode": "hammerdb",
  "hammerdb_vm": "${DR_VALIDATION_HAMMERDB_VM}",
  "database_backend": "postgres"
}
META

if [[ "${snapshot_count:-0}" -lt 1 ]]; then
  err "No DB snapshot JSON extracted from collect job output."
  exit 1
fi

if is_auto_db_snapshot_dir "$OUT_DIR"; then
  update_latest_db_snapshot_link "$OUT_DIR"
  prune_auto_snapshots_db
  log "Collected DB snapshot -> ${OUT_DIR} (latest -> ${DR_VALIDATION_DB_SNAPSHOT_ROOT}/latest)"
else
  log "Collected DB snapshot -> ${OUT_DIR}"
fi
