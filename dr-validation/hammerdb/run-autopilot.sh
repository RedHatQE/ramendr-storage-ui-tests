#!/usr/bin/env bash
# Build HammerDB TPC-C schema once, then run continuous timed OLTP load.
set -euo pipefail

HAMMERDB_HOME="${HAMMERDB_HOME:-/opt/hammerdb/current}"
ENV_FILE="${DR_VALIDATION_DB_ENV_FILE:-/etc/ramendr-dr-validation/db.env}"
WAREHOUSES="${DR_VALIDATION_HAMMERDB_WAREHOUSES:-1}"
VUS="${DR_VALIDATION_HAMMERDB_VUS:-2}"
BUILD_VUS="${VUS}"
if [[ "${WAREHOUSES}" -lt "${BUILD_VUS}" ]]; then
  BUILD_VUS="${WAREHOUSES}"
fi
PG_SUPERUSER="${DR_VALIDATION_PG_SUPERUSER:-postgres}"
PG_SUPERUSER_PASSWORD="${DR_VALIDATION_PG_SUPERUSER_PASSWORD:-postgres}"

if [[ -f "$ENV_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$ENV_FILE"
fi

PG_HOST="${DR_VALIDATION_PG_HOST:-127.0.0.1}"
PG_PORT="${DR_VALIDATION_PG_PORT:-5432}"
PG_DATABASE="${DR_VALIDATION_PG_DATABASE:-tpcc}"
PG_USER="${DR_VALIDATION_PG_USER:-hammerdb}"
PG_PASSWORD="${DR_VALIDATION_PG_PASSWORD:-hammerdb}"

cd "$HAMMERDB_HOME"

STATE_DIR="/var/lib/ramendr-dr-validation/hammerdb"
mkdir -p "$STATE_DIR"
export TMPDIR="${STATE_DIR}/tmp"
mkdir -p "$STATE_DIR/tmp"
chmod 700 "$STATE_DIR/tmp"
export LD_LIBRARY_PATH="/opt/pgdistro/percona-postgresql16/lib:${LD_LIBRARY_PATH:-}"

write_build_script() {
  cat >"${STATE_DIR}/buildschema.tcl" <<EOF
dbset db pg
dbset bm TPC-C
diset connection pg_host ${PG_HOST}
diset connection pg_port ${PG_PORT}
diset connection pg_sslmode prefer
diset tpcc pg_count_ware ${WAREHOUSES}
diset tpcc pg_num_vu ${BUILD_VUS}
diset tpcc pg_superuser ${PG_SUPERUSER}
diset tpcc pg_superuserpass ${PG_SUPERUSER_PASSWORD}
diset tpcc pg_defaultdbase postgres
diset tpcc pg_user ${PG_USER}
diset tpcc pg_pass ${PG_PASSWORD}
diset tpcc pg_dbase ${PG_DATABASE}
diset tpcc pg_tspace pg_default
diset tpcc pg_storedprocs true
diset tpcc pg_partition false
puts "SCHEMA BUILD START"
buildschema
puts "SCHEMA BUILD DONE"
EOF
}

write_run_script() {
  cat >"${STATE_DIR}/runload.tcl" <<'EOF'
proc wait_to_complete {} {
  if {![vucomplete]} {
    after 10000 wait_to_complete
  }
}
EOF
  cat >>"${STATE_DIR}/runload.tcl" <<EOF
dbset db pg
dbset bm TPC-C
diset connection pg_host ${PG_HOST}
diset connection pg_port ${PG_PORT}
diset connection pg_sslmode prefer
diset tpcc pg_superuser ${PG_SUPERUSER}
diset tpcc pg_superuserpass ${PG_SUPERUSER_PASSWORD}
diset tpcc pg_defaultdbase postgres
diset tpcc pg_user ${PG_USER}
diset tpcc pg_pass ${PG_PASSWORD}
diset tpcc pg_dbase ${PG_DATABASE}
diset tpcc pg_driver timed
diset tpcc pg_total_iterations 10000000
diset tpcc pg_rampup 0
diset tpcc pg_duration 86400
diset tpcc pg_vacuum true
diset tpcc pg_timeprofile true
diset tpcc pg_allwarehouse true
while {1} {
  loadscript
  vuset vu ${VUS}
  vucreate
  tcstart
  vurun
  wait_to_complete
  vudestroy
  tcstop
}
EOF
}

if [[ ! -f "${STATE_DIR}/schema-built" ]]; then
  echo "Building HammerDB TPC-C schema (${WAREHOUSES} warehouse(s))..."
  write_build_script
  if ! ./hammerdbcli tcl auto "${STATE_DIR}/buildschema.tcl"; then
    echo "ERROR: HammerDB buildschema failed"
    exit 1
  fi
  touch "${STATE_DIR}/schema-built"
fi

echo "Starting HammerDB TPC-C workload..."
write_run_script
exec ./hammerdbcli tcl auto "${STATE_DIR}/runload.tcl"
