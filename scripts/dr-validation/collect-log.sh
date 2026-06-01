#!/usr/bin/env bash
set -euo pipefail

# Copy timestamp logs from edge VMs to a local directory.
#
# Usage:
#   ./scripts/dr-validation/collect-log.sh [output-dir]

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

OUT_DIR="${1:-$REPO_ROOT/.work/dr-validation-logs/$(date +%Y%m%d-%H%M%S)}"
collect_logs_to_dir "$OUT_DIR"
