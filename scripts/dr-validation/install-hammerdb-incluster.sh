#!/usr/bin/env bash
# Install PostgreSQL + HammerDB TPC-C workload on the DR validation edge VM.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

require_cmd oc python3
ensure_hub_kubeconfig

PRIMARY="$(determine_primary_cluster)"
[[ -z "$PRIMARY" ]] && PRIMARY="ocp-primary"
SPOKE_KC="$(resolve_spoke_kubeconfig "$PRIMARY")"

cleanup_hammerdb_install_secret() {
  KUBECONFIG="$SPOKE_KC" oc delete secret ramendr-dr-hammerdb-ssh -n "$VM_NAMESPACE" --ignore-not-found &>/dev/null || true
}

cleanup_hammerdb_install_resources() {
  [[ -n "${TMP_DIR:-}" && -d "$TMP_DIR" ]] && rm -rf "$TMP_DIR"
  cleanup_hammerdb_install_secret
  KUBECONFIG="$SPOKE_KC" oc delete configmap ramendr-dr-hammerdb-install -n "$VM_NAMESPACE" --ignore-not-found &>/dev/null || true
}
trap cleanup_hammerdb_install_resources EXIT INT TERM

PASS="${DR_VALIDATION_SSH_PASSWORD:-}"
if [[ -z "$PASS" ]]; then
  PASS="$(cloud_init_password_from_vault)"
fi
SSH_KEY_FILE="${SSH_IDENTITY_FILE:-}"
if [[ "${DR_VALIDATION_INCLUSTER_SSH_KEY:-1}" == "1" ]]; then
  if [[ -z "$SSH_KEY_FILE" || ! -f "$SSH_KEY_FILE" ]]; then
    if [[ -f "$HOME/.ssh/id_ed25519" ]]; then
      SSH_KEY_FILE="$HOME/.ssh/id_ed25519"
    elif [[ -f "$HOME/.ssh/id_rsa" ]]; then
      SSH_KEY_FILE="$HOME/.ssh/id_rsa"
    fi
  fi
else
  SSH_KEY_FILE=""
fi
if [[ -z "$PASS" && ( -z "$SSH_KEY_FILE" || ! -f "$SSH_KEY_FILE" ) ]]; then
  err "In-cluster HammerDB install needs DR_VALIDATION_SSH_PASSWORD, Vault cloud-init password, or a local SSH key."
  exit 1
fi

HOSTS="$(get_hammerdb_vm_host "$SPOKE_KC")"
[[ -n "$HOSTS" ]] || exit 1

log "Installing HammerDB PostgreSQL workload on ${DR_VALIDATION_HAMMERDB_VM} (${PRIMARY})..."

TMP_DIR="$(mktemp -d)"
mkdir -p "$TMP_DIR/ramendr_dr_validation/backends" "$TMP_DIR/hammerdb/sql" "$TMP_DIR/systemd"
install -m 0755 "$DR_VALIDATION_DIR/hammerdb/install-on-vm.sh" "$TMP_DIR/hammerdb/install-on-vm.sh"
install -m 0755 "$DR_VALIDATION_DIR/hammerdb/run-autopilot.sh" "$TMP_DIR/hammerdb/run-autopilot.sh"
install -m 0644 "$DR_VALIDATION_DIR/hammerdb/sql/init-audit.sql" "$TMP_DIR/hammerdb/sql/init-audit.sql"
install -m 0644 "$DR_VALIDATION_DIR/ramendr_dr_validation/db_audit.py" "$TMP_DIR/ramendr_dr_validation/db_audit.py"
install -m 0644 "$DR_VALIDATION_DIR/ramendr_dr_validation/db_snapshot.py" "$TMP_DIR/ramendr_dr_validation/db_snapshot.py"
install -m 0644 "$DR_VALIDATION_DIR/ramendr_dr_validation/backends/postgres.py" "$TMP_DIR/ramendr_dr_validation/backends/postgres.py"
install -m 0644 "$DR_VALIDATION_DIR/ramendr_dr_validation/backends/__init__.py" "$TMP_DIR/ramendr_dr_validation/backends/__init__.py"
touch "$TMP_DIR/ramendr_dr_validation/__init__.py"
install -m 0644 "$DR_VALIDATION_DIR/systemd/ramendr-dr-db-audit.service" "$TMP_DIR/systemd/ramendr-dr-db-audit.service"
install -m 0644 "$DR_VALIDATION_DIR/systemd/ramendr-dr-hammerdb.service" "$TMP_DIR/systemd/ramendr-dr-hammerdb.service"
printf '%s\n' "$HOSTS" > "$TMP_DIR/hosts.tsv"

tar -C "$TMP_DIR" -czf "$TMP_DIR/payload.tgz" hammerdb ramendr_dr_validation systemd

KUBECONFIG="$SPOKE_KC" oc create configmap ramendr-dr-hammerdb-install \
  --from-file=payload.tgz="$TMP_DIR/payload.tgz" \
  -n "$VM_NAMESPACE" --dry-run=client -o yaml | KUBECONFIG="$SPOKE_KC" oc apply -f -

SECRET_CREATE=(oc create secret generic ramendr-dr-hammerdb-ssh
  --from-file=hosts.tsv="$TMP_DIR/hosts.tsv"
  -n "$VM_NAMESPACE" --dry-run=client -o yaml)
[[ -n "$PASS" ]] && SECRET_CREATE+=(--from-literal=password="$PASS")
if [[ -n "$SSH_KEY_FILE" && -f "$SSH_KEY_FILE" ]]; then
  SECRET_CREATE+=(--from-file=ssh-privatekey="$SSH_KEY_FILE")
fi
KUBECONFIG="$SPOKE_KC" "${SECRET_CREATE[@]}" | KUBECONFIG="$SPOKE_KC" oc apply -f -

KUBECONFIG="$SPOKE_KC" oc delete job ramendr-dr-hammerdb-install -n "$VM_NAMESPACE" --ignore-not-found
if KUBECONFIG="$SPOKE_KC" oc get job ramendr-dr-hammerdb-install -n "$VM_NAMESPACE" >/dev/null 2>&1; then
  KUBECONFIG="$SPOKE_KC" oc wait --for=delete job/ramendr-dr-hammerdb-install \
    -n "$VM_NAMESPACE" --timeout=120s
fi
KUBECONFIG="$SPOKE_KC" oc apply -f - <<EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: ramendr-dr-hammerdb-install
  namespace: ${VM_NAMESPACE}
spec:
  backoffLimit: 0
  activeDeadlineSeconds: 3600
  template:
    spec:
      restartPolicy: Never
      containers:
      - name: install
        image: ${DR_VALIDATION_UTILITY_CONTAINER_IMAGE}
        env:
        - name: SSH_USER
          value: "${SSH_USER}"
        - name: DR_VALIDATION_HAMMERDB_VM
          value: "${DR_VALIDATION_HAMMERDB_VM}"
        volumeMounts:
        - name: payload
          mountPath: /payload
        - name: ssh
          mountPath: /ssh
          readOnly: true
        command: ["bash", "-c"]
        args:
          - |
            set -euo pipefail
            dnf install -y sshpass openssh-clients tar gzip >/dev/null 2>&1 || true
            PASS="\$(tr -d '\n' < /ssh/password 2>/dev/null || true)"
            test -f /ssh/ssh-privatekey && cp /ssh/ssh-privatekey /tmp/ssh-privatekey && chmod 600 /tmp/ssh-privatekey || true
            cp /ssh/hosts.tsv /tmp/hosts.tsv
            mkdir -p /tmp/ramendr-dr-validation-install
            tar -xzf /payload/payload.tgz -C /tmp/ramendr-dr-validation-install
            wait_for_ssh_tcp() {
              local name="\$1" host="\$2" port="\$3"
              local tries=0 max=40 sleep_sec=15
              while [[ \$tries -lt \$max ]]; do
                if (echo > /dev/tcp/"\$host"/"\$port") 2>/dev/null; then
                  echo "  SSH port open: \$name (\$host:\$port)"
                  return 0
                fi
                echo "  Waiting for SSH on \$name (\$host:\$port) [attempt \$((tries+1))/\$max]..."
                sleep "\$sleep_sec"
                tries=\$((tries+1))
              done
              return 1
            }
            while IFS=\$'\t' read -r name host port; do
              [[ -z "\$name" ]] && continue
              port="\${port:-22}"
              wait_for_ssh_tcp "\$name" "\$host" "\$port" || exit 1
            done < /tmp/hosts.tsv
            install_on_vm() {
              local host="\$1" port="\$2"
              local scp_opts="-P \$port -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"
              local ssh_opts="-p \$port -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"
              local remote="mkdir -p /tmp/ramendr-dr-validation-install && tar -xzf /tmp/payload.tgz -C /tmp/ramendr-dr-validation-install && REPO_ROOT=/tmp/ramendr-dr-validation-install bash /tmp/ramendr-dr-validation-install/hammerdb/install-on-vm.sh"
              if [[ -f /tmp/ssh-privatekey ]] && scp -i /tmp/ssh-privatekey \$scp_opts /payload/payload.tgz \
                  "\${SSH_USER}@\${host}:/tmp/payload.tgz" && \
                ssh -i /tmp/ssh-privatekey -n \$ssh_opts "\${SSH_USER}@\${host}" "\$remote"; then
                return 0
              fi
              if [[ -n "\$PASS" ]]; then
                sshpass -p "\$PASS" scp \$scp_opts /payload/payload.tgz "\${SSH_USER}@\${host}:/tmp/payload.tgz" && \
                sshpass -p "\$PASS" ssh -n \$ssh_opts \
                  -o PreferredAuthentications=password -o PubkeyAuthentication=no \
                  "\${SSH_USER}@\${host}" "\$remote"
              else
                return 1
              fi
            }
            while IFS=\$'\t' read -r name host port; do
              [[ -z "\$name" ]] && continue
              port="\${port:-22}"
              echo "=== \$name @ \$host:\$port ==="
              install_on_vm "\$host" "\$port" || { echo "FAILED \$name"; exit 1; }
            done < /tmp/hosts.tsv
            echo "HammerDB install completed."
      volumes:
      - name: payload
        configMap:
          name: ramendr-dr-hammerdb-install
      - name: ssh
        secret:
          secretName: ramendr-dr-hammerdb-ssh
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

for _ in $(seq 1 120); do
  if KUBECONFIG="$SPOKE_KC" oc get job ramendr-dr-hammerdb-install -n "$VM_NAMESPACE" -o jsonpath='{.status.succeeded}' 2>/dev/null | grep -q 1; then
    logs="$(KUBECONFIG="$SPOKE_KC" oc logs -n "$VM_NAMESPACE" job/ramendr-dr-hammerdb-install --tail=120 2>/dev/null || true)"
    echo "$logs"
    cleanup_hammerdb_install_secret
    if echo "$logs" | grep -q "HammerDB install OK"; then
      log "HammerDB PostgreSQL workload is running on ${DR_VALIDATION_HAMMERDB_VM}."
      exit 0
    fi
    err "HammerDB install job finished without success marker."
    exit 1
  fi
  if KUBECONFIG="$SPOKE_KC" oc get job ramendr-dr-hammerdb-install -n "$VM_NAMESPACE" -o jsonpath='{.status.failed}' 2>/dev/null | grep -q 1; then
    KUBECONFIG="$SPOKE_KC" oc logs -n "$VM_NAMESPACE" job/ramendr-dr-hammerdb-install --tail=80
    cleanup_hammerdb_install_secret
    exit 1
  fi
  sleep 15
done
cleanup_hammerdb_install_secret
err "Timed out waiting for ramendr-dr-hammerdb-install job."
exit 1
