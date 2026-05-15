from playwright.sync_api import expect
from pages.base_page import BasePage


class DashboardPage(BasePage):
    def assert_page_loaded(self):
        expect(self.page.locator("[data-testid='dashboard']")).to_be_visible()
