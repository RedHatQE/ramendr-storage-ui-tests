#!/usr/bin/env bash
# Collect PostgreSQL / SQL Server DR validation snapshots from HammerDB edge VMs via in-cluster SSH.
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

COLLECT_RUN_ID="${DR_VALIDATION_COLLECT_RUN_ID:-$(date +%s)-$$}"
COLLECT_JOB_NAME="ramendr-dr-db-collect-${COLLECT_RUN_ID}"
COLLECT_SECRET_NAME="ramendr-dr-db-collect-ssh-${COLLECT_RUN_ID}"

cleanup_collect_secret() {
  KUBECONFIG="$SPOKE_KC" oc delete secret "$COLLECT_SECRET_NAME" -n "$VM_NAMESPACE" --ignore-not-found &>/dev/null || true
}

HOSTS="$(get_hammerdb_vm_hosts "$SPOKE_KC")"
[[ -n "$HOSTS" ]] || exit 1

LINUX_PASS="${DR_VALIDATION_SSH_PASSWORD:-}"
if [[ -z "$LINUX_PASS" ]]; then
  LINUX_PASS="$(cloud_init_password_from_vault)"
fi
WINDOWS_PASS="${WINDOWS_SSH_PASSWORD:-}"
if [[ -z "$WINDOWS_PASS" ]]; then
  load_windows_ssh_password || true
  WINDOWS_PASS="${WINDOWS_SSH_PASSWORD:-}"
fi

TMP_DIR="$(mktemp -d)"
printf '%s\n' "$HOSTS" > "$TMP_DIR/hosts.tsv"

collect_db_cleanup() {
  [[ -n "${TMP_DIR:-}" && -d "$TMP_DIR" ]] && rm -rf "$TMP_DIR"
  cleanup_collect_secret
  if [[ -n "${COLLECT_JOB_NAME:-}" ]]; then
    KUBECONFIG="$SPOKE_KC" oc delete job "$COLLECT_JOB_NAME" -n "$VM_NAMESPACE" --ignore-not-found &>/dev/null || true
  fi
}
trap collect_db_cleanup EXIT

COLLECT_SECRET_CREATE=(oc create secret generic "$COLLECT_SECRET_NAME"
  --from-file=hosts.tsv="$TMP_DIR/hosts.tsv"
  -n "$VM_NAMESPACE" --dry-run=client -o yaml)
COLLECT_SECRET_CREATE+=(--from-literal=linux-password="${LINUX_PASS:-}")
COLLECT_SECRET_CREATE+=(--from-literal=windows-password="${WINDOWS_PASS:-}")
SSH_KEY_FILE="${SSH_IDENTITY_FILE:-}"
if [[ -z "$SSH_KEY_FILE" || ! -f "$SSH_KEY_FILE" ]]; then
  [[ -f "$HOME/.ssh/id_ed25519" ]] && SSH_KEY_FILE="$HOME/.ssh/id_ed25519"
fi
if [[ -n "$SSH_KEY_FILE" && -f "$SSH_KEY_FILE" ]]; then
  COLLECT_SECRET_CREATE+=(--from-file=ssh-privatekey="$SSH_KEY_FILE")
fi
KUBECONFIG="$SPOKE_KC" "${COLLECT_SECRET_CREATE[@]}" | KUBECONFIG="$SPOKE_KC" oc apply -f -

KUBECONFIG="$SPOKE_KC" oc apply -f - <<EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: ${COLLECT_JOB_NAME}
  namespace: ${VM_NAMESPACE}
spec:
  backoffLimit: 0
  activeDeadlineSeconds: 1800
  template:
    spec:
      restartPolicy: Never
      containers:
      - name: collect
        image: ${DR_VALIDATION_UTILITY_CONTAINER_IMAGE}
        env:
        - name: DR_VALIDATION_SNAPSHOT_STATUS_ONLY
          value: "${DR_VALIDATION_SNAPSHOT_STATUS_ONLY:-0}"
        volumeMounts:
        - name: ssh
          mountPath: /ssh
          readOnly: true
        command: ["bash", "-c"]
        args:
          - |
            set -euo pipefail
            dnf install -y sshpass openssh-clients >/dev/null 2>&1 || true
            LINUX_PASS="\$(tr -d '\n' < /ssh/linux-password 2>/dev/null || true)"
            WINDOWS_PASS="\$(tr -d '\n' < /ssh/windows-password 2>/dev/null || true)"
            test -f /ssh/ssh-privatekey && cp /ssh/ssh-privatekey /tmp/ssh-privatekey && chmod 600 /tmp/ssh-privatekey || true
            cp /ssh/hosts.tsv /tmp/hosts.tsv
            refresh_linux_audit() {
              local host="\$1" port="\$2" ssh_user="\$3"
              local ssh_opts="-p \$port -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"
              local cmd="sudo systemctl restart ramendr-dr-db-audit.service"
              if [[ -f /tmp/ssh-privatekey ]]; then
                ssh -i /tmp/ssh-privatekey -n \$ssh_opts "\${ssh_user}@\${host}" "\$cmd" || return 1
                return 0
              fi
              if [[ -n "\$LINUX_PASS" ]]; then
                sshpass -p "\$LINUX_PASS" ssh -n \$ssh_opts \
                  -o PreferredAuthentications=password -o PubkeyAuthentication=no \
                  "\${ssh_user}@\${host}" "\$cmd" || return 1
                return 0
              fi
              return 1
            }
            refresh_windows_audit() {
              local host="\$1" port="\$2" ssh_user="\$3"
              local ssh_opts="-p \$port -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"
              local cmd='powershell -NoProfile -ExecutionPolicy Bypass -Command "Stop-ScheduledTask -TaskName ramendr-dr-db-audit -ErrorAction SilentlyContinue; Start-ScheduledTask -TaskName ramendr-dr-db-audit"'
              if [[ -z "\$WINDOWS_PASS" ]]; then
                return 1
              fi
              sshpass -p "\$WINDOWS_PASS" ssh -n \$ssh_opts \
                -o PreferredAuthentications=password -o PubkeyAuthentication=no \
                "\${ssh_user}@\${host}" "\$cmd" || return 1
            }
            collect_linux() {
              local name="\$1" host="\$2" port="\$3" ssh_user="\$4"
              local remote_cmd="sudo /usr/local/bin/ramendr-dr-db-snapshot --vm-name \${name}"
              if [[ "\${DR_VALIDATION_SNAPSHOT_STATUS_ONLY:-0}" == "1" ]]; then
                remote_cmd="\${remote_cmd} --status-only"
              fi
              local ssh_opts="-p \$port -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"
              refresh_linux_audit "\$host" "\$port" "\$ssh_user" || echo "WARN: could not refresh audit on \${name}" >&2
              sleep 15
              if [[ -f /tmp/ssh-privatekey ]] && ssh -i /tmp/ssh-privatekey -n \$ssh_opts "\${ssh_user}@\${host}" "\$remote_cmd" 2>/dev/null; then
                return 0
              fi
              if [[ -n "\$LINUX_PASS" ]]; then
                sshpass -p "\$LINUX_PASS" ssh -n \$ssh_opts \
                  -o PreferredAuthentications=password -o PubkeyAuthentication=no \
                  "\${ssh_user}@\${host}" "\$remote_cmd" 2>/dev/null || return 1
              fi
              return 1
            }
            collect_windows() {
              local name="\$1" host="\$2" port="\$3" ssh_user="\$4"
              local remote_cmd="powershell -NoProfile -ExecutionPolicy Bypass -File C:\\ProgramData\\ramendr-dr-validation\\bin\\ramendr-dr-db-snapshot.ps1 --vm-name \${name}"
              if [[ "\${DR_VALIDATION_SNAPSHOT_STATUS_ONLY:-0}" == "1" ]]; then
                remote_cmd="\${remote_cmd} --status-only"
              fi
              local ssh_opts="-p \$port -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"
              if [[ -z "\$WINDOWS_PASS" ]]; then
                echo "WARN: skipping \$name (no windows-password)" >&2
                return 1
              fi
              refresh_windows_audit "\$host" "\$port" "\$ssh_user" || echo "WARN: could not refresh audit on \${name}" >&2
              sleep 15
              sshpass -p "\$WINDOWS_PASS" ssh -n \$ssh_opts \
                -o PreferredAuthentications=password -o PubkeyAuthentication=no \
                "\${ssh_user}@\${host}" "\$remote_cmd" 2>/dev/null || return 1
            }
            while IFS=\$'\t' read -r name host port platform ssh_user; do
              [[ -z "\$name" ]] && continue
              port="\${port:-22}"
              echo "===SNAPSHOT:\${name}==="
              if [[ "\$platform" == windows ]]; then
                collect_windows "\$name" "\$host" "\$port" "\$ssh_user" || true
              else
                collect_linux "\$name" "\$host" "\$port" "\$ssh_user" || true
              fi
            done < /tmp/hosts.tsv
      volumes:
      - name: ssh
        secret:
          secretName: ${COLLECT_SECRET_NAME}
          items:
          - key: hosts.tsv
            path: hosts.tsv
          - key: linux-password
            path: linux-password
            optional: true
          - key: windows-password
            path: windows-password
            optional: true
          - key: ssh-privatekey
            path: ssh-privatekey
            optional: true
EOF

collect_failed=0
job_done=0
for _ in $(seq 1 180); do
  if KUBECONFIG="$SPOKE_KC" oc get job "$COLLECT_JOB_NAME" -n "$VM_NAMESPACE" -o jsonpath='{.status.succeeded}' 2>/dev/null | grep -q 1; then
    job_done=1
    break
  fi
  if KUBECONFIG="$SPOKE_KC" oc get job "$COLLECT_JOB_NAME" -n "$VM_NAMESPACE" -o jsonpath='{.status.failed}' 2>/dev/null | grep -q 1; then
    KUBECONFIG="$SPOKE_KC" oc logs -n "$VM_NAMESPACE" "job/${COLLECT_JOB_NAME}"
    collect_failed=1
    job_done=1
    break
  fi
  sleep 10
done

if [[ "$collect_failed" -eq 1 ]]; then
  cleanup_collect_secret
  KUBECONFIG="$SPOKE_KC" oc delete job "$COLLECT_JOB_NAME" -n "$VM_NAMESPACE" --ignore-not-found &>/dev/null || true
  exit 1
fi
if [[ "$job_done" -ne 1 ]]; then
  cleanup_collect_secret
  KUBECONFIG="$SPOKE_KC" oc delete job "$COLLECT_JOB_NAME" -n "$VM_NAMESPACE" --ignore-not-found &>/dev/null || true
  err "Timed out waiting for ${COLLECT_JOB_NAME} job."
  exit 1
fi

mkdir -p "$OUT_DIR"
KUBECONFIG="$SPOKE_KC" oc logs -n "$VM_NAMESPACE" "job/${COLLECT_JOB_NAME}" > "$TMP_DIR/collect.raw"
cleanup_collect_secret
KUBECONFIG="$SPOKE_KC" oc delete job "$COLLECT_JOB_NAME" -n "$VM_NAMESPACE" --ignore-not-found &>/dev/null || true

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

expected_count="$(hammerdb_target_vm_count)"
cat >"${OUT_DIR}/metadata.json" <<META
{
  "collected_at_utc": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "primary_cluster": "${PRIMARY}",
  "validation_mode": "hammerdb",
  "hammerdb_target_count": ${expected_count},
  "snapshots_collected": ${snapshot_count:-0}
}
META

if [[ "${snapshot_count:-0}" -lt 1 ]]; then
  err "No DB snapshot JSON extracted from collect job output."
  exit 1
fi

if is_auto_db_snapshot_dir "$OUT_DIR"; then
  update_latest_db_snapshot_link "$OUT_DIR"
  prune_auto_snapshots_db
  log "Collected ${snapshot_count} DB snapshot(s) -> ${OUT_DIR} (latest -> ${DR_VALIDATION_DB_SNAPSHOT_ROOT}/latest)"
else
  log "Collected ${snapshot_count} DB snapshot(s) -> ${OUT_DIR}"
fi
