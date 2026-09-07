#!/usr/bin/env bash
# Start or stop HammerDB autopilot + audit writers on all edge VMs via in-cluster SSH.
# Usage: control-hammerdb-load-incluster.sh start|stop
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

ACTION="${1:-}"
if [[ "$ACTION" != "start" && "$ACTION" != "stop" ]]; then
  err "Usage: $0 start|stop"
  exit 1
fi

require_cmd oc python3
ensure_hub_kubeconfig

PRIMARY="$(determine_primary_cluster)"
[[ -z "$PRIMARY" ]] && PRIMARY="ocp-primary"
SPOKE_KC="$(resolve_spoke_kubeconfig "$PRIMARY")"

LOAD_RUN_ID="${DR_VALIDATION_LOAD_RUN_ID:-$(date +%s)-$$}"
LOAD_JOB_NAME="ramendr-dr-hammerdb-load-${ACTION}-${LOAD_RUN_ID}"
LOAD_SECRET_NAME="ramendr-dr-hammerdb-load-ssh-${LOAD_RUN_ID}"

cleanup_load_secret() {
  KUBECONFIG="$SPOKE_KC" oc delete secret "$LOAD_SECRET_NAME" -n "$VM_NAMESPACE" --ignore-not-found &>/dev/null || true
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

load_cleanup() {
  [[ -n "${TMP_DIR:-}" && -d "$TMP_DIR" ]] && rm -rf "$TMP_DIR"
  cleanup_load_secret
  if [[ -n "${LOAD_JOB_NAME:-}" ]]; then
    KUBECONFIG="$SPOKE_KC" oc delete job "$LOAD_JOB_NAME" -n "$VM_NAMESPACE" --ignore-not-found &>/dev/null || true
  fi
}
trap load_cleanup EXIT

LOAD_SECRET_CREATE=(oc create secret generic "$LOAD_SECRET_NAME"
  --from-file=hosts.tsv="$TMP_DIR/hosts.tsv"
  -n "$VM_NAMESPACE" --dry-run=client -o yaml)
LOAD_SECRET_CREATE+=(--from-literal=linux-password="${LINUX_PASS:-}")
LOAD_SECRET_CREATE+=(--from-literal=windows-password="${WINDOWS_PASS:-}")
SSH_KEY_FILE="${SSH_IDENTITY_FILE:-}"
if [[ -z "$SSH_KEY_FILE" || ! -f "$SSH_KEY_FILE" ]]; then
  if [[ -f "$HOME/.ssh/id_ed25519" ]]; then
    SSH_KEY_FILE="$HOME/.ssh/id_ed25519"
  elif [[ -f "$HOME/.ssh/id_rsa" ]]; then
    SSH_KEY_FILE="$HOME/.ssh/id_rsa"
  fi
fi
if [[ -n "$SSH_KEY_FILE" && -f "$SSH_KEY_FILE" ]]; then
  LOAD_SECRET_CREATE+=(--from-file=ssh-privatekey="$SSH_KEY_FILE")
fi
KUBECONFIG="$SPOKE_KC" "${LOAD_SECRET_CREATE[@]}" | KUBECONFIG="$SPOKE_KC" oc apply -f -

if [[ "$ACTION" == "start" ]]; then
  log "Starting HammerDB autopilot + audit on all target edge VMs..."
else
  log "Stopping HammerDB autopilot + audit on all target edge VMs..."
fi

KUBECONFIG="$SPOKE_KC" oc apply -f - <<EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: ${LOAD_JOB_NAME}
  namespace: ${VM_NAMESPACE}
spec:
  backoffLimit: 0
  activeDeadlineSeconds: 900
  template:
    spec:
      restartPolicy: Never
      containers:
      - name: hammerdb-load
        image: ${DR_VALIDATION_UTILITY_CONTAINER_IMAGE}
        env:
        - name: HAMMERDB_LOAD_ACTION
          value: "${ACTION}"
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
            ACTION="\${HAMMERDB_LOAD_ACTION}"
            if [[ "\$ACTION" == "start" ]]; then
              LINUX_CMD="sudo systemctl start ramendr-dr-hammerdb.service ramendr-dr-db-audit.service"
              WINDOWS_CMD='powershell -NoProfile -ExecutionPolicy Bypass -Command "Start-ScheduledTask -TaskName ramendr-dr-hammerdb; Start-ScheduledTask -TaskName ramendr-dr-db-audit"'
            else
              LINUX_CMD="sudo systemctl stop ramendr-dr-hammerdb.service ramendr-dr-db-audit.service || true; sudo systemctl disable ramendr-dr-hammerdb.service ramendr-dr-db-audit.service || true; if sudo systemctl is-active --quiet ramendr-dr-hammerdb.service || sudo systemctl is-active --quiet ramendr-dr-db-audit.service; then exit 1; fi"
              WINDOWS_CMD='powershell -NoProfile -ExecutionPolicy Bypass -Command "Stop-ScheduledTask -TaskName ramendr-dr-hammerdb -ErrorAction SilentlyContinue; Stop-ScheduledTask -TaskName ramendr-dr-db-audit -ErrorAction SilentlyContinue; if (((Get-ScheduledTask -TaskName ramendr-dr-hammerdb -ErrorAction SilentlyContinue).State) -eq '\''Running'\'') { exit 1 }; if (((Get-ScheduledTask -TaskName ramendr-dr-db-audit -ErrorAction SilentlyContinue).State) -eq '\''Running'\'') { exit 1 }"'
            fi
            ssh_linux() {
              local host="\$1" port="\$2" ssh_user="\$3"
              local ssh_opts="-p \$port -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"
              if [[ -f /tmp/ssh-privatekey ]]; then
                ssh -i /tmp/ssh-privatekey -n \$ssh_opts "\${ssh_user}@\${host}" "\$LINUX_CMD" && return 0
              fi
              if [[ -n "\$LINUX_PASS" ]]; then
                sshpass -p "\$LINUX_PASS" ssh -n \$ssh_opts \
                  -o PreferredAuthentications=password -o PubkeyAuthentication=no \
                  "\${ssh_user}@\${host}" "\$LINUX_CMD" && return 0
              fi
              return 1
            }
            ssh_windows() {
              local host="\$1" port="\$2" ssh_user="\$3"
              local ssh_opts="-p \$port -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"
              if [[ -z "\$WINDOWS_PASS" ]]; then
                echo "WARN: skipping windows host \$host (no windows-password)" >&2
                return 1
              fi
              sshpass -p "\$WINDOWS_PASS" ssh -n \$ssh_opts \
                -o PreferredAuthentications=password -o PubkeyAuthentication=no \
                "\${ssh_user}@\${host}" "\$WINDOWS_CMD"
            }
            fail=0
            while IFS=\$'\t' read -r name host port platform ssh_user; do
              [[ -z "\$name" ]] && continue
              port="\${port:-22}"
              echo "===LOAD:\${ACTION}:\${name}==="
              if [[ "\$platform" == windows ]]; then
                if ssh_windows "\$host" "\$port" "\$ssh_user"; then
                  echo "OK \${name} (\${ACTION})"
                else
                  echo "FAIL \${name} (\${ACTION})"
                  fail=1
                fi
              else
                if ssh_linux "\$host" "\$port" "\$ssh_user"; then
                  echo "OK \${name} (\${ACTION})"
                else
                  echo "FAIL \${name} (\${ACTION})"
                  fail=1
                fi
              fi
            done < /tmp/hosts.tsv
            exit "\$fail"
      volumes:
      - name: ssh
        secret:
          secretName: ${LOAD_SECRET_NAME}
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

job_done=0
job_failed=0
for _ in $(seq 1 90); do
  if KUBECONFIG="$SPOKE_KC" oc get job "$LOAD_JOB_NAME" -n "$VM_NAMESPACE" -o jsonpath='{.status.succeeded}' 2>/dev/null | grep -q 1; then
    job_done=1
    break
  fi
  if KUBECONFIG="$SPOKE_KC" oc get job "$LOAD_JOB_NAME" -n "$VM_NAMESPACE" -o jsonpath='{.status.failed}' 2>/dev/null | grep -q 1; then
    job_failed=1
    job_done=1
    break
  fi
  sleep 5
done

KUBECONFIG="$SPOKE_KC" oc logs -n "$VM_NAMESPACE" "job/${LOAD_JOB_NAME}" || true

if [[ "$job_failed" -eq 1 ]]; then
  err "HammerDB load ${ACTION} job failed."
  exit 1
fi
if [[ "$job_done" -ne 1 ]]; then
  err "Timed out waiting for ${LOAD_JOB_NAME} job."
  exit 1
fi

log "HammerDB load ${ACTION} completed."
