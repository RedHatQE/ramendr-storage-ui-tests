"""Tests for optional local environment-file loading."""

import os
from pathlib import Path

from config.env_file import load_env_file


def test_load_env_file_loads_values_without_overwriting_environment(
    tmp_path: Path, monkeypatch
) -> None:
    """A local file fills missing values but shell/CI values take precedence."""
    env_file = tmp_path / ".env"
    env_file.write_text(
        "# local configuration\n"
        "FROM_FILE=loaded\n"
        "EXTERNAL_VALUE=from-file\n"
        "QUOTED_VALUE='quoted value'\n"
        "MALFORMED_LINE\n",
        encoding="utf-8",
    )
    monkeypatch.delenv("FROM_FILE", raising=False)
    monkeypatch.setenv("EXTERNAL_VALUE", "from-shell")
    monkeypatch.delenv("QUOTED_VALUE", raising=False)

    try:
        load_env_file(env_file)

        assert os.environ["FROM_FILE"] == "loaded"
        assert os.environ["EXTERNAL_VALUE"] == "from-shell"
        assert os.environ["QUOTED_VALUE"] == "quoted value"
    finally:
        # load_env_file writes directly to os.environ, so remove values it
        # added and let monkeypatch restore any values that existed before.
        os.environ.pop("FROM_FILE", None)
        os.environ.pop("QUOTED_VALUE", None)


def test_load_env_file_is_a_noop_when_file_is_missing(tmp_path: Path) -> None:
    """An absent local .env must not prevent ordinary test runs."""
    load_env_file(tmp_path / ".env")
