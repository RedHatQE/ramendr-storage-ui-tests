"""Page object for the login page."""

import re

from playwright.sync_api import expect

from pages.base_page import BasePage


class LoginPage(BasePage):
    """Login page actions and validations."""

    def assert_page_loaded(self):
        """Verify that the login page is loaded."""
        expect(self.page.locator("body")).to_be_visible()

    def login(self, username: str, password: str):
        """Log in via the OpenShift identity provider selection page.

        Clicks the kubeadmin IdP button if an IdP-selection screen is shown,
        then fills credentials and submits. Falls back to the only visible IdP
        link when kube:admin is not present by name.
        """
        # IdP selection — OpenShift renders IdP choices as <a> or <button>.
        # Try kube:admin by name first; fall back to the single available IdP.
        idp = self.page.get_by_role(
            "link", name=re.compile(r"kube:?admin", re.IGNORECASE)
        )
        if idp.count() == 0:
            idp = self.page.get_by_role(
                "button", name=re.compile(r"kube:?admin", re.IGNORECASE)
            )
        if idp.count() == 0:
            # Fall back: click the only IdP link/button on the page (if exactly one).
            all_links = self.page.get_by_role("link").filter(
                has=self.page.locator("span, div")
            )
            all_buttons = self.page.get_by_role("button").filter(
                has=self.page.locator("span, div")
            )
            link_count = all_links.count()
            button_count = all_buttons.count()
            if link_count + button_count == 1:
                idp = all_links if link_count == 1 else all_buttons

        if idp.count() > 0:
            idp.first.click()

        # Fill credentials using accessible labels (OpenShift form standard).
        self.page.get_by_label("Username").fill(username)
        self.page.get_by_label("Password").fill(password)

        # Submit — the button text is typically "Log in" on OpenShift.
        self.page.get_by_role(
            "button", name=re.compile(r"log.?in|sign.?in", re.IGNORECASE)
        ).click()

        # Wait for navigation away from the /login path.
        expect(self.page).not_to_have_url(re.compile(r"/login"), timeout=15_000)
