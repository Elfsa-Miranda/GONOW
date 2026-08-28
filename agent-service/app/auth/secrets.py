"""Secret provider boundary with redacted failures and no value cache."""

from __future__ import annotations

import os
from collections.abc import Mapping, Sequence
from typing import Protocol, runtime_checkable

from pydantic import BaseModel, ConfigDict, SecretStr

from app.config.settings import SecretReference


class SecretUnavailableError(RuntimeError):
    """Raised using only a non-sensitive logical secret name."""

    def __init__(self, secret_name: str) -> None:
        super().__init__(f"required secret unavailable: {secret_name}")
        self.secret_name = secret_name


class SecretReadiness(BaseModel):
    model_config = ConfigDict(extra="forbid", frozen=True)

    ready: bool
    missing_secret_names: tuple[str, ...]


@runtime_checkable
class SecretsProvider(Protocol):
    async def get_secret(self, reference: SecretReference) -> SecretStr:
        """Resolve one secret on demand without logging or checkpointing it."""


class EnvironmentSecretsProvider:
    """Read a named environment entry on every request; no values are cached."""

    async def get_secret(self, reference: SecretReference) -> SecretStr:
        raw_value = os.environ.get(reference.provider_key)
        if raw_value is None or raw_value == "":
            raise SecretUnavailableError(reference.name)
        return SecretStr(raw_value)


class SyntheticSecretsProvider:
    """In-memory provider restricted to synthetic unit-test fixtures."""

    def __init__(self, values: Mapping[str, str]) -> None:
        self._values = {key: SecretStr(value) for key, value in values.items()}

    async def get_secret(self, reference: SecretReference) -> SecretStr:
        value = self._values.get(reference.provider_key)
        if value is None:
            raise SecretUnavailableError(reference.name)
        return value


async def validate_required_secrets(
    references: Sequence[SecretReference],
    provider: SecretsProvider,
) -> SecretReadiness:
    """Check presence while discarding each resolved value immediately."""

    missing: list[str] = []
    for reference in references:
        try:
            resolved = await provider.get_secret(reference)
            if resolved.get_secret_value() == "":
                missing.append(reference.name)
        except SecretUnavailableError:
            missing.append(reference.name)
    return SecretReadiness(ready=not missing, missing_secret_names=tuple(missing))
