from __future__ import annotations

import json
import site
import sys
import time
from pathlib import Path

import jwt
import httpx
import pytest
from cryptography.hazmat.primitives.asymmetric import rsa


SERVICE_ROOT = Path(__file__).resolve().parents[2]
site.addsitedir(str(SERVICE_ROOT / ".venv" / "Lib" / "site-packages"))
sys.path.insert(0, str(SERVICE_ROOT))

from app.auth.jwt import (  # noqa: E402
    AuthInvalidToken,
    AuthVerifier,
    HttpJwksProvider,
    JwksCache,
    StaticJwksProvider,
)


ISSUER = "https://identity.test.invalid"
AUDIENCE = "gonow-agent"
PRIVATE_KEY = rsa.generate_private_key(public_exponent=65537, key_size=2048)
PUBLIC_JWK = json.loads(jwt.algorithms.RSAAlgorithm.to_jwk(PRIVATE_KEY.public_key()))
PUBLIC_JWK.update({"kid": "key-1", "alg": "RS256", "use": "sig"})


def _claims(**overrides: object) -> dict[str, object]:
    now = int(time.time())
    claims: dict[str, object] = {
        "iss": ISSUER,
        "aud": AUDIENCE,
        "sub": "principal-1",
        "tenant_id": "tenant-1",
        "permissions": ["itinerary.read"],
        "iat": now,
        "exp": now + 600,
    }
    claims.update(overrides)
    return claims


def _verifier(document: dict[str, object] | None = None) -> AuthVerifier:
    provider = StaticJwksProvider([document or {"keys": [PUBLIC_JWK]}])
    return AuthVerifier(issuer=ISSUER, audience=AUDIENCE, jwks=JwksCache(provider))


def _rs256(**overrides: object) -> str:
    return jwt.encode(_claims(**overrides), PRIVATE_KEY, algorithm="RS256", headers={"kid": "key-1"})


@pytest.mark.asyncio
async def test_rs256_valid_claims_are_verified() -> None:
    identity = await _verifier().verify(_rs256())
    assert identity.subject == "principal-1"
    assert identity.tenant_id == "tenant-1"


@pytest.mark.asyncio
async def test_ct_003_alg_none_is_rejected() -> None:
    token = jwt.encode(_claims(), key="", algorithm="none", headers={"kid": "key-1"})
    with pytest.raises(AuthInvalidToken, match="auth.invalid_token"):
        await _verifier().verify(token)


@pytest.mark.asyncio
async def test_ct_004_hmac_is_rejected_before_key_lookup() -> None:
    provider = StaticJwksProvider([{"keys": [PUBLIC_JWK]}])
    verifier = AuthVerifier(issuer=ISSUER, audience=AUDIENCE, jwks=JwksCache(provider))
    token = jwt.encode(_claims(), key="synthetic-hmac-key-at-least-32-bytes", algorithm="HS256", headers={"kid": "key-1"})
    with pytest.raises(AuthInvalidToken):
        await verifier.verify(token)
    assert provider.calls == 0


@pytest.mark.asyncio
async def test_nbf_plus_299_seconds_passes() -> None:
    identity = await _verifier().verify(_rs256(nbf=int(time.time()) + 299))
    assert identity.subject == "principal-1"


@pytest.mark.asyncio
async def test_nbf_plus_301_seconds_is_invalid_token() -> None:
    with pytest.raises(AuthInvalidToken, match="auth.invalid_token"):
        await _verifier().verify(_rs256(nbf=int(time.time()) + 301))


@pytest.mark.asyncio
async def test_unknown_kid_is_rejected_after_one_refresh() -> None:
    token = jwt.encode(_claims(), PRIVATE_KEY, algorithm="RS256", headers={"kid": "unknown-key"})
    with pytest.raises(AuthInvalidToken):
        await _verifier().verify(token)


@pytest.mark.asyncio
async def test_spoofed_body_user_is_denied_before_context_creation() -> None:
    from app.api.middleware.auth import AuthMiddleware
    from app.auth.context import ContextInvalid

    with pytest.raises(ContextInvalid, match="context.invalid"):
        await AuthMiddleware(_verifier()).authenticate(
            {"authorization": f"Bearer {_rs256()}", "x-trace-id": "trace-1"},
            body={"user_id": "spoofed-principal"},
        )


@pytest.mark.asyncio
async def test_http_jwks_provider_is_https_host_allowlisted_and_no_redirect() -> None:
    async def handler(request: httpx.Request) -> httpx.Response:
        assert request.url.host == "identity.test.invalid"
        return httpx.Response(200, json={"keys": [PUBLIC_JWK]})

    provider = HttpJwksProvider(
        "https://identity.test.invalid/.well-known/jwks.json",
        allowed_hosts=["identity.test.invalid"],
        transport=httpx.MockTransport(handler),
    )

    assert (await provider.load())["keys"] == [PUBLIC_JWK]


def test_http_jwks_provider_rejects_unapproved_host() -> None:
    with pytest.raises(ValueError, match="not approved"):
        HttpJwksProvider(
            "https://unapproved.test.invalid/jwks.json",
            allowed_hosts=["identity.test.invalid"],
        )


@pytest.mark.asyncio
@pytest.mark.parametrize(
    "claim_overrides",
    [
        {"iss": "https://wrong.test.invalid"},
        {"aud": "wrong-audience"},
        {"exp": int(time.time()) - 301},
    ],
)
async def test_invalid_registered_claim_is_rejected(claim_overrides: dict[str, object]) -> None:
    with pytest.raises(AuthInvalidToken):
        await _verifier().verify(_rs256(**claim_overrides))
