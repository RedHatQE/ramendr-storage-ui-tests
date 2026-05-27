"""Page object for the ACM DR hub DRPC overview page."""

import re

from playwright.sync_api import expect

from pages.base_page import BasePage

# Status text inside <span data-test="status-text"> for a healthy DRPC.
_HEALTHY_STATUS_RE = re.compile(r"^\s*Healthy\s*$", re.IGNORECASE)


class DRPCPage(BasePage):
    """ACM Data Services → Disaster Recovery page."""

    # ------------------------------------------------------------------
    # Navigation helpers
    # ------------------------------------------------------------------

    def navigate(self, base_url: str):  # noqa: ARG002 — kept for API compatibility
        """Open Data Services → Disaster recovery via the left-hand nav.

        Switches to the Fleet Management perspective first (using the
        perspective-switcher toggle at the top of the nav) so the ACM nav
        items — including Data Services — are available regardless of which
        perspective the console landed on after login.
        """
        # Switch to Fleet Management perspective if not already there.
        switcher = self.page.locator("[data-test-id='perspective-switcher-toggle']")
        switcher.wait_for(timeout=15_000)
        if "Fleet Management" not in (switcher.text_content() or ""):
            switcher.click()
            # PatternFly v6 menu items are buttons inside .pf-v6-c-menu__item;
            # fall back to any element with the exact text if the class changes.
            fleet_item = self.page.locator(".pf-v6-c-menu__item").filter(
                has_text="Fleet Management"
            )
            if fleet_item.count() == 0:
                fleet_item = self.page.get_by_role("option", name="Fleet Management")
            if fleet_item.count() == 0:
                fleet_item = self.page.get_by_text("Fleet Management").first
            fleet_item.first.click()
            self.page.wait_for_load_state("domcontentloaded")

        # Expand "Data Services" in the left nav if collapsed.
        # Wait for the button to be present — React may not have rendered it yet.
        data_services_btn = self.page.get_by_role("button", name="Data Services")
        data_services_btn.wait_for(timeout=15_000)
        if data_services_btn.get_attribute("aria-expanded") == "false":
            data_services_btn.click()

        self.page.get_by_role("link", name="Disaster recovery").click()
        # Wait for the horizontal tab bar to confirm the DR page has loaded.
        self.page.locator("[data-test-id='horizontal-link-Policies']").wait_for(
            timeout=15_000
        )

    def navigate_policies_tab(self):
        """Switch to the Policies horizontal tab."""
        self.page.locator("[data-test-id='horizontal-link-Policies']").click()
        # Wait for the table to render before assertions.
        self.page.locator("tr[role='row']").first.wait_for(timeout=15_000)

    def navigate_protected_applications_tab(self):
        """Switch to the Protected applications horizontal tab."""
        self.page.locator(
            "[data-test-id='horizontal-link-Protected applications']"
        ).click()
        # Wait for the table to render before assertions.
        self.page.locator("tr").first.wait_for(timeout=15_000)

    # ------------------------------------------------------------------
    # Assertions — Policies tab
    # ------------------------------------------------------------------

    def assert_drpolicy(
        self,
        policy_name: str,
        *,
        expected_status: str = "Validated",
        expected_applications: str = "1 Application",
    ):
        """Assert a DRPolicy row shows the expected status and application count.

        Targets the ReactVirtualized DRPolicy table whose cells carry
        data-label attributes (lowercase) for stable column matching.
        """
        row = self.page.locator("tr[role='row']").filter(
            has=self.page.locator("td[data-label='name']").filter(
                has_text=re.compile(rf"^\s*{re.escape(policy_name)}\s*$")
            )
        )
        expect(
            row,
            f"DRPolicy row '{policy_name}' not found in the Policies table",
        ).to_be_visible(timeout=10_000)

        expect(
            row.locator("td[data-label='status']"),
            f"DRPolicy '{policy_name}': expected status '{expected_status}'",
        ).to_have_text(expected_status, timeout=10_000)

        expect(
            row.locator("td[data-label='applications']"),
            f"DRPolicy '{policy_name}': expected applications '{expected_applications}'",
        ).to_have_text(expected_applications, timeout=10_000)

    # ------------------------------------------------------------------
    # Assertions — Protected applications tab
    # ------------------------------------------------------------------

    def assert_drpc(
        self,
        drpc_name: str,
        *,
        expected_policy: str,
        expected_cluster: str,
    ):
        """Assert a DRPC row is visible and healthy with the expected policy and cluster.

        Uses data-label cell attributes and data-test identifiers from the
        Protected applications table HTML. DR Status is checked via the
        <span data-test="status-text"> element inside the status cell.
        """
        # Find the row by the resource link unique to this DRPC.
        row = self.page.locator("tr").filter(
            has=self.page.locator(f"a[data-test='resource-link-{drpc_name}']")
        )
        expect(
            row,
            f"DRPC row '{drpc_name}' not found in the Protected applications table",
        ).to_be_visible(timeout=10_000)

        # DR Status — the status text lives in <span data-test="status-text">.
        status_span = row.locator(
            "td[data-label='DR Status'] [data-test='status-text']"
        )
        expect(
            status_span,
            f"DRPC '{drpc_name}': DR Status is not Healthy",
        ).to_have_text(_HEALTHY_STATUS_RE, timeout=10_000)

        # Policy link text.
        expect(
            row.locator("td[data-label='Policy']"),
            f"DRPC '{drpc_name}': expected policy '{expected_policy}'",
        ).to_have_text(expected_policy, timeout=10_000)

        # Cluster plain text cell.
        expect(
            row.locator("td[data-label='Cluster']"),
            f"DRPC '{drpc_name}': expected cluster '{expected_cluster}'",
        ).to_have_text(expected_cluster, timeout=10_000)
