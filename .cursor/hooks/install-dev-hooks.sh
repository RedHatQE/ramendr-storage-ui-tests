#!/usr/bin/env bash
# Cursor sessionStart: install git pre-commit/pre-push hooks (idempotent, non-blocking).
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# Ignore session JSON on stdin.
cat >/dev/null 2>&1 || true
if [[ -x "${REPO_ROOT}/scripts/setup-dev.sh" ]]; then
  "${REPO_ROOT}/scripts/setup-dev.sh" >/dev/null 2>&1 || true
fi
exit 0
