"""Shared pytest fixtures for Playwright UI tests and oc-based smoke tests."""

import tempfile
from typing import Any, Dict

import pytest

from config.settings import (
    HUB_KUBECONFIG,
    IGNORE_HTTPS_ERRORS,
    PRIMARY_KUBECONFIG,
    SECONDARY_KUBECONFIG,
)


@pytest.fixture(scope="session")
def browser_context_args(
    pytestconfig: Any,
    _pw_artifacts_folder: tempfile.TemporaryDirectory,
) -> Dict:
    """Configure the Playwright browser context for all tests.

    Mirrors the parameters accepted by pytest-playwright's own
    browser_context_args so that --video / --tracing flags are not silently
    dropped when our fixture overrides the plugin's default.
    """
    args: Dict = {
        "viewport": {"width": 1280, "height": 720},
        "ignore_https_errors": IGNORE_HTTPS_ERRORS,
    }

    video_option = pytestconfig.getoption("--video")
    if video_option in ["on", "retain-on-failure"]:
        args["record_video_dir"] = _pw_artifacts_folder.name

    return args


@pytest.fixture(scope="session")
def hub_kubeconfig() -> str:
    """Path to the hub cluster kubeconfig (RAMENDR_HUB_KUBECONFIG)."""
    return HUB_KUBECONFIG


@pytest.fixture(scope="session")
def primary_kubeconfig() -> str:
    """Path to the primary spoke kubeconfig (RAMENDR_PRIMARY_KUBECONFIG)."""
    return PRIMARY_KUBECONFIG


@pytest.fixture(scope="session")
def secondary_kubeconfig() -> str:
    """Path to the secondary spoke kubeconfig (RAMENDR_SECONDARY_KUBECONFIG)."""
    return SECONDARY_KUBECONFIG
