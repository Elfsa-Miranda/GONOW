"""Fail-closed asymmetric JWT verification with bounded JWKS refresh."""

from __future__ import annotations

import asyncio
import time
from collections.abc import Mapping, Sequence
from typing import Any, Protocol

import jwt
import httpx
from pydantic import BaseModel, ConfigDict, Field


ALLOWED_ALGORITHMS = ("RS256",)
CLOCK_SKEW_TOLERANCE_SECONDS = 300


class AuthInvalidToken(RuntimeError):
    code = "auth.invalid_token"

    def __init__(self) -> None:
        super().__init__(self.code)


class JwksUnavailable(RuntimeError):
    pass


class JwksProvider(Protocol):
    async def load(self) -> Mapping[str, Any]:
        """Return a JWKS document from an approved identity endpoint."""


class StaticJwksProvider:
    """Synthetic provider used by isolated tests."""

    def __init__(self, documents: Sequence[Mapping[str, Any]]) -> None:
        self._documents = list(documents)
        self.calls = 0

    async def load(self) -> Mapping[str, Any]:
        if not self._documents:
            raise JwksUnavailable("jwks unavailable")
        index = min(self.calls, len(self._documents) - 1)
        self.calls += 1
        return self._documents[index]


class HttpJwksProvider:
    """Fetch JWKS only from a configured HTTPS identity host without redirects."""

    def __init__(
        self,
        url: str,
        *,
        allowed_hosts: Sequence[str],
        transport: httpx.AsyncBaseTransport | None = None,
    ) -> None:
        parsed = httpx.URL(url)
        normalized_hosts = {host.lower() for host in allowed_hosts}
        if parsed.scheme != "https" or parsed.userinfo or parsed.host is None:
            raise ValueError("jwks url must be an uncredentialed HTTPS URL")
        if parsed.host.lower() not in normalized_hosts:
            raise ValueError("jwks host is not approved")
        self._url = parsed
        self._transport = transport

    async def load(self) -> Mapping[str, Any]:
        try:
            async with httpx.AsyncClient(
                transport=self._transport,
                follow_redirects=False,
                timeout=httpx.Timeout(5.0),
            ) as client:
                response = await client.get(self._url)
                response.raise_for_status()
                document = response.json()
            if not isinstance(document, dict):
                raise JwksUnavailable("invalid jwks")
            return document
        except JwksUnavailable:
            raise
        except Exception as error:
            raise JwksUnavailable("jwks unavailable") from error


class JwksCache:
    """Cache public keys briefly and refresh once when a key id rotates."""

    def __init__(self, provider: JwksProvider, ttl_seconds: int = 300) -> None:
        if ttl_seconds < 1:
            raise ValueError("ttl_seconds must be positive")
        self._provider = provider
        self._ttl_seconds = ttl_seconds
        self._keys: dict[str, Any] = {}
        self._loaded_at = 0.0
        self._lock = asyncio.Lock()
        self.ready = False

    async def _refresh(self) -> None:
        try:
            document = await self._provider.load()
            raw_keys = document.get("keys")
            if not isinstance(raw_keys, list):
                raise JwksUnavailable("invalid jwks")
            accepted: dict[str, Any] = {}
            for raw_key in raw_keys:
                if not isinstance(raw_key, dict):
                    continue
                if raw_key.get("kty") != "RSA" or raw_key.get("alg") not in (None, "RS256"):
                    continue
                key_id = raw_key.get("kid")
                if not isinstance(key_id, str) or not key_id:
                    continue
                accepted[key_id] = jwt.PyJWK.from_dict(raw_key, algorithm="RS256").key
            if not accepted:
                raise JwksUnavailable("no approved jwks keys")
            self._keys = accepted
            self._loaded_at = time.monotonic()
            self.ready = True
        except Exception as error:
            self.ready = False
            if isinstance(error, JwksUnavailable):
                raise
            raise JwksUnavailable("jwks unavailable") from error

    async def get_key(self, key_id: str) -> Any:
        async with self._lock:
            stale = time.monotonic() - self._loaded_at >= self._ttl_seconds
            if not self._keys or stale:
                await self._refresh()
            key = self._keys.get(key_id)
            if key is None:
                await self._refresh()
                key = self._keys.get(key_id)
            if key is None:
                raise JwksUnavailable("unknown key id")
            return key

    async def warm(self) -> None:
        """Require at least one approved key before declaring the API ready."""

        async with self._lock:
            await self._refresh()


class VerifiedIdentity(BaseModel):
    model_config = ConfigDict(extra="forbid", frozen=True)

    subject: str = Field(min_length=1)
    tenant_id: str = Field(min_length=1)
    issuer: str = Field(min_length=1)
    permissions: tuple[str, ...]
    key_id: str = Field(min_length=1)


class AuthVerifier:
    def __init__(self, *, issuer: str, audience: str, jwks: JwksCache) -> None:
        self._issuer = issuer
        self._audience = audience
        self._jwks = jwks

    @property
    def ready(self) -> bool:
        return self._jwks.ready

    async def verify(self, token: str) -> VerifiedIdentity:
        try:
            header = jwt.get_unverified_header(token)
            algorithm = header.get("alg")
            key_id = header.get("kid")
            if algorithm not in ALLOWED_ALGORITHMS or not isinstance(key_id, str) or not key_id:
                raise AuthInvalidToken()
            key = await self._jwks.get_key(key_id)
            claims = jwt.decode(
                token,
                key=key,
                algorithms=list(ALLOWED_ALGORITHMS),
                issuer=self._issuer,
                audience=self._audience,
                leeway=CLOCK_SKEW_TOLERANCE_SECONDS,
                options={"require": ["iss", "aud", "sub", "exp", "iat", "tenant_id"]},
            )
            permissions = claims.get("permissions", [])
            if not isinstance(permissions, list) or not all(isinstance(item, str) for item in permissions):
                raise AuthInvalidToken()
            return VerifiedIdentity(
                subject=claims["sub"],
                tenant_id=claims["tenant_id"],
                issuer=claims["iss"],
                permissions=tuple(permissions),
                key_id=key_id,
            )
        except AuthInvalidToken:
            raise
        except Exception as error:
            raise AuthInvalidToken() from error
