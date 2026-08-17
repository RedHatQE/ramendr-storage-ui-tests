# shellcheck shell=bash
# Re-exec the calling script with GNU bash 4+ (macOS /usr/bin/bash is 3.2, no mapfile).
#
# Must be sourced from a standalone script (uses $0 / "$@"). The re-exec marker is
# per-script so a parent that already re-execed (redeploy.sh) does not skip the
# child's own re-exec.

if [[ "${BASH_VERSINFO[0]:-0}" -lt 4 ]]; then
  if [[ "${RAMENDR_GNU_BASH_REEXECED_FOR:-}" == "$0" ]]; then
    echo "ERROR: GNU bash 4+ is required (mapfile). Re-exec of $0 still has bash ${BASH_VERSION:-unknown}." >&2
    echo "On macOS: brew install bash" >&2
    exit 1
  fi
  for _bash in "${GNU_BASH:-}" /opt/homebrew/bin/bash /usr/local/bin/bash; do
    if [[ -n "${_bash}" && -x "$_bash" ]]; then
      export RAMENDR_GNU_BASH_REEXECED_FOR="$0"
      exec "$_bash" "$0" "$@"
    fi
  done
  echo "ERROR: GNU bash 4+ is required (mapfile). On macOS: brew install bash" >&2
  exit 1
fi
