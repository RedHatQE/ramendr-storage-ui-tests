"""Load the optional repository-root ``.env`` file into ``os.environ``.

This is the single, central place local credentials/config for this repo
(e.g. ``JIRA_BASE_URL`` / ``JIRA_EMAIL`` / ``JIRA_API_TOKEN`` for
``reporting/jira_client.py``) can live on a developer machine instead of
being exported by hand before every ``pytest`` invocation.

This intentionally stays local to pytest so it does not import the
standalone DR-validation helpers in
``dr-validation/ramendr_dr_validation/db_audit.py`` and
``db_audit_mssql.py``. Keep their shared dotenv-style behavior aligned:
plain ``KEY=VALUE`` lines, ``#`` comments, blank lines ignored, no
dependency on ``python-dotenv``.

Precedence: real environment variables (shell export, CI secret store,
``RAMENDR_*``/``JIRA_*`` set externally) always win. ``.env`` only fills in
values that are *not already set* (``os.environ.setdefault``), so this file
is safe to source in any order relative to CI/shell exports.

Scope: only ``pytest`` runs (via the root ``conftest.py``) load this file
automatically. Standalone scripts under ``scripts/`` do not import this
module and must continue to receive credentials via exported environment
variables. This file is not read by -- and does not configure -- any
Cursor MCP server; MCP processes get their environment from their own
``mcp.json``/``--env-file`` configuration (see ``.env.example`` for a note
on this).
"""

from __future__ import annotations

import os
from pathlib import Path

#: Repository root is this file's grandparent (``config/env_file.py`` ->
#: ``config/`` -> repo root).
_REPO_ROOT = Path(__file__).resolve().parent.parent
DEFAULT_ENV_PATH = _REPO_ROOT / ".env"


def load_env_file(path: Path | str | None = None) -> None:
    """Load ``KEY=VALUE`` lines from ``path`` (default repo-root ``.env``).

    No-op if the file does not exist. Never overwrites a variable that is
    already present in ``os.environ`` (external env always wins over the
    file). Never raises on malformed lines -- lines without ``=`` or
    starting with ``#`` are silently skipped.
    """
    env_path = Path(path) if path is not None else DEFAULT_ENV_PATH
    if not env_path.is_file():
        return
    for line in env_path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        key = key.strip()
        value = value.strip()
        # Allow optionally-quoted values (KEY="value" / KEY='value').
        if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
            value = value[1:-1]
        if key:
            os.environ.setdefault(key, value)
