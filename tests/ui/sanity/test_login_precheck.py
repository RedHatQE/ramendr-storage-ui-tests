"""Login-only precheck for the RamenDR ACM hub console.

Minimal, standalone test: opens the hub console, logs in with
RAMENDR_HUB_USERNAME / RAMENDR_HUB_PASSWORD, and confirms the dashboard
loaded (i.e. the OAuth login actually succeeded).

Does NOT:
  - navigate to Disaster Recovery / DRPC
  - perform failover or relocate
  - import or call anything from ``reporting/`` (no Jira calls of any kind,
    not even indirectly via import)

Use this to validate hub console credentials cheaply before running the
full sanity DR flow (``tests/ui/sanity/test_sanity.py``).

    pytest tests/ui/sanity/test_login_precheck.py --tb=short

``--tb=short`` gives a compact traceback on failure. Frame-local variables
are only printed when ``--showlocals``/``-l`` is explicitly passed -- do
**not** enable that flag when running this test: ``LoginPage.login()``
receives the plaintext password as an argument, and ``--showlocals`` would
print it in the traceback on failure.
"""

from __future__ import annotations

import pytest

from config.settings import BASE_URL, HUB_PASSWORD, HUB_USERNAME
from pages.dashboard_page import DashboardPage
from pages.login_page import LoginPage


def _require_ui_credentials() -> None:
    """Skip the test if BASE_URL, HUB_USERNAME, or HUB_PASSWORD are unset."""
    if not BASE_URL:
        pytest.skip(
            "BASE_URL is empty — set BASE_DOMAIN or RAMENDR_BASE_URL before running UI tests"
        )
    missing = [
        name
        for name, val in [
            ("RAMENDR_HUB_USERNAME", HUB_USERNAME),
            ("RAMENDR_HUB_PASSWORD", HUB_PASSWORD),
        ]
        if not val
    ]
    if missing:
        pytest.skip(f"Required env var(s) not set: {', '.join(missing)}")


@pytest.mark.smoke
@pytest.mark.login
def test_hub_console_login_precheck(page):
    """Log in to the hub console and confirm the dashboard loads. Nothing else."""
    _require_ui_credentials()

    login_page = LoginPage(page)
    login_page.open(BASE_URL)
    login_page.assert_page_loaded()
    login_page.login(HUB_USERNAME, HUB_PASSWORD)

    dashboard = DashboardPage(page)
    dashboard.assert_page_loaded()
    dashboard.dismiss_welcome_if_present()
