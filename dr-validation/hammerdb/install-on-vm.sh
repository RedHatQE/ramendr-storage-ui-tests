#!/usr/bin/env bash
# Install PostgreSQL + HammerDB TPC-C workload on a DR-protected edge VM.
# Intended to run on the VM via SSH from install-hammerdb-incluster.sh.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/ensure-data-disk-linux.sh
source "${SCRIPT_DIR}/lib/ensure-data-disk-linux.sh"

REPO_ROOT="${REPO_ROOT:-/tmp/ramendr-dr-validation-install}"
DATA_ROOT="${DR_VALIDATION_DATA_ROOT:-/var/lib/ramendr-dr-validation}"
DATA_DISK_MOUNT="${DR_VALIDATION_DATA_DISK_MOUNT:-/mnt/ramendr-data}"
OS_TABLESPACE_NAME="${DR_VALIDATION_OS_TABLESPACE:-ramendr_os}"
OS_TABLESPACE_DIR="${DR_VALIDATION_OS_TABLESPACE_DIR:-${DATA_ROOT}/postgres/os-tablespace}"
PGDATA="${DR_VALIDATION_PGDATA:-${DATA_DISK_MOUNT}/postgres/data}"
ENV_DIR="/etc/ramendr-dr-validation"
ENV_FILE="${ENV_DIR}/db.env"
PG_ENV_FILE="${ENV_DIR}/postgresql.env"
HAMMERDB_VERSION="${HAMMERDB_VERSION:-5.0}"
HAMMERDB_INSTALL_ROOT="${HAMMERDB_INSTALL_ROOT:-/opt/hammerdb}"
HAMMERDB_HOME="${HAMMERDB_INSTALL_ROOT}/current"
WAREHOUSES="${DR_VALIDATION_HAMMERDB_WAREHOUSES:-1}"
PG_DATABASE="${DR_VALIDATION_PG_DATABASE:-tpcc}"
PG_USER="${DR_VALIDATION_PG_USER:-hammerdb}"
PG_PASSWORD="${DR_VALIDATION_PG_PASSWORD:-hammerdb}"
PERCONA_PG_VERSION="${PERCONA_PG_VERSION:-16.8}"
PERCONA_PG_ROOT="${PERCONA_PG_ROOT:-/opt/pgdistro}"
PG_HOME="${PERCONA_PG_ROOT}/percona-postgresql16"

PG_BIN_DIR=""
PG_CTL=""
PSQL=""
PG_LIB_DIR=""

pg_quote_ident() {
  local s="${1//\"/\"\"}"
  printf '"%s"' "$s"
}

pg_quote_literal() {
  local s="${1//\'/\'\'}"
  printf "'%s'" "$s"
}

echo "=== RamenDR HammerDB install (PostgreSQL) ==="

ensure_dr_validation_data_disk

sudo install -m 0755 -d "$DATA_ROOT/postgres" "$ENV_DIR" "${DATA_ROOT}/hammerdb" "${DATA_ROOT}/hammerdb/tmp"
sudo install -m 0755 -d "${DATA_DISK_MOUNT}/postgres"
sudo chown -R cloud-user:cloud-user "${DATA_ROOT}/hammerdb" || true

dnf_rhel_repos_enabled() {
  sudo dnf repolist enabled 2>/dev/null | grep -qE 'rhel-|codeready|baseos|appstream'
}

is_rhel_registered() {
  sudo subscription-manager status 2>/dev/null | grep -qE 'Overall Status: (Current|Access)'
}

ensure_python_psycopg2() {
  local audit_python="python3"
  if [[ -x "${PERCONA_PG_ROOT}/percona-python3/bin/python3" ]]; then
    audit_python="${PERCONA_PG_ROOT}/percona-python3/bin/python3"
  fi

  if "$audit_python" -c "import psycopg2" 2>/dev/null; then
    sudo tee /etc/ramendr-dr-validation/python.env >/dev/null <<EOF
DR_VALIDATION_PYTHON=${audit_python}
EOF
    return 0
  fi

  if ! "$audit_python" -m pip --version >/dev/null 2>&1; then
    local py_minor
    py_minor="$("$audit_python" -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')"
    curl -fsSL "https://bootstrap.pypa.io/pip/${py_minor}/get-pip.py" -o /tmp/get-pip.py
    sudo "$audit_python" /tmp/get-pip.py
  fi
  sudo "$audit_python" -m pip install psycopg2-binary
  "$audit_python" -c "import psycopg2"
  sudo tee /etc/ramendr-dr-validation/python.env >/dev/null <<EOF
DR_VALIDATION_PYTHON=${audit_python}
EOF
}

install_postgresql_from_packages() {
  echo "Installing PostgreSQL from system packages..."
  if ! sudo dnf install -y postgresql-server postgresql python3-psycopg2 curl tar gzip; then
    return 1
  fi

  if command -v /usr/pgsql-16/bin/pg_ctl >/dev/null 2>&1; then
    PG_BIN_DIR="/usr/pgsql-16/bin"
  else
    PG_BIN_DIR="$(dirname "$(command -v pg_ctl)")"
  fi
  PG_CTL="${PG_BIN_DIR}/pg_ctl"
  PSQL="${PG_BIN_DIR}/psql"
  if [[ -d "${PG_BIN_DIR}/../lib" ]]; then
    PG_LIB_DIR="$(cd "${PG_BIN_DIR}/../lib" && pwd)"
  else
    PG_LIB_DIR=""
  fi
}

install_postgresql_from_percona() {
  echo "Installing PostgreSQL from Percona binary tarball (unregistered RHEL)..."
  local tarball_url="https://downloads.percona.com/downloads/postgresql-distribution-16/${PERCONA_PG_VERSION}/binary/tarball/percona-postgresql-${PERCONA_PG_VERSION}-ssl3-linux-x86_64.tar.gz"

  if [[ ! -x "${PG_HOME}/bin/postgres" ]]; then
    tmpdir="$(mktemp -d)"
    curl -fsSL "$tarball_url" -o "${tmpdir}/percona-postgresql.tar.gz"
    sudo mkdir -p "$PERCONA_PG_ROOT"
    sudo tar -xzf "${tmpdir}/percona-postgresql.tar.gz" -C "$PERCONA_PG_ROOT"
    rm -rf "$tmpdir"
  fi

  PG_BIN_DIR="${PG_HOME}/bin"
  PG_CTL="${PG_BIN_DIR}/pg_ctl"
  PSQL="${PG_BIN_DIR}/psql"
  PG_LIB_DIR="${PG_HOME}/lib"
}

postgres_lib_path_env() {
  if [[ -n "$PG_LIB_DIR" && -d "$PG_LIB_DIR" ]]; then
    printf 'LD_LIBRARY_PATH=%s' "$PG_LIB_DIR"
  fi
}

wait_for_postgresql_ready() {
  local pg_isready="${PG_BIN_DIR}/pg_isready"
  local lib_env
  lib_env="$(postgres_lib_path_env)"
  local tries=0
  local max="${DR_VALIDATION_PG_READY_WAIT_ATTEMPTS:-60}"

  echo "Waiting for PostgreSQL to accept connections (up to $((max * 2))s)..."
  while [[ $tries -lt $max ]]; do
    if [[ -x "$pg_isready" ]]; then
      if [[ -n "$lib_env" ]]; then
        sudo -u postgres env "$lib_env" "$pg_isready" -h localhost -p 5432 -q 2>/dev/null && return 0
      else
        sudo -u postgres "$pg_isready" -h localhost -p 5432 -q 2>/dev/null && return 0
      fi
    fi
    if [[ -n "$lib_env" ]]; then
      sudo -u postgres env "$lib_env" "$PSQL" -h localhost -p 5432 -d postgres -Atqc 'SELECT 1' \
        &>/dev/null && return 0
    else
      sudo -u postgres "$PSQL" -h localhost -p 5432 -d postgres -Atqc 'SELECT 1' \
        &>/dev/null && return 0
    fi
    tries=$((tries + 1))
    sleep 2
  done
  return 1
}

log_postgresql_start_failure() {
  echo "ERROR: PostgreSQL did not become ready after starting ramendr-postgresql.service"
  sudo systemctl status ramendr-postgresql.service --no-pager -l 2>/dev/null || true
  sudo journalctl -u ramendr-postgresql.service --no-pager -n 40 2>/dev/null || true
}

stop_existing_postgresql() {
  sudo systemctl stop ramendr-postgresql.service 2>/dev/null || true
  sudo systemctl reset-failed ramendr-postgresql.service 2>/dev/null || true
  if [[ -n "$PG_CTL" && -d "$PGDATA" ]]; then
    local lib_env
    lib_env="$(postgres_lib_path_env)"
    if [[ -n "$lib_env" ]]; then
      sudo -u postgres env "$lib_env" "$PG_CTL" -D "$PGDATA" stop -m fast 2>/dev/null || true
    else
      sudo -u postgres "$PG_CTL" -D "$PGDATA" stop -m fast 2>/dev/null || true
    fi
  fi
  for _ in $(seq 1 20); do
    if ! sudo ss -ltn 2>/dev/null | grep -q ':5432 '; then
      return 0
    fi
    sleep 1
  done
  sudo pkill -u postgres -x postgres 2>/dev/null || true
  sleep 2
}

install_postgresql() {
  local installed=0
  if is_rhel_registered && dnf_rhel_repos_enabled && install_postgresql_from_packages; then
    installed=1
  elif install_postgresql_from_percona; then
    installed=1
  fi
  if [[ "$installed" -ne 1 ]]; then
    echo "ERROR: could not install PostgreSQL from packages or Percona tarball"
    exit 1
  fi

  if [[ -z "$PG_BIN_DIR" || ! -x "${PG_BIN_DIR}/initdb" ]]; then
    echo "ERROR: PostgreSQL binaries not found under ${PG_BIN_DIR:-<unset>}"
    exit 1
  fi

  sudo useradd -r -s /sbin/nologin postgres 2>/dev/null || true
  stop_existing_postgresql
  sudo mkdir -p "$(dirname "$PGDATA")"
  sudo chown postgres:postgres "$(dirname "$PGDATA")"

  if ! sudo test -f "$PGDATA/PG_VERSION"; then
    echo "Initializing PostgreSQL in ${PGDATA}..."
    sudo rm -rf "$PGDATA"
    sudo mkdir -p "$PGDATA"
    sudo chown postgres:postgres "$PGDATA"
    sudo -u postgres "${PG_BIN_DIR}/initdb" -D "$PGDATA"
    sudo -u postgres sed -i "s/#listen_addresses = 'localhost'/listen_addresses = 'localhost'/" \
      "$PGDATA/postgresql.conf" || true
  else
    sudo chown -R postgres:postgres "$DATA_ROOT/postgres"
    sudo chmod 700 "$PGDATA"
  fi

  sudo touch /var/log/ramendr-postgresql.log
  sudo chown postgres:postgres /var/log/ramendr-postgresql.log

  sudo tee "$PG_ENV_FILE" >/dev/null <<EOF
PGDATA=${PGDATA}
PG_CTL=${PG_CTL}
PG_LIB_DIR=${PG_LIB_DIR}
DR_VALIDATION_PG_LIB_DIR=${PG_LIB_DIR}
EOF
  sudo chmod 0640 "$PG_ENV_FILE"

  local pg_service_env=""
  if [[ -n "$PG_LIB_DIR" && -d "$PG_LIB_DIR" ]]; then
    pg_service_env="Environment=LD_LIBRARY_PATH=${PG_LIB_DIR}"
  fi

  sudo tee /etc/systemd/system/ramendr-postgresql.service >/dev/null <<EOF
[Unit]
Description=RamenDR PostgreSQL for HammerDB DR validation
After=network.target

[Service]
Type=simple
User=postgres
Group=postgres
${pg_service_env}
ExecStart=${PG_BIN_DIR}/postgres -D ${PGDATA}
ExecStop=${PG_CTL} -D ${PGDATA} stop -m fast
Restart=on-failure
RestartSec=10
TimeoutStartSec=120

[Install]
WantedBy=multi-user.target
EOF

  sudo systemctl daemon-reload
  sudo systemctl enable ramendr-postgresql.service
  stop_existing_postgresql
  if ! sudo systemctl start ramendr-postgresql.service; then
    log_postgresql_start_failure
    exit 1
  fi
  if ! wait_for_postgresql_ready; then
    log_postgresql_start_failure
    exit 1
  fi
}

install_postgresql

sudo install -m 0700 -d -o postgres -g postgres "$OS_TABLESPACE_DIR"

ensure_python_psycopg2

sudo tee /usr/local/bin/ramendr-dr-db-audit >/dev/null <<'WRAPPER'
#!/usr/bin/env bash
set -a
source /etc/ramendr-dr-validation/python.env 2>/dev/null || true
set +a
export PYTHONPATH=/usr/local/lib
exec "${DR_VALIDATION_PYTHON:-python3}" /usr/local/lib/ramendr_dr_validation/db_audit.py "$@"
WRAPPER
sudo tee /usr/local/bin/ramendr-dr-db-snapshot >/dev/null <<'WRAPPER'
#!/usr/bin/env bash
set -a
source /etc/ramendr-dr-validation/python.env 2>/dev/null || true
set +a
export PYTHONPATH=/usr/local/lib
exec "${DR_VALIDATION_PYTHON:-python3}" /usr/local/lib/ramendr_dr_validation/db_snapshot.py "$@"
WRAPPER

sudo -u postgres "$PSQL" -v ON_ERROR_STOP=1 <<SQL
DO \$\$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = $(pg_quote_literal "$PG_USER")) THEN
    EXECUTE format(
      'CREATE ROLE %I LOGIN PASSWORD %L',
      $(pg_quote_literal "$PG_USER"),
      $(pg_quote_literal "$PG_PASSWORD")
    );
  END IF;
END
\$\$;
SQL

if ! sudo -u postgres "$PSQL" -Atqc \
  "SELECT 1 FROM pg_database WHERE datname=$(pg_quote_literal "$PG_DATABASE")" | grep -q 1; then
  sudo -u postgres "${PG_BIN_DIR}/createdb" -O "${PG_USER}" "${PG_DATABASE}"
fi

sudo -u postgres "$PSQL" -v ON_ERROR_STOP=1 -c \
  "GRANT ALL PRIVILEGES ON DATABASE $(pg_quote_ident "$PG_DATABASE") TO $(pg_quote_ident "$PG_USER");"

if ! sudo -u postgres "$PSQL" -Atqc \
  "SELECT 1 FROM pg_tablespace WHERE spcname=$(pg_quote_literal "$OS_TABLESPACE_NAME")" | grep -q 1; then
  sudo -u postgres "$PSQL" -v ON_ERROR_STOP=1 -d postgres -c \
    "CREATE TABLESPACE $(pg_quote_ident "$OS_TABLESPACE_NAME") LOCATION $(pg_quote_literal "$OS_TABLESPACE_DIR");"
fi

sudo install -m 0755 -d "$ENV_DIR"
sudo tee "$ENV_FILE" >/dev/null <<ENV
DR_VALIDATION_PG_HOST=127.0.0.1
DR_VALIDATION_PG_PORT=5432
DR_VALIDATION_PG_DATABASE=${PG_DATABASE}
DR_VALIDATION_PG_USER=${PG_USER}
DR_VALIDATION_PG_PASSWORD="${PG_PASSWORD}"
DR_VALIDATION_PG_SCHEMA=public
DR_VALIDATION_PG_AUDIT_TABLE=dr_validation_audit
DR_VALIDATION_HAMMERDB_WAREHOUSES=${WAREHOUSES}
DR_VALIDATION_HAMMERDB_HOME=${HAMMERDB_HOME}
DR_VALIDATION_PG_LIB_DIR=${PG_HOME}/lib
DR_VALIDATION_DATA_DISK_MOUNT=${DATA_DISK_MOUNT}
DR_VALIDATION_PGDATA=${PGDATA}
DR_VALIDATION_OS_TABLESPACE=${OS_TABLESPACE_NAME}
ENV
sudo chown root:cloud-user "$ENV_FILE"
sudo chmod 0640 "$ENV_FILE"

if [[ ! -x "${HAMMERDB_HOME}/hammerdbcli" ]]; then
  tmpdir="$(mktemp -d)"
  tarball="HammerDB-${HAMMERDB_VERSION}-Prod-Lin-RHEL9.tar.gz"
  url="https://github.com/TPC-Council/HammerDB/releases/download/v${HAMMERDB_VERSION}/${tarball}"
  echo "Downloading HammerDB ${HAMMERDB_VERSION}..."
  curl -fsSL "$url" -o "${tmpdir}/${tarball}"
  sudo mkdir -p "$HAMMERDB_INSTALL_ROOT"
  sudo tar -xzf "${tmpdir}/${tarball}" -C "$HAMMERDB_INSTALL_ROOT"
  extracted="$(find "$HAMMERDB_INSTALL_ROOT" -maxdepth 1 -type d -name 'HammerDB-*' | head -1)"
  sudo ln -sfn "$extracted" "$HAMMERDB_HOME"
  rm -rf "$tmpdir"
fi

sudo install -m 0755 "${REPO_ROOT}/hammerdb/run-autopilot.sh" /usr/local/bin/ramendr-hammerdb-autopilot
sudo install -d -m 0755 /usr/local/lib/ramendr_dr_validation/backends
sudo install -m 0644 "${REPO_ROOT}/ramendr_dr_validation/db_audit.py" \
  /usr/local/lib/ramendr_dr_validation/db_audit.py
sudo install -m 0644 "${REPO_ROOT}/ramendr_dr_validation/db_snapshot_common.py" \
  /usr/local/lib/ramendr_dr_validation/db_snapshot_common.py
sudo install -m 0644 "${REPO_ROOT}/ramendr_dr_validation/db_snapshot.py" \
  /usr/local/lib/ramendr_dr_validation/db_snapshot.py
sudo install -m 0644 "${REPO_ROOT}/ramendr_dr_validation/tpcc_schema.py" \
  /usr/local/lib/ramendr_dr_validation/tpcc_schema.py
sudo chmod 0755 /usr/local/bin/ramendr-dr-db-audit /usr/local/bin/ramendr-dr-db-snapshot
sudo install -m 0644 "${REPO_ROOT}/ramendr_dr_validation/backends/postgres.py" \
  /usr/local/lib/ramendr_dr_validation/backends/postgres.py
sudo install -m 0644 "${REPO_ROOT}/ramendr_dr_validation/backends/__init__.py" \
  /usr/local/lib/ramendr_dr_validation/backends/__init__.py
sudo touch /usr/local/lib/ramendr_dr_validation/__init__.py

sudo install -m 0644 "${REPO_ROOT}/systemd/ramendr-dr-db-audit.service" /etc/systemd/system/
sudo tee /etc/systemd/system/ramendr-dr-hammerdb.service >/dev/null <<EOF
[Unit]
Description=RamenDR HammerDB TPC-C autopilot workload
After=ramendr-postgresql.service
Requires=ramendr-postgresql.service

[Service]
Type=simple
User=cloud-user
Group=cloud-user
Environment=TMPDIR=${DATA_ROOT}/hammerdb/tmp
EnvironmentFile=-${ENV_FILE}
ExecStart=/usr/local/bin/ramendr-hammerdb-autopilot
Restart=always
RestartSec=15

[Install]
WantedBy=multi-user.target
EOF

tpcc_tables="$(sudo -u postgres "$PSQL" -d "$PG_DATABASE" -Atqc \
  "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='public' AND table_name IN ('customer','orders','warehouse');" \
  2>/dev/null || echo 0)"
if [[ "${tpcc_tables:-0}" -lt 3 ]]; then
  sudo rm -f "${DATA_ROOT}/hammerdb/schema-built"
  sudo systemctl stop ramendr-dr-hammerdb.service ramendr-dr-db-audit.service 2>/dev/null || true
  sudo -u postgres "$PSQL" -v ON_ERROR_STOP=1 <<SQL
SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname=$(pg_quote_literal "$PG_DATABASE") AND pid <> pg_backend_pid();
DROP DATABASE IF EXISTS $(pg_quote_ident "$PG_DATABASE");
CREATE DATABASE $(pg_quote_ident "$PG_DATABASE") OWNER $(pg_quote_ident "$PG_USER");
GRANT ALL PRIVILEGES ON DATABASE $(pg_quote_ident "$PG_DATABASE") TO $(pg_quote_ident "$PG_USER");
SQL
fi

sudo systemctl daemon-reload
sudo systemctl enable ramendr-dr-hammerdb.service ramendr-dr-db-audit.service
sudo systemctl restart ramendr-dr-hammerdb.service

echo "Waiting for HammerDB TPC-C schema (up to 10 min)..."
schema_ready=0
for _ in $(seq 1 60); do
  tpcc_tables="$(sudo -u postgres "$PSQL" -d "$PG_DATABASE" -Atqc \
    "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='public' AND table_name IN ('customer','orders','warehouse');" \
    2>/dev/null || echo 0)"
  if [[ "${tpcc_tables:-0}" -ge 3 ]]; then
    schema_ready=1
    break
  fi
  sleep 10
done
if [[ "$schema_ready" -ne 1 ]]; then
  echo "ERROR: HammerDB TPC-C schema not ready (found ${tpcc_tables:-0}/3 core tables)"
  sudo journalctl -u ramendr-dr-hammerdb.service --no-pager -n 40 || true
  exit 1
fi

audit_sql="$(mktemp)"
sed "s/__DR_VALIDATION_OS_TABLESPACE__/${OS_TABLESPACE_NAME}/g" \
  "${REPO_ROOT}/hammerdb/sql/init-audit.sql" > "$audit_sql"
sudo -u postgres "$PSQL" -d "$PG_DATABASE" -v ON_ERROR_STOP=1 -f "$audit_sql"
rm -f "$audit_sql"
sudo -u postgres "$PSQL" -d "$PG_DATABASE" -c \
  "GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO $(pg_quote_ident "$PG_USER");"
sudo -u postgres "$PSQL" -d "$PG_DATABASE" -c \
  "GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO $(pg_quote_ident "$PG_USER");"

sudo systemctl restart ramendr-dr-db-audit.service

echo "Waiting for audit writer (up to 2 min)..."
audit_count=0
for _ in $(seq 1 24); do
  audit_count="$(sudo -u postgres "$PSQL" -d "$PG_DATABASE" -Atqc 'SELECT COUNT(*) FROM dr_validation_audit;' 2>/dev/null || echo 0)"
  if [[ "${audit_count:-0}" -ge 1 ]]; then
    break
  fi
  sleep 5
done

sudo systemctl is-active --quiet ramendr-postgresql.service
sudo systemctl is-active --quiet ramendr-dr-hammerdb.service
sudo systemctl is-active --quiet ramendr-dr-db-audit.service

if [[ "${audit_count:-0}" -lt 1 ]]; then
  echo "ERROR: dr_validation_audit has no rows after install"
  exit 1
fi

echo "HammerDB install OK: audit_rows=${audit_count} tpcc_core_tables=${tpcc_tables}"
set +o pipefail
sudo /usr/local/bin/ramendr-dr-db-snapshot | head -n 20
set -o pipefail
