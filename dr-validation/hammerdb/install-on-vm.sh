#!/usr/bin/env bash
# Install PostgreSQL + HammerDB TPC-C workload on a DR-protected edge VM.
# Intended to run on the VM via SSH from install-hammerdb-incluster.sh.
set -euo pipefail

REPO_ROOT="${REPO_ROOT:-/tmp/ramendr-dr-validation-install}"
DATA_ROOT="${DR_VALIDATION_DATA_ROOT:-/var/lib/ramendr-dr-validation}"
PGDATA="${DR_VALIDATION_PGDATA:-${DATA_ROOT}/postgres/data}"
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

echo "=== RamenDR HammerDB install (PostgreSQL) ==="

sudo mkdir -p "$DATA_ROOT/postgres" "$ENV_DIR" "${DATA_ROOT}/hammerdb" "${DATA_ROOT}/hammerdb/tmp"
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
}

stop_existing_postgresql() {
  sudo systemctl stop ramendr-postgresql.service 2>/dev/null || true
  sudo systemctl reset-failed ramendr-postgresql.service 2>/dev/null || true
  if [[ -n "$PG_CTL" && -d "$PGDATA" ]]; then
    sudo -u postgres "$PG_CTL" -D "$PGDATA" stop -m fast 2>/dev/null || true
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
EOF
  sudo chmod 0640 "$PG_ENV_FILE"

  sudo tee /etc/systemd/system/ramendr-postgresql.service >/dev/null <<EOF
[Unit]
Description=RamenDR PostgreSQL for HammerDB DR validation
After=network.target

[Service]
Type=simple
User=postgres
Group=postgres
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
  sudo systemctl start ramendr-postgresql.service
}

install_postgresql

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
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = '${PG_USER}') THEN
    CREATE ROLE ${PG_USER} LOGIN PASSWORD '${PG_PASSWORD}';
  END IF;
END
\$\$;
SQL

if ! sudo -u postgres "$PSQL" -Atqc "SELECT 1 FROM pg_database WHERE datname='${PG_DATABASE}'" | grep -q 1; then
  sudo -u postgres "${PG_BIN_DIR}/createdb" -O "${PG_USER}" "${PG_DATABASE}"
fi

sudo -u postgres "$PSQL" -v ON_ERROR_STOP=1 -c \
  "GRANT ALL PRIVILEGES ON DATABASE ${PG_DATABASE} TO ${PG_USER};"

sudo install -m 0750 -d "$ENV_DIR"
sudo tee "$ENV_FILE" >/dev/null <<ENV
DR_VALIDATION_PG_HOST=127.0.0.1
DR_VALIDATION_PG_PORT=5432
DR_VALIDATION_PG_DATABASE=${PG_DATABASE}
DR_VALIDATION_PG_USER=${PG_USER}
DR_VALIDATION_PG_PASSWORD=${PG_PASSWORD}
DR_VALIDATION_PG_SCHEMA=public
DR_VALIDATION_PG_AUDIT_TABLE=dr_validation_audit
DR_VALIDATION_HAMMERDB_WAREHOUSES=${WAREHOUSES}
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
sudo install -m 0644 "${REPO_ROOT}/ramendr_dr_validation/db_snapshot.py" \
  /usr/local/lib/ramendr_dr_validation/db_snapshot.py
sudo chmod 0755 /usr/local/bin/ramendr-dr-db-audit /usr/local/bin/ramendr-dr-db-snapshot
sudo install -m 0644 "${REPO_ROOT}/ramendr_dr_validation/backends/postgres.py" \
  /usr/local/lib/ramendr_dr_validation/backends/postgres.py
sudo install -m 0644 "${REPO_ROOT}/ramendr_dr_validation/backends/__init__.py" \
  /usr/local/lib/ramendr_dr_validation/backends/__init__.py
sudo touch /usr/local/lib/ramendr_dr_validation/__init__.py

sudo install -m 0644 "${REPO_ROOT}/systemd/ramendr-dr-db-audit.service" /etc/systemd/system/
sudo install -m 0644 "${REPO_ROOT}/systemd/ramendr-dr-hammerdb.service" /etc/systemd/system/

tpcc_tables="$(sudo -u postgres "$PSQL" -d "$PG_DATABASE" -Atqc \
  "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='public' AND table_name IN ('customer','orders','warehouse');" \
  2>/dev/null || echo 0)"
if [[ "${tpcc_tables:-0}" -lt 3 ]]; then
  sudo rm -f "${DATA_ROOT}/hammerdb/schema-built"
  sudo systemctl stop ramendr-dr-hammerdb.service ramendr-dr-db-audit.service 2>/dev/null || true
  sudo -u postgres "$PSQL" -v ON_ERROR_STOP=1 <<SQL
SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname='${PG_DATABASE}' AND pid <> pg_backend_pid();
DROP DATABASE IF EXISTS ${PG_DATABASE};
CREATE DATABASE ${PG_DATABASE} OWNER ${PG_USER};
GRANT ALL PRIVILEGES ON DATABASE ${PG_DATABASE} TO ${PG_USER};
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

sudo -u postgres "$PSQL" -d "$PG_DATABASE" -v ON_ERROR_STOP=1 \
  -f "${REPO_ROOT}/hammerdb/sql/init-audit.sql"
sudo -u postgres "$PSQL" -d "$PG_DATABASE" -c \
  "GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO ${PG_USER};"
sudo -u postgres "$PSQL" -d "$PG_DATABASE" -c \
  "GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO ${PG_USER};"

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
sudo /usr/local/bin/ramendr-dr-db-snapshot | head -n 20
