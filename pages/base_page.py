"""Base page object shared by all UI pages."""

from playwright.sync_api import Page


class BasePage:
    """Base class for all page objects."""

    def __init__(self, page: Page):
        """Initialize the page object with a Playwright page."""
        self.page = page

    def open(self, url: str):
        """Open the given URL in the browser."""
        self.page.goto(url)
