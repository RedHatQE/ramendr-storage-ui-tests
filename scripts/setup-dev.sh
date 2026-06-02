#!/usr/bin/env bash
# Install local git hooks so pre-commit runs automatically on commit and push.
# Idempotent — safe to run repeatedly (also invoked from .cursor/hooks on session start).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

if ! git rev-parse --git-dir >/dev/null 2>&1; then
  echo "Not a git repository: ${REPO_ROOT}" >&2
  exit 1
fi

install_pre_commit() {
  if command -v pre-commit >/dev/null 2>&1; then
    return 0
  fi
  if [[ -x "${REPO_ROOT}/.venv/bin/pre-commit" ]]; then
    export PATH="${REPO_ROOT}/.venv/bin:${PATH}"
    return 0
  fi
  echo "Installing pre-commit..."
  if [[ -x "${REPO_ROOT}/.venv/bin/pip" ]]; then
    "${REPO_ROOT}/.venv/bin/pip" install -q pre-commit
    export PATH="${REPO_ROOT}/.venv/bin:${PATH}"
    return 0
  fi
  python3 -m pip install --user -q pre-commit
  export PATH="${HOME}/.local/bin:${PATH}"
}

install_pre_commit
if ! command -v pre-commit >/dev/null 2>&1; then
  echo "pre-commit not found. Install with: pip install pre-commit" >&2
  exit 1
fi

pre-commit install
echo "Dev hooks ready: pre-commit runs on git commit and git push (same checks as CI)."
