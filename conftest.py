import pytest
from config import settings


@pytest.fixture(scope="session")
def browser_context_args():
    return {
        "viewport": {"width": 1280, "height": 720},
        "ignore_https_errors": settings.IGNORE_HTTPS_ERRORS,
    }
