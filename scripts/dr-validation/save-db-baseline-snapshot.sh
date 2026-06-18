#!/usr/bin/env bash
set -euo pipefail

# Capture a HammerDB DB snapshot and point auto/latest at it (pre-DR baseline).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

ensure_hub_kubeconfig

stamp="$(date +%Y%m%d-%H%M%S)"
dest="${DR_VALIDATION_DB_SNAPSHOT_ROOT}/${stamp}"
log "Saving DB baseline snapshot -> ${dest}"
if ! "$SCRIPT_DIR/collect-db-snapshot-incluster.sh" "$dest"; then
  err "Could not save DB baseline snapshot."
  exit 1
fi
update_latest_db_snapshot_link "$dest"
log "Baseline latest -> ${DR_VALIDATION_DB_SNAPSHOT_ROOT}/latest"
