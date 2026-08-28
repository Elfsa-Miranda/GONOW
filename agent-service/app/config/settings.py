"""Typed, secret-free service configuration."""

from __future__ import annotations

from typing import Literal

from pydantic import AnyHttpUrl, BaseModel, ConfigDict, Field


class SecretReference(BaseModel):
    """A provider locator; it never contains secret material."""

    model_config = ConfigDict(extra="forbid", frozen=True)

    name: str = Field(min_length=1, max_length=80, pattern=r"^[a-z][a-z0-9_]*$")
    provider_key: str = Field(min_length=1, max_length=120, pattern=r"^[A-Z][A-Z0-9_]*$")


class ServiceSettings(BaseModel):
    """Startup configuration accepted by both API and Worker processes."""

    model_config = ConfigDict(extra="forbid", frozen=True)

    environment: Literal["local", "test", "staging", "production"]
    database_host: str = Field(min_length=1, max_length=253)
    database_port: int = Field(default=5432, ge=1, le=65535)
    database_name: str = Field(min_length=1, max_length=63, pattern=r"^[A-Za-z_][A-Za-z0-9_]*$")
    jwks_url: AnyHttpUrl
    secret_references: tuple[SecretReference, ...] = Field(min_length=1)

    def required_secret_names(self) -> tuple[str, ...]:
        return tuple(reference.name for reference in self.secret_references)
