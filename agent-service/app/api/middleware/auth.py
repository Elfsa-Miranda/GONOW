"""Authentication pipeline boundary for HTTP adapters."""

from __future__ import annotations

from collections.abc import Mapping

from app.auth.context import ContextInvalid, RequestContext
from app.auth.jwt import AuthInvalidToken, AuthVerifier


class AuthMiddleware:
    def __init__(self, verifier: AuthVerifier) -> None:
        self._verifier = verifier

    async def authenticate(
        self,
        headers: Mapping[str, str],
        body: Mapping[str, object] | None = None,
    ) -> RequestContext:
        normalized = {key.lower(): value for key, value in headers.items()}
        authorization = normalized.get("authorization", "")
        scheme, separator, token = authorization.partition(" ")
        if separator != " " or scheme != "Bearer" or not token:
            raise AuthInvalidToken()
        if body is not None and any(key in body for key in ("user_id", "tenant_id")):
            raise ContextInvalid()
        identity = await self._verifier.verify(token)
        return RequestContext.from_identity(identity, normalized)
