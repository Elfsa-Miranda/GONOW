"""Content-addressed public schema registry and descriptor route."""

from __future__ import annotations

import hashlib
import json
from pathlib import Path
from typing import Any

from fastapi import APIRouter
from pydantic import BaseModel, ConfigDict, Field


EXPECTED_OPENAPI_SHA256 = "ba776e2c464ff6faf1866c7e369756368a43b5023642ac6318758e55f857b8ed"
PUBLIC_ERROR_CODES = (
    "auth.forbidden",
    "auth.invalid_token",
    "context.invalid",
    "internal.error",
    "rate.limit",
    "schema.unsupported",
    "service.unavailable",
    "tenant.scope_missing",
)


class SchemaUnsupported(RuntimeError):
    code = "schema.unsupported"

    def __init__(self) -> None:
        super().__init__(self.code)


class SchemaDigestMismatch(RuntimeError):
    code = "schema.digest_mismatch"

    def __init__(self) -> None:
        super().__init__(self.code)


class SchemaRegistryUnavailable(RuntimeError):
    code = "service.unavailable"

    def __init__(self) -> None:
        super().__init__(self.code)


class ContractDescriptor(BaseModel):
    model_config = ConfigDict(extra="forbid", frozen=True)

    name: str = Field(pattern=r"^[a-z][a-z0-9-]+$")
    major: int = Field(ge=1)
    version: str = Field(pattern=r"^[0-9]+\.[0-9]+\.[0-9]+$")
    spec_sha256: str = Field(pattern=r"^[a-f0-9]{64}$")


class SchemaCodec:
    """JSON codec bound to one immutable public schema digest."""

    def __init__(self, descriptor: ContractDescriptor) -> None:
        self.descriptor = descriptor

    def encode(self, value: dict[str, Any]) -> bytes:
        return json.dumps(value, ensure_ascii=True, separators=(",", ":"), sort_keys=True).encode("utf-8")

    def decode(self, value: bytes) -> dict[str, Any]:
        decoded = json.loads(value.decode("utf-8"))
        if not isinstance(decoded, dict):
            raise ValueError("schema payload must be an object")
        return decoded


class SchemaRegistry:
    def __init__(self, specification_path: Path, *, expected_sha256: str = EXPECTED_OPENAPI_SHA256) -> None:
        self._path = specification_path
        self._expected_sha256 = expected_sha256
        self.available = True

    def resolve(self, name: str, major: int) -> SchemaCodec:
        if not self.available:
            raise SchemaRegistryUnavailable()
        if name != "agent-api" or major != 1:
            raise SchemaUnsupported()
        try:
            raw = self._path.read_bytes()
            digest = hashlib.sha256(raw).hexdigest()
            if digest != self._expected_sha256:
                raise SchemaDigestMismatch()
            specification = json.loads(raw)
            if (
                specification.get("openapi") != "3.1.0"
                or specification.get("x-contract-name") != name
                or specification.get("info", {}).get("version") != "1.0.0"
                or tuple(specification.get("x-error-codes", ())) != PUBLIC_ERROR_CODES
            ):
                raise SchemaDigestMismatch()
            return SchemaCodec(
                ContractDescriptor(name=name, major=major, version="1.0.0", spec_sha256=digest)
            )
        except (SchemaDigestMismatch, SchemaUnsupported):
            raise
        except Exception as error:
            raise SchemaRegistryUnavailable() from error


def create_contract_router(registry: SchemaRegistry) -> APIRouter:
    router = APIRouter(prefix="/v1/contracts", tags=["contracts"])

    @router.get("/{name}/{major}", response_model=ContractDescriptor)
    async def get_contract(name: str, major: int) -> ContractDescriptor:
        return registry.resolve(name, major).descriptor

    return router
