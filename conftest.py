"""Shared pytest fixtures for Playwright UI tests."""

import pytest

from config.settings import IGNORE_HTTPS_ERRORS


@pytest.fixture(scope="session")
def browser_context_args():
    """Configure the Playwright browser context for all tests."""
    return {
        "viewport": {"width": 1280, "height": 720},
        "ignore_https_errors": IGNORE_HTTPS_ERRORS,
    }
