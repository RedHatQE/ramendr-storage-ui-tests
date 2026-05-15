from playwright.sync_api import expect
from pages.base_page import BasePage


class DashboardPage(BasePage):
    def assert_loaded(self):
        expect(self.page.locator("body")).to_be_visible()
