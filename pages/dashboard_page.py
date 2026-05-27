"""Page object for the dashboard page."""

import re

from playwright.sync_api import TimeoutError as PlaywrightTimeoutError, expect

from pages.base_page import BasePage

# Selector for the "Skip tour" button inside the guided-tour modal
# (<button data-test="tour-step-footer-secondary"> inside #guided-tour-modal).
# The modal close button (aria-label="Close") is kept as a fallback.
_WELCOME_DISMISS_SELECTORS = [
    "#guided-tour-modal [data-test='tour-step-footer-secondary']",
    "#guided-tour-modal button[aria-label='Close']",
]


class DashboardPage(BasePage):
    """Dashboard page actions and validations."""

    def dismiss_welcome_if_present(self, timeout: int = 5_000):
        """Dismiss the ACM welcome tour/modal if it is visible.

        Called after login because ACM shows a welcome overlay on every fresh
        browser context (no persistent localStorage). Non-blocking: if no
        welcome UI is detected the method returns silently.
        """
        for selector in _WELCOME_DISMISS_SELECTORS:
            locator = self.page.locator(selector).first
            try:
                locator.click(timeout=timeout)
                self.page.wait_for_load_state("domcontentloaded")
                return
            except PlaywrightTimeoutError:
                continue

    def assert_page_loaded(self):
        """Verify that login succeeded by confirming the URL left the login path."""
        expect(self.page).not_to_have_url(
            re.compile(r"/login"),
            timeout=30_000,
        )
