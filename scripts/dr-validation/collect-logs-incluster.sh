#!/usr/bin/env bash
# Collect timestamp logs from edge VMs via in-cluster SSH (same path as install-writer-incluster).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

OUT_DIR="${1:-${REPO_ROOT}/.work/dr-validation-logs/manual/$(date +%Y%m%d-%H%M%S)}"
require_cmd oc python3
ensure_hub_kubeconfig

PRIMARY="$(determine_primary_cluster)"
[[ -z "$PRIMARY" ]] && PRIMARY="ocp-primary"
SPOKE_KC="$(resolve_spoke_kubeconfig "$PRIMARY")"

HOSTS="$(list_vm_ssh_hosts "$SPOKE_KC")"
[[ -n "$HOSTS" ]] || { err "No SSH endpoints"; exit 1; }

PASS="${DR_VALIDATION_SSH_PASSWORD:-}"
if [[ -z "$PASS" ]]; then
  PASS="$(cloud_init_password_from_vault)"
fi
if [[ -z "$PASS" ]]; then
  err "In-cluster log collect requires a password (DR_VALIDATION_SSH_PASSWORD or Vault cloud-init password)."
  err "Private keys are not copied into the spoke cluster."
  exit 1
fi

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
printf '%s\n' "$HOSTS" > "$TMP_DIR/hosts.tsv"

cleanup_collect_secret() {
  KUBECONFIG="$SPOKE_KC" oc delete secret ramendr-dr-collect-ssh -n "$VM_NAMESPACE" --ignore-not-found &>/dev/null || true
}

KUBECONFIG="$SPOKE_KC" oc create secret generic ramendr-dr-collect-ssh \
  --from-file=hosts.tsv="$TMP_DIR/hosts.tsv" \
  --from-literal=password="$PASS" \
  -n "$VM_NAMESPACE" --dry-run=client -o yaml | KUBECONFIG="$SPOKE_KC" oc apply -f -

KUBECONFIG="$SPOKE_KC" oc delete job ramendr-dr-collect-logs -n "$VM_NAMESPACE" --ignore-not-found
KUBECONFIG="$SPOKE_KC" oc apply -f - <<EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: ramendr-dr-collect-logs
  namespace: ${VM_NAMESPACE}
spec:
  backoffLimit: 0
  template:
    spec:
      restartPolicy: Never
      containers:
      - name: collect
        image: quay.io/validatedpatterns/utility-container:latest
        env:
        - name: SSH_USER
          value: "${SSH_USER}"
        - name: LOG_PATH
          value: "${DR_VALIDATION_LOG_PATH}"
        volumeMounts:
        - name: ssh
          mountPath: /ssh
          readOnly: true
        command: ["bash", "-c"]
        args:
          - |
            set -uo pipefail
            dnf install -y sshpass openssh-clients >/dev/null 2>&1 || true
            PASS="$(tr -d '\n' < /ssh/password)"
            cp /ssh/hosts.tsv /tmp/hosts.tsv
            while IFS=\$'\t' read -r name host port; do
              [[ -z "\$name" ]] && continue
              port="\${port:-22}"
              echo "===FILE:\${name}==="
              sshpass -p "\$PASS" ssh -n -p "\$port" -o StrictHostKeyChecking=no \
                -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
                "\${SSH_USER}@\${host}" "cat \${LOG_PATH} 2>/dev/null || true" 2>/dev/null
            done < /tmp/hosts.tsv
      volumes:
      - name: ssh
        secret:
          secretName: ramendr-dr-collect-ssh
EOF

collect_failed=0
job_done=0
for _ in $(seq 1 40); do
  if KUBECONFIG="$SPOKE_KC" oc get job ramendr-dr-collect-logs -n "$VM_NAMESPACE" -o jsonpath='{.status.succeeded}' 2>/dev/null | grep -q 1; then
    job_done=1
    break
  fi
  if KUBECONFIG="$SPOKE_KC" oc get job ramendr-dr-collect-logs -n "$VM_NAMESPACE" -o jsonpath='{.status.failed}' 2>/dev/null | grep -q 1; then
    KUBECONFIG="$SPOKE_KC" oc logs -n "$VM_NAMESPACE" job/ramendr-dr-collect-logs
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
  err "Timed out waiting for ramendr-dr-collect-logs job to complete."
  KUBECONFIG="$SPOKE_KC" oc logs -n "$VM_NAMESPACE" job/ramendr-dr-collect-logs 2>/dev/null || true
  exit 1
fi

mkdir -p "$OUT_DIR"
KUBECONFIG="$SPOKE_KC" oc logs -n "$VM_NAMESPACE" job/ramendr-dr-collect-logs > "$TMP_DIR/collect.raw"

python3 <<PY
import re
from pathlib import Path
raw = Path("$TMP_DIR/collect.raw").read_text()
out = Path("$OUT_DIR")
out.mkdir(parents=True, exist_ok=True)
parts = re.split(r'^===FILE:(.+?)===\n', raw, flags=re.M)
# parts[0] is preamble; then name, content, name, content...
i = 1
while i + 1 < len(parts):
    name, content = parts[i], parts[i + 1]
    lines = [ln for ln in content.splitlines() if re.match(r"^\d+,", ln)]
    (out / f"{name}.timestamps.log").write_text("\n".join(lines) + ("\n" if lines else ""))
    i += 2
print(len(list(out.glob("*.timestamps.log"))))
PY

if [[ "$OUT_DIR" == *"/auto/"* ]]; then
  update_latest_snapshot_link "$OUT_DIR"
  prune_auto_snapshots
  log "Collected logs -> ${OUT_DIR} (latest -> ${AUTO_SNAPSHOT_ROOT}/latest)"
else
  log "Collected logs -> ${OUT_DIR}"
fi
