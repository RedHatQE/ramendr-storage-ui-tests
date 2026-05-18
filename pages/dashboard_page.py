"""Page object for the dashboard page."""

from playwright.sync_api import expect
from pages.base_page import BasePage


class DashboardPage(BasePage):
    """Dashboard page actions and validations."""

    # OpenShift Console lands on Overview after login (stable post-auth marker).
    _OVERVIEW_HEADING = "Overview"

    def assert_page_loaded(self):
        """Verify that the dashboard (console overview) page is loaded."""
        expect(self.page.get_by_role("heading", name=self._OVERVIEW_HEADING)).to_be_visible()
