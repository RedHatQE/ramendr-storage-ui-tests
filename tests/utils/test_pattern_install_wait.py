"""Tests for BYOC pattern install recoverability."""

from __future__ import annotations

import subprocess
from pathlib import Path

import pytest

from tests.utils.pattern_variant import hub_argocd_namespace

REPO_ROOT = Path(__file__).resolve().parents[2]
BYOC_IMPORT_WAIT = REPO_ROOT / "scripts/lib/byoc-import-wait.sh"
PATTERN_VARIANT = REPO_ROOT / "scripts/lib/pattern-variant.sh"


def _bash_eval(body: str, *, pattern_variant: str = "odf") -> str:
    script = f"""
set -euo pipefail
source "{PATTERN_VARIANT}"
source "{BYOC_IMPORT_WAIT}"
PATTERN_VARIANT="{pattern_variant}"
export PATTERN_VARIANT
{body}
"""
    return subprocess.run(
        ["bash", "-c", script],
        check=True,
        capture_output=True,
        text=True,
    ).stdout.strip()


@pytest.mark.parametrize(
    "hub,rdr,acm,joined,expected",
    [
        ("Healthy", "Unknown", "Healthy", "1", "0"),
        ("Healthy", "Unknown", "Progressing", "1", "0"),
        ("Missing", "Healthy", "Progressing", "1", "0"),
        ("Missing", "Unknown", "Healthy", "1", "0"),
        ("Missing", "Unknown", "Progressing", "3", "0"),
        ("Missing", "Unknown", "Progressing", "1", "1"),
    ],
)
def test_pattern_install_recoverable_or_semantics(hub, rdr, acm, joined, expected):
    ns = hub_argocd_namespace()
    body = f"""
hub_pattern_app_health() {{ echo "{hub}"; }}
oc() {{
  if [[ "$*" == *"regional-dr"* ]]; then echo "{rdr}"; return 0; fi
  if [[ "$*" == *"application.argoproj.io acm"* ]]; then echo "{acm}"; return 0; fi
  if [[ "$*" == *"managedclusters --no-headers"* ]]; then
    seq 1 {joined} | while read -r _; do echo mc; done
    return 0
  fi
  return 0
}}
hub_argocd_namespace() {{ echo "{ns}"; }}
hub_pattern_app_name() {{ echo "{ns}"; }}
if pattern_install_recoverable; then echo 0; else echo 1; fi
"""
    assert _bash_eval(body) == str(expected)
