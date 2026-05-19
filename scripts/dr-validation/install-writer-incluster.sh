#!/usr/bin/env bash
# Install timestamp writers from a Job on the primary spoke (cluster network → NodePort SSH).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

require_cmd oc python3
ensure_hub_kubeconfig

PRIMARY="$(determine_primary_cluster)"
[[ -z "$PRIMARY" ]] && PRIMARY="ocp-primary"
SPOKE_KC="$(resolve_spoke_kubeconfig "$PRIMARY")"

PASS="${DR_VALIDATION_SSH_PASSWORD:-}"
if [[ -z "$PASS" ]]; then
  PASS="$(cloud_init_password_from_vault)"
fi
if [[ -z "$PASS" ]]; then
  err "In-cluster writer install requires a password (DR_VALIDATION_SSH_PASSWORD or Vault cloud-init password)."
  err "Private keys are not copied into the spoke cluster. Use install-writer.sh from a host that can reach NodePorts, or set a password."
  exit 1
fi

HOSTS="$(list_vm_ssh_hosts "$SPOKE_KC")"
if [[ -z "$HOSTS" ]]; then
  err "No SSH endpoints for VMs on $PRIMARY."
  exit 1
fi

log "Installing writers in-cluster on $PRIMARY (${VM_NAMESPACE})..."

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
mkdir -p "$TMP_DIR/ramendr_dr_validation"
install -m 0644 "$DR_VALIDATION_DIR/ramendr_dr_validation/records.py" "$TMP_DIR/ramendr_dr_validation/records.py"
touch "$TMP_DIR/ramendr_dr_validation/__init__.py"
install -m 0755 "$DR_VALIDATION_DIR/ramendr_dr_validation/writer.py" "$TMP_DIR/ramendr-dr-writer"
cp "$DR_VALIDATION_DIR/systemd/ramendr-dr-writer.service" "$TMP_DIR/ramendr-dr-writer.service"
printf '%s\n' "$HOSTS" > "$TMP_DIR/hosts.tsv"
log "SSH targets: $(wc -l < "$TMP_DIR/hosts.tsv" | tr -d ' ') VM(s)"

cleanup_writer_install_secret() {
  KUBECONFIG="$SPOKE_KC" oc delete secret ramendr-dr-writer-ssh -n "$VM_NAMESPACE" --ignore-not-found &>/dev/null || true
}

KUBECONFIG="$SPOKE_KC" oc create configmap ramendr-dr-writer-install \
  --from-file=ramendr-dr-writer="$TMP_DIR/ramendr-dr-writer" \
  --from-file=records.py="$TMP_DIR/ramendr_dr_validation/records.py" \
  --from-file=ramendr-dr-writer.service="$TMP_DIR/ramendr-dr-writer.service" \
  -n "$VM_NAMESPACE" --dry-run=client -o yaml | KUBECONFIG="$SPOKE_KC" oc apply -f -

KUBECONFIG="$SPOKE_KC" oc create secret generic ramendr-dr-writer-ssh \
  --from-file=hosts.tsv="$TMP_DIR/hosts.tsv" \
  --from-literal=password="$PASS" \
  -n "$VM_NAMESPACE" --dry-run=client -o yaml | KUBECONFIG="$SPOKE_KC" oc apply -f -

KUBECONFIG="$SPOKE_KC" oc delete job ramendr-dr-writer-install -n "$VM_NAMESPACE" --ignore-not-found
KUBECONFIG="$SPOKE_KC" oc apply -f - <<EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: ramendr-dr-writer-install
  namespace: ${VM_NAMESPACE}
spec:
  backoffLimit: 0
  template:
    spec:
      restartPolicy: Never
      containers:
      - name: install
        image: quay.io/validatedpatterns/utility-container:latest
        env:
        - name: SSH_USER
          value: "${SSH_USER}"
        volumeMounts:
        - name: payload
          mountPath: /payload
        - name: ssh
          mountPath: /ssh
          readOnly: true
        - name: hosts
          mountPath: /hosts
          readOnly: true
        command: ["bash", "-c"]
        args:
          - |
            set -uo pipefail
            dnf install -y sshpass openssh-clients >/dev/null 2>&1 || true
            cp /hosts/hosts.tsv /tmp/hosts.tsv
            echo "hosts count: $(wc -l < /tmp/hosts.tsv)"
            PASS="$(tr -d '\n' < /ssh/password)"
            install_on_vm() {
              local host="$1" port="$2"
              # shellcheck disable=SC2016
              local remote_install='sudo mkdir -p /var/lib/ramendr-dr-validation /usr/local/lib/ramendr_dr_validation /usr/local/bin && \
                sudo install -m 0644 /tmp/records.py /usr/local/lib/ramendr_dr_validation/records.py && \
                sudo touch /usr/local/lib/ramendr_dr_validation/__init__.py && \
                sudo install -m 0755 /tmp/ramendr-dr-writer /usr/local/bin/ramendr-dr-writer && \
                sudo install -m 0644 /tmp/ramendr-dr-writer.service /etc/systemd/system/ramendr-dr-writer.service && \
                sudo systemctl daemon-reload && sudo systemctl enable --now ramendr-dr-writer.service && \
                sleep 3 && systemctl is-active ramendr-dr-writer.service && \
                tail -n 2 /var/lib/ramendr-dr-validation/timestamps.log'
              sshpass -p "$PASS" scp -P "$port" -o StrictHostKeyChecking=no \
                /payload/ramendr-dr-writer /payload/records.py /payload/ramendr-dr-writer.service \
                "${SSH_USER}@${host}:/tmp/"
              sshpass -p "$PASS" ssh -n -p "$port" -o StrictHostKeyChecking=no "${SSH_USER}@${host}" "$remote_install"
            }
            while IFS=$'\t' read -r name host port; do
              [[ -z "$name" ]] && continue
              port="${port:-22}"
              echo "=== $name @ $host:$port ==="
              install_on_vm "$host" "$port" || { echo "FAILED $name"; exit 1; }
            done < /tmp/hosts.tsv
            echo "All writers installed."
      volumes:
      - name: payload
        configMap:
          name: ramendr-dr-writer-install
      - name: ssh
        secret:
          secretName: ramendr-dr-writer-ssh
      - name: hosts
        secret:
          secretName: ramendr-dr-writer-ssh
          items:
          - key: hosts.tsv
            path: hosts.tsv
EOF

for _ in $(seq 1 40); do
  if KUBECONFIG="$SPOKE_KC" oc get job ramendr-dr-writer-install -n "$VM_NAMESPACE" -o jsonpath='{.status.succeeded}' 2>/dev/null | grep -q 1; then
    logs="$(KUBECONFIG="$SPOKE_KC" oc logs -n "$VM_NAMESPACE" job/ramendr-dr-writer-install --tail=120 2>/dev/null || true)"
    echo "$logs"
    cleanup_writer_install_secret
    expected_vms="${DR_VALIDATION_EXPECTED_VMS:-4}"
    if echo "$logs" | grep -qE 'Permission denied \(publickey|ssh: connect to host.*Permission denied'; then
      err "SSH to edge VMs failed. Ensure values-secret vm-ssh/cloud-init match Vault and VMs were provisioned with cloud-init."
      exit 1
    fi
    installed=$(echo "$logs" | grep -cE '^=== ' || true)
    ts_lines=$(echo "$logs" | grep -cE '^[0-9]+,20[0-9]{2}-' || true)
    if [[ "$installed" -lt "$expected_vms" ]] || [[ "$ts_lines" -lt "$expected_vms" ]]; then
      err "Writer install incomplete: ${installed}/${expected_vms} VMs, ${ts_lines}/${expected_vms} timestamp samples in job log."
      exit 1
    fi
    log "In-cluster writer install completed on all ${installed}/${expected_vms} VM(s)."
    exit 0
  fi
  if KUBECONFIG="$SPOKE_KC" oc get job ramendr-dr-writer-install -n "$VM_NAMESPACE" -o jsonpath='{.status.failed}' 2>/dev/null | grep -q 1; then
    KUBECONFIG="$SPOKE_KC" oc logs -n "$VM_NAMESPACE" job/ramendr-dr-writer-install --tail=50
    cleanup_writer_install_secret
    exit 1
  fi
  sleep 15
done
cleanup_writer_install_secret
err "Timed out waiting for ramendr-dr-writer-install job."
exit 1
