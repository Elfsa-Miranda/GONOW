"""Fail-closed startup validation shared by API and Worker."""

from __future__ import annotations

from pydantic import BaseModel, ConfigDict

from app.auth.secrets import SecretsProvider, validate_required_secrets
from app.config.settings import ServiceSettings


class StartupReadiness(BaseModel):
    model_config = ConfigDict(extra="forbid", frozen=True)

    configuration_valid: bool
    secrets_ready: bool
    missing_secret_names: tuple[str, ...]

    @property
    def ready(self) -> bool:
        return self.configuration_valid and self.secrets_ready


async def validate_startup(
    settings: ServiceSettings,
    provider: SecretsProvider,
) -> StartupReadiness:
    """Resolve every required secret without retaining its value."""

    secret_readiness = await validate_required_secrets(settings.secret_references, provider)
    return StartupReadiness(
        configuration_valid=True,
        secrets_ready=secret_readiness.ready,
        missing_secret_names=secret_readiness.missing_secret_names,
    )
