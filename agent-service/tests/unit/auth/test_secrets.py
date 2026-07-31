from __future__ import annotations

import site
import sys
from pathlib import Path

import pytest


SERVICE_ROOT = Path(__file__).resolve().parents[3]
site.addsitedir(str(SERVICE_ROOT / ".venv" / "Lib" / "site-packages"))
sys.path.insert(0, str(SERVICE_ROOT))

from app.auth.secrets import (  # noqa: E402
    EnvironmentSecretsProvider,
    SecretUnavailableError,
    SyntheticSecretsProvider,
    validate_required_secrets,
)
from app.config.settings import SecretReference  # noqa: E402


REFERENCE = SecretReference(name="database_password", provider_key="GONOW_DATABASE_PASSWORD")


@pytest.mark.asyncio
async def test_missing_secret_readiness_false(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.delenv(REFERENCE.provider_key, raising=False)

    readiness = await validate_required_secrets([REFERENCE], EnvironmentSecretsProvider())

    assert readiness.ready is False
    assert readiness.missing_secret_names == (REFERENCE.name,)


@pytest.mark.asyncio
async def test_missing_secret_error_is_redacted(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.delenv(REFERENCE.provider_key, raising=False)

    with pytest.raises(SecretUnavailableError) as captured:
        await EnvironmentSecretsProvider().get_secret(REFERENCE)

    assert str(captured.value) == "required secret unavailable: database_password"
    assert REFERENCE.provider_key not in str(captured.value)


@pytest.mark.asyncio
async def test_synthetic_canary_is_masked_in_repr() -> None:
    canary = "gonow-p02-002-secret-canary"
    provider = SyntheticSecretsProvider({REFERENCE.provider_key: canary})

    secret = await provider.get_secret(REFERENCE)

    assert canary not in repr(secret)
    assert repr(secret) == "SecretStr('**********')"


@pytest.mark.asyncio
async def test_provider_protocol_has_no_value_cache_on_environment_provider() -> None:
    provider = EnvironmentSecretsProvider()

    assert vars(provider) == {}
