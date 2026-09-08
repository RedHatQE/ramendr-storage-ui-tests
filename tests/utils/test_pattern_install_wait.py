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
    "hub,rdr,spokes_joined,expected",
    [
        ("Healthy", "Unknown", "2", "0"),
        ("Missing", "Healthy", "2", "0"),
        ("Healthy", "Unknown", "1", "1"),
        ("Missing", "Unknown", "2", "1"),
        ("Missing", "Unknown", "3", "1"),
        ("Missing", "Progressing", "0", "1"),
    ],
)
def test_pattern_install_recoverable_requires_spokes_and_parent_or_rdr(
    hub, rdr, spokes_joined, expected
):
    ns = hub_argocd_namespace()
    body = f"""
hub_pattern_app_health() {{ echo "{hub}"; }}
oc() {{
  if [[ "$*" == *"regional-dr"* ]]; then echo "{rdr}"; return 0; fi
  return 0
}}
byoc_spokes_joined_count() {{ echo "{spokes_joined}"; }}
hub_argocd_namespace() {{ echo "{ns}"; }}
hub_pattern_app_name() {{ echo "{ns}"; }}
if pattern_install_recoverable; then echo 0; else echo 1; fi
"""
    assert _bash_eval(body) == str(expected)


def test_pattern_install_recoverable_ignores_acm_only():
    ns = hub_argocd_namespace()
    body = f"""
hub_pattern_app_health() {{ echo "Missing"; }}
oc() {{
  if [[ "$*" == *"regional-dr"* ]]; then echo "Unknown"; return 0; fi
  if [[ "$*" == *"application.argoproj.io acm"* ]]; then echo "Healthy"; return 0; fi
  return 0
}}
byoc_spokes_joined_count() {{ echo "2"; }}
hub_argocd_namespace() {{ echo "{ns}"; }}
if pattern_install_recoverable; then echo 0; else echo 1; fi
"""
    assert _bash_eval(body) == "1"


def _init_variant_git_repo(tmp_path: Path, variant: str) -> Path:
    repo = tmp_path / "upstream"
    repo.mkdir()
    (repo / "values-global.yaml").write_text(f"main:\n  variant: {variant}\n")
    subprocess.run(["git", "init"], cwd=repo, check=True, capture_output=True)
    subprocess.run(["git", "add", "values-global.yaml"], cwd=repo, check=True)
    subprocess.run(
        [
            "git",
            "-c",
            "user.email=test@example.com",
            "-c",
            "user.name=test",
            "-c",
            "commit.gpgsign=false",
            "commit",
            "-m",
            "init",
        ],
        cwd=repo,
        check=True,
        capture_output=True,
    )
    return repo


def test_require_variant_gitops_match_fails_on_partner_mismatch(tmp_path: Path):
    repo = _init_variant_git_repo(tmp_path, "odf")
    body = f"""
UPSTREAM_BRANCH=""
if _require_variant_gitops_match "{repo}" >/dev/null; then echo 0; else echo 1; fi
"""
    assert _bash_eval(body, pattern_variant="drpartner-s4") == "1"


def test_require_variant_gitops_match_ok_when_git_matches(tmp_path: Path):
    repo = _init_variant_git_repo(tmp_path, "drpartner-s4")
    body = f"""
UPSTREAM_BRANCH=""
if _require_variant_gitops_match "{repo}" >/dev/null; then echo 0; else echo 1; fi
"""
    assert _bash_eval(body, pattern_variant="drpartner-s4") == "0"


def test_pattern_install_stop_group_terminates_children():
    body = r"""
(
  pattern_install_exec_in_group bash -c 'sleep 30 & wait'
) &
leader=$!
for _ in $(seq 1 50); do
  kill -0 "$leader" 2>/dev/null && break
  sleep 0.05
done
child=""
if command -v pgrep >/dev/null 2>&1; then
  child="$(pgrep -P "$leader" | head -n 1 || true)"
fi
pattern_install_stop_group "$leader"
sleep 0.3
if kill -0 "$leader" 2>/dev/null; then
  echo leader-alive
  exit 0
fi
if [[ -n "$child" ]] && kill -0 "$child" 2>/dev/null; then
  echo child-alive
  exit 0
fi
echo dead
"""
    assert _bash_eval(body) == "dead"
