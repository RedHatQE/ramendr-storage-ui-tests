import pytest
from config.settings import BASE_URL
from pages.login_page import LoginPage


@pytest.mark.smoke
@pytest.mark.requires_stage
def test_ui_loads(page):
    login_page = LoginPage(page)

    login_page.open(BASE_URL)
    login_page.assert_page_loaded()
