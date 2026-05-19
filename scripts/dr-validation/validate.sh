#!/usr/bin/env bash
set -euo pipefail

# Validate collected timestamp log(s) for sequence continuity (post-failover check).
#
# Usage:
#   ./scripts/dr-validation/validate.sh <log-or-dir> [--compare before.log] [--interval 10.0]

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

require_cmd python3

TARGET="${1:-}"
shift || true
if [[ -z "$TARGET" ]]; then
  err "Usage: $0 <timestamps.log-or-directory> [--compare before.log] [--interval SECONDS]"
  exit 1
fi

export PYTHONPATH="${DR_VALIDATION_DIR}:${PYTHONPATH:-}"
INTERVAL="${DR_VALIDATION_INTERVAL}"

require_option_value() {
  local opt="$1" val="${2:-}"
  if [[ -z "$val" ]] || [[ "$val" == -* ]]; then
    err "Option ${opt} requires a value"
    exit 1
  fi
}

ARGS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --interval)
      require_option_value "$1" "${2:-}"
      INTERVAL="$2"
      shift 2
      ;;
    --compare)
      require_option_value "$1" "${2:-}"
      ARGS+=(--compare "$2")
      shift 2
      ;;
    *) ARGS+=("$1"); shift ;;
  esac
done

validate_one() {
  local file="$1"
  log "Validating $file"
  python3 -m ramendr_dr_validation.validator "$file" --interval "$INTERVAL" "${ARGS[@]}"
}

failures=0
if [[ -d "$TARGET" ]]; then
  shopt -s nullglob
  logs=()
  for f in "$TARGET"/*.timestamps.log; do
    [[ -f "$f" ]] && logs+=("$f")
  done
  for f in "$TARGET"/*.log; do
    [[ -f "$f" ]] || continue
    case "$f" in *.timestamps.log) continue ;; esac
    logs+=("$f")
  done
  if [[ ${#logs[@]} -eq 0 ]]; then
    err "No .log files in $TARGET"
    exit 1
  fi
  for f in "${logs[@]}"; do
    validate_one "$f" || failures=$((failures + 1))
  done
else
  validate_one "$TARGET" || failures=$((failures + 1))
fi

if [[ "$failures" -gt 0 ]]; then
  err "$failures validation run(s) failed."
  exit 1
fi
log "All validations passed."
