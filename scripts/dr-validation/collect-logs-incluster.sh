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

cleanup_collect_secret() {
  KUBECONFIG="$SPOKE_KC" oc delete secret ramendr-dr-collect-ssh -n "$VM_NAMESPACE" --ignore-not-found &>/dev/null || true
}

HOSTS="$(list_vm_ssh_hosts "$SPOKE_KC")"
[[ -n "$HOSTS" ]] || { err "No SSH endpoints"; exit 1; }

PASS="${DR_VALIDATION_SSH_PASSWORD:-}"
if [[ -z "$PASS" ]]; then
  PASS="$(cloud_init_password_from_vault)"
fi

TMP_DIR="$(mktemp -d)"
printf '%s\n' "$HOSTS" > "$TMP_DIR/hosts.tsv"

collect_logs_cleanup() {
  [[ -n "${TMP_DIR:-}" && -d "$TMP_DIR" ]] && rm -rf "$TMP_DIR"
  cleanup_collect_secret
}
trap collect_logs_cleanup EXIT

COLLECT_SECRET_CREATE=(oc create secret generic ramendr-dr-collect-ssh
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
            set -euo pipefail
            dnf install -y sshpass openssh-clients >/dev/null 2>&1 || true
            PASS="\$(tr -d '\n' < /ssh/password 2>/dev/null || true)"
            test -f /ssh/ssh-privatekey && cp /ssh/ssh-privatekey /tmp/ssh-privatekey && chmod 600 /tmp/ssh-privatekey || true
            cp /ssh/hosts.tsv /tmp/hosts.tsv
            wait_for_ssh_tcp() {
              local name="\$1" host="\$2" port="\$3"
              local tries=0 max=20 sleep_sec=15
              while [[ \$tries -lt \$max ]]; do
                if (echo > /dev/tcp/"\$host"/"\$port") 2>/dev/null; then
                  echo "  SSH port open: \$name (\$host:\$port)"
                  return 0
                fi
                echo "  Waiting for SSH on \$name (\$host:\$port) [attempt \$((tries+1))/\$max]..."
                sleep "\$sleep_sec"
                tries=\$((tries+1))
              done
              echo "  TIMEOUT waiting for SSH on \$name (\$host:\$port)"
              return 1
            }
            echo "Waiting for SSH on all VMs..."
            while IFS=\$'\t' read -r name host port; do
              [[ -z "\$name" ]] && continue
              port="\${port:-22}"
              wait_for_ssh_tcp "\$name" "\$host" "\$port" || { echo "FAILED_SSH_WAIT \$name"; exit 1; }
            done < /tmp/hosts.tsv
            while IFS=\$'\t' read -r name host port; do
              [[ -z "\$name" ]] && continue
              port="\${port:-22}"
              echo "===FILE:\${name}==="
              if [[ -f /tmp/ssh-privatekey ]] && ssh -i /tmp/ssh-privatekey -n -p "\$port" -o StrictHostKeyChecking=no \
                  -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
                  "\${SSH_USER}@\${host}" "cat \${LOG_PATH} 2>/dev/null || true" 2>/dev/null; then
                continue
              fi
              if [[ -n "\$PASS" ]]; then
                sshpass -p "\$PASS" ssh -n -p "\$port" -o StrictHostKeyChecking=no \
                  -o PreferredAuthentications=password -o PubkeyAuthentication=no \
                  -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
                  "\${SSH_USER}@\${host}" "cat \${LOG_PATH} 2>/dev/null || true" 2>/dev/null || true
              fi
            done < /tmp/hosts.tsv
      volumes:
      - name: ssh
        secret:
          secretName: ramendr-dr-collect-ssh
EOF

collect_failed=0
job_done=0
for _ in $(seq 1 120); do
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
