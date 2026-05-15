"""Page object for the dashboard page."""

from playwright.sync_api import expect
from pages.base_page import BasePage


class DashboardPage(BasePage):
    """Dashboard page actions and validations."""

    def assert_loaded(self):
        """Verify that the dashboard page is loaded."""
        expect(self.page.locator("body")).to_be_visible()
