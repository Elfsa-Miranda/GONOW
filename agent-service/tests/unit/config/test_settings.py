from __future__ import annotations

import site
import sys
from pathlib import Path

import pytest


SERVICE_ROOT = Path(__file__).resolve().parents[3]
site.addsitedir(str(SERVICE_ROOT / ".venv" / "Lib" / "site-packages"))
sys.path.insert(0, str(SERVICE_ROOT))

from app.config.settings import ServiceSettings  # noqa: E402


def _valid_settings() -> dict[str, object]:
    return {
        "environment": "test",
        "database_host": "database.test.invalid",
        "database_name": "gonow_test",
        "jwks_url": "https://identity.test.invalid/.well-known/jwks.json",
        "secret_references": [
            {"name": "database_password", "provider_key": "GONOW_DATABASE_PASSWORD"}
        ],
    }


def test_typed_settings_accept_only_secret_references() -> None:
    settings = ServiceSettings.model_validate(_valid_settings())

    assert settings.environment == "test"
    assert settings.required_secret_names() == ("database_password",)


def test_typed_settings_reject_literal_secret_fields() -> None:
    source = _valid_settings()
    source["database_password"] = "synthetic-value-must-not-enter-settings"

    with pytest.raises(ValueError, match="Extra inputs are not permitted"):
        ServiceSettings.model_validate(source)
