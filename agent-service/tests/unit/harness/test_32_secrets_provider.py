from __future__ import annotations

import site
import sys
from pathlib import Path

import pytest


SERVICE_ROOT = Path(__file__).resolve().parents[3]
site.addsitedir(str(SERVICE_ROOT / ".venv" / "Lib" / "site-packages"))
sys.path.insert(0, str(SERVICE_ROOT))

from app.auth.secrets import SyntheticSecretsProvider, validate_required_secrets  # noqa: E402
from app.config.settings import SecretReference, ServiceSettings  # noqa: E402


REFERENCE = SecretReference(name="database_password", provider_key="GONOW_DATABASE_PASSWORD")


@pytest.mark.asyncio
async def test_32_secrets_provider_s_resolves_synthetic_reference() -> None:
    provider = SyntheticSecretsProvider({REFERENCE.provider_key: "synthetic-only"})
    assert (await validate_required_secrets([REFERENCE], provider)).ready is True


@pytest.mark.asyncio
async def test_32_secrets_provider_i_missing_secret_readiness_false() -> None:
    assert (await validate_required_secrets([REFERENCE], SyntheticSecretsProvider({}))).ready is False


@pytest.mark.asyncio
async def test_32_secrets_provider_d_canary_never_enters_readiness() -> None:
    canary = "gonow-p02-002-harness-canary"
    readiness = await validate_required_secrets(
        [REFERENCE], SyntheticSecretsProvider({REFERENCE.provider_key: canary})
    )
    assert canary not in repr(readiness)


def test_32_secrets_provider_d_literal_secret_is_rejected() -> None:
    with pytest.raises(ValueError):
        ServiceSettings.model_validate(
            {
                "environment": "test",
                "database_host": "database.test.invalid",
                "database_name": "gonow_test",
                "jwks_url": "https://identity.test.invalid/jwks.json",
                "secret_references": [REFERENCE.model_dump()],
                "api_key": "synthetic-value-must-not-enter-settings",
            }
        )
