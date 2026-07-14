#!/usr/bin/env bash
# Install PostgreSQL/SQL Server + HammerDB TPC-C workload on DR validation edge VMs.
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

LINUX_PASS="${DR_VALIDATION_SSH_PASSWORD:-}"
if [[ -z "$LINUX_PASS" ]]; then
  LINUX_PASS="$(cloud_init_password_from_vault)"
fi
WINDOWS_PASS="${WINDOWS_SSH_PASSWORD:-}"
if [[ -z "$WINDOWS_PASS" ]]; then
  load_windows_ssh_password || true
  WINDOWS_PASS="${WINDOWS_SSH_PASSWORD:-}"
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
if [[ -z "$LINUX_PASS" && ( -z "$SSH_KEY_FILE" || ! -f "$SSH_KEY_FILE" ) ]]; then
  err "In-cluster HammerDB install needs DR_VALIDATION_SSH_PASSWORD, Vault cloud-init password, or a local SSH key."
  exit 1
fi

HOSTS="$(get_hammerdb_vm_hosts "$SPOKE_KC")"
[[ -n "$HOSTS" ]] || exit 1
TARGET_COUNT="$(echo "$HOSTS" | wc -l | tr -d ' ')"
if echo "$HOSTS" | awk -F '\t' '$4 == "windows" { found=1 } END { exit !found }'; then
  if [[ -z "$WINDOWS_PASS" ]]; then
    err "Windows HammerDB target(s) require WINDOWS_SSH_PASSWORD or windows-admin in VALUES_SECRET."
    exit 1
  fi
  ensure_mssql_credentials || exit 1
fi
log "Installing HammerDB workload on ${TARGET_COUNT} edge VM(s) (${PRIMARY})..."

TMP_DIR="$(mktemp -d)"
mkdir -p "$TMP_DIR/ramendr_dr_validation/backends" "$TMP_DIR/hammerdb/sql" "$TMP_DIR/hammerdb/lib" "$TMP_DIR/systemd"
install -m 0755 "$DR_VALIDATION_DIR/hammerdb/install-on-vm.sh" "$TMP_DIR/hammerdb/install-on-vm.sh"
install -m 0755 "$DR_VALIDATION_DIR/hammerdb/lib/ensure-data-disk-linux.sh" "$TMP_DIR/hammerdb/lib/ensure-data-disk-linux.sh"
install -m 0755 "$DR_VALIDATION_DIR/hammerdb/run-autopilot.sh" "$TMP_DIR/hammerdb/run-autopilot.sh"
install -m 0644 "$DR_VALIDATION_DIR/hammerdb/install-on-vm-windows.ps1" "$TMP_DIR/hammerdb/install-on-vm-windows.ps1"
install -m 0644 "$DR_VALIDATION_DIR/hammerdb/install-remote-windows.cmd" "$TMP_DIR/hammerdb/install-remote-windows.cmd"
install -m 0644 "$DR_VALIDATION_DIR/hammerdb/run-autopilot-mssql.ps1" "$TMP_DIR/hammerdb/run-autopilot-mssql.ps1"
install -m 0644 "$DR_VALIDATION_DIR/hammerdb/sql/init-audit.sql" "$TMP_DIR/hammerdb/sql/init-audit.sql"
install -m 0644 "$DR_VALIDATION_DIR/hammerdb/sql/init-audit-mssql.sql" "$TMP_DIR/hammerdb/sql/init-audit-mssql.sql"
install -m 0644 "$DR_VALIDATION_DIR/ramendr_dr_validation/db_audit.py" "$TMP_DIR/ramendr_dr_validation/db_audit.py"
install -m 0644 "$DR_VALIDATION_DIR/ramendr_dr_validation/db_audit_mssql.py" "$TMP_DIR/ramendr_dr_validation/db_audit_mssql.py"
install -m 0644 "$DR_VALIDATION_DIR/ramendr_dr_validation/db_snapshot_common.py" "$TMP_DIR/ramendr_dr_validation/db_snapshot_common.py"
install -m 0644 "$DR_VALIDATION_DIR/ramendr_dr_validation/db_snapshot.py" "$TMP_DIR/ramendr_dr_validation/db_snapshot.py"
install -m 0644 "$DR_VALIDATION_DIR/ramendr_dr_validation/db_snapshot_mssql.py" "$TMP_DIR/ramendr_dr_validation/db_snapshot_mssql.py"
install -m 0644 "$DR_VALIDATION_DIR/ramendr_dr_validation/tpcc_schema.py" "$TMP_DIR/ramendr_dr_validation/tpcc_schema.py"
install -m 0644 "$DR_VALIDATION_DIR/ramendr_dr_validation/backends/postgres.py" "$TMP_DIR/ramendr_dr_validation/backends/postgres.py"
install -m 0644 "$DR_VALIDATION_DIR/ramendr_dr_validation/backends/mssql.py" "$TMP_DIR/ramendr_dr_validation/backends/mssql.py"
install -m 0644 "$DR_VALIDATION_DIR/ramendr_dr_validation/backends/__init__.py" "$TMP_DIR/ramendr_dr_validation/backends/__init__.py"
touch "$TMP_DIR/ramendr_dr_validation/__init__.py"
install -m 0644 "$DR_VALIDATION_DIR/systemd/ramendr-dr-db-audit.service" "$TMP_DIR/systemd/ramendr-dr-db-audit.service"
install -m 0644 "$DR_VALIDATION_DIR/systemd/ramendr-dr-hammerdb.service" "$TMP_DIR/systemd/ramendr-dr-hammerdb.service"
printf '%s\n' "$HOSTS" > "$TMP_DIR/hosts.tsv"

tar -C "$TMP_DIR" -czf "$TMP_DIR/payload.tgz" hammerdb ramendr_dr_validation systemd

KUBECONFIG="$SPOKE_KC" oc create configmap ramendr-dr-hammerdb-install \
  --from-file=payload.tgz="$TMP_DIR/payload.tgz" \
  --from-file=install-remote-windows.cmd="$DR_VALIDATION_DIR/hammerdb/install-remote-windows.cmd" \
  -n "$VM_NAMESPACE" --dry-run=client -o yaml | KUBECONFIG="$SPOKE_KC" oc apply -f -

SECRET_CREATE=(oc create secret generic ramendr-dr-hammerdb-ssh
  --from-file=hosts.tsv="$TMP_DIR/hosts.tsv"
  -n "$VM_NAMESPACE" --dry-run=client -o yaml)
SECRET_CREATE+=(--from-literal=linux-password="${LINUX_PASS:-}")
SECRET_CREATE+=(--from-literal=windows-password="${WINDOWS_PASS:-}")
if [[ -n "${DR_VALIDATION_MSSQL_SA_PASSWORD:-}" ]]; then
  SECRET_CREATE+=(--from-literal=mssql-sa-password="${DR_VALIDATION_MSSQL_SA_PASSWORD}")
  SECRET_CREATE+=(--from-literal=mssql-user="${DR_VALIDATION_MSSQL_USER}")
  SECRET_CREATE+=(--from-literal=mssql-password="${DR_VALIDATION_MSSQL_PASSWORD}")
fi
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
  activeDeadlineSeconds: 14400
  template:
    spec:
      restartPolicy: Never
      containers:
      - name: install
        image: ${DR_VALIDATION_UTILITY_CONTAINER_IMAGE}
        env:
        - name: TARGET_COUNT
          value: "${TARGET_COUNT}"
        - name: DR_VALIDATION_SQL_SSEI_URL
          value: "${DR_VALIDATION_SQL_SSEI_URL}"
        - name: DR_VALIDATION_PYTHON_WINDOWS_URL
          value: "${DR_VALIDATION_PYTHON_WINDOWS_URL}"
        - name: DR_VALIDATION_ODBC_DRIVER_MSI_URL
          value: "${DR_VALIDATION_ODBC_DRIVER_MSI_URL}"
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
            LINUX_PASS="\$(tr -d '\n' < /ssh/linux-password 2>/dev/null || true)"
            WINDOWS_PASS="\$(tr -d '\n' < /ssh/windows-password 2>/dev/null || true)"
            MSSQL_SA="\$(tr -d '\n' < /ssh/mssql-sa-password 2>/dev/null || true)"
            MSSQL_USER="\$(tr -d '\n' < /ssh/mssql-user 2>/dev/null || true)"
            MSSQL_PASSWORD="\$(tr -d '\n' < /ssh/mssql-password 2>/dev/null || true)"
            test -f /ssh/ssh-privatekey && cp /ssh/ssh-privatekey /tmp/ssh-privatekey && chmod 600 /tmp/ssh-privatekey || true
            cp /ssh/hosts.tsv /tmp/hosts.tsv
            mkdir -p /tmp/ramendr-dr-validation-install /tmp/windows-staging
            tar -xzf /payload/payload.tgz -C /tmp/ramendr-dr-validation-install
            WINDOWS_TARGETS=0
            while IFS=\$'\t' read -r name _ _ platform _; do
              [[ "\$platform" == windows ]] && WINDOWS_TARGETS=1 && break
            done < /tmp/hosts.tsv
            if [[ "\$WINDOWS_TARGETS" -eq 1 ]]; then
              HAMMER_VERSION="\${HAMMERDB_VERSION:-5.0}"
              HAMMER_ZIP="HammerDB-\${HAMMER_VERSION}-Prod-Win.tar.gz"
              SQL_INSTALLER="SQL2022-SSEI-Expr.exe"
              PYTHON_INSTALLER="python-amd64.exe"
              ODBC_INSTALLER="msodbcsql17.exe"
              if [[ ! -s "/tmp/windows-staging/\${SQL_INSTALLER}" ]]; then
                echo "Staging SQL Server 2022 Express bootstrapper for Windows targets..."
                curl -fL -o "/tmp/windows-staging/\${SQL_INSTALLER}" \
                  "\${DR_VALIDATION_SQL_SSEI_URL:-https://download.microsoft.com/download/5/1/4/5145fe04-4d30-4b85-b0d1-39533663a2f1/SQL2022-SSEI-Expr.exe}" || true
              fi
              if [[ ! -s "/tmp/windows-staging/\${PYTHON_INSTALLER}" ]]; then
                echo "Staging Python Windows installer for Windows targets..."
                curl -fL -o "/tmp/windows-staging/\${PYTHON_INSTALLER}" \
                  "\${DR_VALIDATION_PYTHON_WINDOWS_URL:-https://www.python.org/ftp/python/3.12.7/python-3.12.7-amd64.exe}" || true
              fi
              if [[ ! -s "/tmp/windows-staging/\${ODBC_INSTALLER}" ]]; then
                echo "Staging ODBC Driver 17 MSI for Windows targets..."
                curl -fL -o "/tmp/windows-staging/\${ODBC_INSTALLER}" \
                  "\${DR_VALIDATION_ODBC_DRIVER_MSI_URL:-https://go.microsoft.com/fwlink/?linkid=2361646}" || true
              fi
              if [[ ! -s "/tmp/windows-staging/\${HAMMER_ZIP}" ]]; then
                echo "Staging HammerDB \${HAMMER_VERSION} Windows archive for Windows targets..."
                curl -fL -o "/tmp/windows-staging/\${HAMMER_ZIP}" \
                  "https://github.com/TPC-Council/HammerDB/releases/download/v\${HAMMER_VERSION}/\${HAMMER_ZIP}" || true
              fi
            fi
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
            while IFS=\$'\t' read -r name host port platform ssh_user; do
              [[ -z "\$name" ]] && continue
              port="\${port:-22}"
              wait_for_ssh_tcp "\$name" "\$host" "\$port" || exit 1
            done < /tmp/hosts.tsv
            install_linux_vm() {
              local host="\$1" port="\$2" ssh_user="\$3"
              local scp_opts="-P \$port -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"
              local ssh_opts="-p \$port -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"
              local remote="mkdir -p /tmp/ramendr-dr-validation-install && tar -xzf /tmp/payload.tgz -C /tmp/ramendr-dr-validation-install && REPO_ROOT=/tmp/ramendr-dr-validation-install bash /tmp/ramendr-dr-validation-install/hammerdb/install-on-vm.sh"
              if [[ -f /tmp/ssh-privatekey ]]; then
                scp -i /tmp/ssh-privatekey \$scp_opts /payload/payload.tgz "\${ssh_user}@\${host}:/tmp/payload.tgz" && \
                ssh -i /tmp/ssh-privatekey -n \$ssh_opts "\${ssh_user}@\${host}" "\$remote" && \
                return 0
              fi
              if [[ -n "\$LINUX_PASS" ]]; then
                sshpass -p "\$LINUX_PASS" scp \$scp_opts /payload/payload.tgz "\${ssh_user}@\${host}:/tmp/payload.tgz" && \
                sshpass -p "\$LINUX_PASS" ssh -n \$ssh_opts \
                  -o PreferredAuthentications=password -o PubkeyAuthentication=no \
                  "\${ssh_user}@\${host}" "\$remote"
                return \$?
              fi
              return 1
            }
            install_windows_vm() {
              local name="\$1" host="\$2" port="\$3" ssh_user="\$4"
              local scp_opts="-P \$port -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"
              local ssh_opts="-p \$port -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"
              local prep='if not exist C:\\Temp mkdir C:\\Temp'
              local remote='cmd.exe /c C:\\Temp\\install-remote-windows.cmd'
              local hammer_version="\${HAMMERDB_VERSION:-5.0}"
              local hammer_zip="HammerDB-\${hammer_version}-Prod-Win.tar.gz"
              local sql_installer="SQL2022-SSEI-Expr.exe"
              local python_installer="python-amd64.exe"
              local odbc_installer="msodbcsql17.exe"
              local mssql_env_file="/tmp/mssql-install-\${name}.env"
              if [[ -z "\$WINDOWS_PASS" ]]; then
                echo "FAILED \${name}: missing windows-password"
                return 1
              fi
              if [[ -z "\$MSSQL_SA" || -z "\$MSSQL_USER" || -z "\$MSSQL_PASSWORD" ]]; then
                echo "FAILED \${name}: missing MSSQL credentials in install secret"
                return 1
              fi
              printf 'DR_VALIDATION_MSSQL_SA_PASSWORD=%s\nDR_VALIDATION_MSSQL_USER=%s\nDR_VALIDATION_MSSQL_PASSWORD=%s\n' \
                "\$MSSQL_SA" "\$MSSQL_USER" "\$MSSQL_PASSWORD" > "\$mssql_env_file"
              sshpass -p "\$WINDOWS_PASS" ssh -n \$ssh_opts \
                -o PreferredAuthentications=password -o PubkeyAuthentication=no \
                "\${ssh_user}@\${host}" "\$prep" && \
              sshpass -p "\$WINDOWS_PASS" scp \$scp_opts /payload/payload.tgz /payload/install-remote-windows.cmd \
                "\${ssh_user}@\${host}:C:/Temp/" && \
              sshpass -p "\$WINDOWS_PASS" scp \$scp_opts "\$mssql_env_file" \
                "\${ssh_user}@\${host}:C:/Temp/mssql-install.env" && \
              { [[ ! -s "/tmp/windows-staging/\${sql_installer}" ]] || \
                sshpass -p "\$WINDOWS_PASS" scp \$scp_opts \
                  "/tmp/windows-staging/\${sql_installer}" "\${ssh_user}@\${host}:C:/Temp/\${sql_installer}"; } && \
              { [[ ! -s "/tmp/windows-staging/\${python_installer}" ]] || \
                sshpass -p "\$WINDOWS_PASS" scp \$scp_opts \
                  "/tmp/windows-staging/\${python_installer}" "\${ssh_user}@\${host}:C:/Temp/\${python_installer}"; } && \
              { [[ ! -s "/tmp/windows-staging/\${odbc_installer}" ]] || \
                sshpass -p "\$WINDOWS_PASS" scp \$scp_opts \
                  "/tmp/windows-staging/\${odbc_installer}" "\${ssh_user}@\${host}:C:/Temp/\${odbc_installer}"; } && \
              { [[ ! -s "/tmp/windows-staging/\${hammer_zip}" ]] || \
                sshpass -p "\$WINDOWS_PASS" scp \$scp_opts \
                  "/tmp/windows-staging/\${hammer_zip}" "\${ssh_user}@\${host}:C:/Temp/\${hammer_zip}"; } && \
              sshpass -p "\$WINDOWS_PASS" ssh -n \$ssh_opts \
                -o PreferredAuthentications=password -o PubkeyAuthentication=no \
                "\${ssh_user}@\${host}" "\$remote" || return 1
              local poll_tries=0 poll_max=240 poll_sleep=60
              while [[ \$poll_tries -lt \$poll_max ]]; do
                if sshpass -p "\$WINDOWS_PASS" ssh -n \$ssh_opts \
                  -o PreferredAuthentications=password -o PubkeyAuthentication=no \
                  "\${ssh_user}@\${host}" "if exist C:\\ProgramData\\ramendr-dr-validation\\install.done (type C:\\ProgramData\\ramendr-dr-validation\\install.log 2>nul & exit 0) else if exist C:\\ProgramData\\ramendr-dr-validation\\install.failed (type C:\\ProgramData\\ramendr-dr-validation\\install.log 2>nul & exit 1) else exit 2" 2>/dev/null; then
                  return 0
                fi
                local poll_rc=\$?
                if [[ \$poll_rc -eq 1 ]]; then
                  return 1
                fi
                echo "  Waiting for detached Windows HammerDB install on \${name} (attempt \$((poll_tries + 1))/\$poll_max)..."
                sleep "\$poll_sleep"
                poll_tries=\$((poll_tries + 1))
              done
              echo "FAILED \${name}: timed out waiting for detached Windows HammerDB install"
              return 1
            }
            INSTALL_LOG_DIR=/tmp/install-logs
            mkdir -p "\$INSTALL_LOG_DIR"
            INSTALL_ORDER=()
            INSTALL_PIDS=()
            run_vm_install() {
              local name="\$1" host="\$2" port="\$3" platform="\$4" ssh_user="\$5"
              local log_file="\${INSTALL_LOG_DIR}/\${name}.log"
              local rc_file="\${INSTALL_LOG_DIR}/\${name}.rc"
              local rc=0
              {
                echo "=== \${name} @ \${host}:\${port} (\${platform}) ==="
                if [[ "\$platform" == windows ]]; then
                  install_windows_vm "\$name" "\$host" "\$port" "\$ssh_user" || rc=1
                else
                  install_linux_vm "\$host" "\$port" "\$ssh_user" || rc=1
                fi
                if [[ \$rc -eq 0 ]]; then
                  echo "INSTALL OK \${name}"
                else
                  echo "INSTALL FAILED \${name}"
                fi
              } > "\$log_file" 2>&1
              echo "\$rc" > "\$rc_file"
            }
            while IFS=\$'\t' read -r name host port platform ssh_user; do
              [[ -z "\$name" ]] && continue
              port="\${port:-22}"
              INSTALL_ORDER+=("\$name")
              run_vm_install "\$name" "\$host" "\$port" "\$platform" "\$ssh_user" &
              INSTALL_PIDS+=("\$!")
            done < /tmp/hosts.tsv
            echo "Installing HammerDB on \${#INSTALL_PIDS[@]} VM(s) in parallel..."
            for pid in "\${INSTALL_PIDS[@]}"; do
              wait "\$pid" || true
            done
            install_fail=0
            for name in "\${INSTALL_ORDER[@]}"; do
              echo ""
              echo "========== \${name} =========="
              if [[ -f "\${INSTALL_LOG_DIR}/\${name}.log" ]]; then
                cat "\${INSTALL_LOG_DIR}/\${name}.log"
              else
                echo "WARN: missing install log for \${name}"
                install_fail=1
                continue
              fi
              rc="\$(tr -d '[:space:]' < "\${INSTALL_LOG_DIR}/\${name}.rc" 2>/dev/null || echo 1)"
              if [[ "\$rc" != "0" ]]; then
                echo "FAILED \${name} (exit \${rc})"
                install_fail=1
              fi
            done
            if [[ "\$install_fail" -ne 0 ]]; then
              echo "One or more HammerDB installs failed."
              exit 1
            fi
            refresh_linux_audit() {
              local host="\$1" port="\$2" ssh_user="\$3"
              local ssh_opts="-p \$port -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"
              local cmd="sudo systemctl restart ramendr-dr-db-audit.service"
              if [[ -f /tmp/ssh-privatekey ]]; then
                ssh -i /tmp/ssh-privatekey -n \$ssh_opts "\${ssh_user}@\${host}" "\$cmd"
                return \$?
              fi
              if [[ -n "\$LINUX_PASS" ]]; then
                sshpass -p "\$LINUX_PASS" ssh -n \$ssh_opts \
                  -o PreferredAuthentications=password -o PubkeyAuthentication=no \
                  "\${ssh_user}@\${host}" "\$cmd"
                return \$?
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
                "\${ssh_user}@\${host}" "\$cmd"
            }
            echo "Refreshing audit writers on all target VMs..."
            while IFS=\$'\t' read -r name host port platform ssh_user; do
              [[ -z "\$name" ]] && continue
              port="\${port:-22}"
              if [[ "\$platform" == windows ]]; then
                refresh_windows_audit "\$host" "\$port" "\$ssh_user" || echo "WARN: could not refresh audit on \$name"
              else
                refresh_linux_audit "\$host" "\$port" "\$ssh_user" || echo "WARN: could not refresh audit on \$name"
              fi
            done < /tmp/hosts.tsv
            echo "Waiting 45s for audit writers to append fresh rows..."
            sleep 45
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
          - key: linux-password
            path: linux-password
            optional: true
          - key: windows-password
            path: windows-password
            optional: true
          - key: mssql-sa-password
            path: mssql-sa-password
            optional: true
          - key: mssql-user
            path: mssql-user
            optional: true
          - key: mssql-password
            path: mssql-password
            optional: true
          - key: ssh-privatekey
            path: ssh-privatekey
            optional: true
EOF

for _ in $(seq 1 960); do
  if KUBECONFIG="$SPOKE_KC" oc get job ramendr-dr-hammerdb-install -n "$VM_NAMESPACE" -o jsonpath='{.status.succeeded}' 2>/dev/null | grep -q 1; then
    logs="$(KUBECONFIG="$SPOKE_KC" oc logs -n "$VM_NAMESPACE" job/ramendr-dr-hammerdb-install 2>/dev/null || true)"
    echo "$logs" | tail -n 200
    cleanup_hammerdb_install_secret
    ok_count="$(echo "$logs" | grep -c "HammerDB install OK" || true)"
    if [[ "${ok_count:-0}" -ge "$TARGET_COUNT" ]]; then
      log "HammerDB workload is running on ${TARGET_COUNT} edge VM(s)."
      exit 0
    fi
    err "HammerDB install job finished with ${ok_count:-0}/${TARGET_COUNT} success marker(s)."
    exit 1
  fi
  if KUBECONFIG="$SPOKE_KC" oc get job ramendr-dr-hammerdb-install -n "$VM_NAMESPACE" -o jsonpath='{.status.failed}' 2>/dev/null | grep -q 1; then
    KUBECONFIG="$SPOKE_KC" oc logs -n "$VM_NAMESPACE" job/ramendr-dr-hammerdb-install --tail=120
    cleanup_hammerdb_install_secret
    exit 1
  fi
  sleep 15
done
cleanup_hammerdb_install_secret
err "Timed out waiting for ramendr-dr-hammerdb-install job."
exit 1
