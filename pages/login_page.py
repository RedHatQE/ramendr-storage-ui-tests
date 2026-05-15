from playwright.sync_api import expect
from pages.base_page import BasePage


class LoginPage(BasePage):
    def assert_page_loaded(self):
        expect(self.page.locator("body")).to_be_visible()
