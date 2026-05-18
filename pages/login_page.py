"""Page object for the login page."""

from playwright.sync_api import expect
from pages.base_page import BasePage


class LoginPage(BasePage):
    """Login page actions and validations."""

    def assert_page_loaded(self):
        """Verify that the login page is loaded."""
        expect(self.page.locator("body")).to_be_visible()
