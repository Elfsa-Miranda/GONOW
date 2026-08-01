from __future__ import annotations

import json
import site
import sys
import time
from pathlib import Path

import jwt
import pytest
from cryptography.hazmat.primitives.asymmetric import rsa

SERVICE_ROOT=Path(__file__).resolve().parents[3];site.addsitedir(str(SERVICE_ROOT/".venv"/"Lib"/"site-packages"));sys.path.insert(0,str(SERVICE_ROOT))
from app.auth.jwt import AuthInvalidToken, AuthVerifier, JwksCache, JwksUnavailable, StaticJwksProvider  # noqa: E402

ISSUER="https://identity.test.invalid";AUDIENCE="gonow-agent";KEY=rsa.generate_private_key(public_exponent=65537,key_size=2048)
JWK=json.loads(jwt.algorithms.RSAAlgorithm.to_jwk(KEY.public_key()));JWK.update({"kid":"key-1","alg":"RS256"})

def claims(**values: object) -> dict[str,object]:
    now=int(time.time());base={"iss":ISSUER,"aud":AUDIENCE,"sub":"principal-1","tenant_id":"tenant-1","permissions":["read"],"iat":now,"exp":now+600};base.update(values);return base
def token(**values: object) -> str:return jwt.encode(claims(**values),KEY,algorithm="RS256",headers={"kid":"key-1"})
def verifier(provider: StaticJwksProvider|None=None) -> AuthVerifier:return AuthVerifier(issuer=ISSUER,audience=AUDIENCE,jwks=JwksCache(provider or StaticJwksProvider([{"keys":[JWK]}])))

@pytest.mark.asyncio
async def test_02_auth_verifier_s_valid_rs256_claims() -> None:assert (await verifier().verify(token())).subject=="principal-1"
@pytest.mark.asyncio
async def test_02_auth_verifier_i_alg_none_ct_003() -> None:
    with pytest.raises(AuthInvalidToken):await verifier().verify(jwt.encode(claims(),"",algorithm="none",headers={"kid":"key-1"}))
@pytest.mark.asyncio
async def test_02_auth_verifier_i_hs256_ct_004() -> None:
    provider=StaticJwksProvider([{"keys":[JWK]}])
    with pytest.raises(AuthInvalidToken):await verifier(provider).verify(jwt.encode(claims(),"synthetic-hmac-key-at-least-32-bytes",algorithm="HS256",headers={"kid":"key-1"}))
    assert provider.calls==0
@pytest.mark.asyncio
async def test_02_auth_verifier_i_expired_token() -> None:
    with pytest.raises(AuthInvalidToken):await verifier().verify(token(exp=int(time.time())-301))
@pytest.mark.asyncio
async def test_02_auth_verifier_i_wrong_issuer() -> None:
    with pytest.raises(AuthInvalidToken):await verifier().verify(token(iss="https://wrong.test.invalid"))
@pytest.mark.asyncio
async def test_02_auth_verifier_i_wrong_audience() -> None:
    with pytest.raises(AuthInvalidToken):await verifier().verify(token(aud="wrong"))
@pytest.mark.asyncio
async def test_02_auth_verifier_i_unknown_kid() -> None:
    with pytest.raises(AuthInvalidToken):await verifier().verify(jwt.encode(claims(),KEY,algorithm="RS256",headers={"kid":"unknown"}))
@pytest.mark.asyncio
async def test_02_auth_verifier_i_removed_old_kid() -> None:
    new_key=rsa.generate_private_key(public_exponent=65537,key_size=2048);new_jwk=json.loads(jwt.algorithms.RSAAlgorithm.to_jwk(new_key.public_key()));new_jwk.update({"kid":"key-2","alg":"RS256"})
    cache=JwksCache(StaticJwksProvider([{"keys":[JWK]},{"keys":[new_jwk]}]));selected=AuthVerifier(issuer=ISSUER,audience=AUDIENCE,jwks=cache);await selected.verify(token())
    rotated=jwt.encode(claims(),new_key,algorithm="RS256",headers={"kid":"key-2"});await selected.verify(rotated)
    with pytest.raises(AuthInvalidToken):await selected.verify(token())
@pytest.mark.asyncio
async def test_02_auth_verifier_s_nbf_plus_299() -> None:assert (await verifier().verify(token(nbf=int(time.time())+299))).subject=="principal-1"
@pytest.mark.asyncio
async def test_02_auth_verifier_i_nbf_plus_301() -> None:
    with pytest.raises(AuthInvalidToken):await verifier().verify(token(nbf=int(time.time())+301))
@pytest.mark.asyncio
async def test_02_auth_verifier_d_missing_bearer_is_invalid() -> None:
    from app.api.middleware.auth import AuthMiddleware
    with pytest.raises(AuthInvalidToken):await AuthMiddleware(verifier()).authenticate({"x-trace-id":"trace-1"})
@pytest.mark.asyncio
async def test_02_auth_verifier_d_non_bearer_is_invalid() -> None:
    from app.api.middleware.auth import AuthMiddleware
    with pytest.raises(AuthInvalidToken):await AuthMiddleware(verifier()).authenticate({"authorization":"Basic abc","x-trace-id":"trace-1"})
@pytest.mark.asyncio
async def test_02_auth_verifier_d_jwks_unavailable_is_closed() -> None:
    selected=verifier(StaticJwksProvider([]))
    with pytest.raises(AuthInvalidToken):await selected.verify(token())
    assert selected.ready is False
