from __future__ import annotations

import site
import sys
from pathlib import Path

import pytest

SERVICE_ROOT=Path(__file__).resolve().parents[3];site.addsitedir(str(SERVICE_ROOT/".venv"/"Lib"/"site-packages"));sys.path.insert(0,str(SERVICE_ROOT))
from app.api.middleware.auth import AuthMiddleware  # noqa: E402
from app.auth.context import ContextInvalid, RequestContext  # noqa: E402
from app.auth.jwt import AuthInvalidToken, VerifiedIdentity  # noqa: E402

IDENTITY=VerifiedIdentity(subject="principal-1",tenant_id="tenant-1",issuer="https://identity.test.invalid",permissions=("read",),key_id="key-1")

def test_01_request_context_s_server_derived_refs() -> None:
    context=RequestContext.from_identity(IDENTITY,{"x-trace-id":"trace-1"});assert (context.principal_id,context.tenant_id)==("principal-1","tenant-1")

def test_01_request_context_i_missing_header_is_invalid() -> None:
    with pytest.raises(ContextInvalid):RequestContext.from_identity(IDENTITY,{})

def test_01_request_context_d_client_tenant_override_is_invalid() -> None:
    with pytest.raises(ContextInvalid):RequestContext.from_identity(IDENTITY,{"x-trace-id":"trace-1","x-tenant-id":"tenant-2"})

def test_01_request_context_d_safe_fields_exclude_token() -> None:
    fields=RequestContext.from_identity(IDENTITY,{"x-trace-id":"trace-1"}).safe_log_fields();assert "token" not in fields

@pytest.mark.asyncio
async def test_01_request_context_d_body_spoof_never_enters_context() -> None:
    class Verifier:
        async def verify(self, token: str) -> VerifiedIdentity:return IDENTITY
    with pytest.raises(ContextInvalid):await AuthMiddleware(Verifier()).authenticate({"authorization":"Bearer synthetic","x-trace-id":"trace-1"},{"user_id":"spoofed"})

@pytest.mark.asyncio
async def test_01_request_context_d_identity_dependency_failure_closed() -> None:
    class Verifier:
        async def verify(self, token: str) -> VerifiedIdentity:raise AuthInvalidToken()
    with pytest.raises(AuthInvalidToken):await AuthMiddleware(Verifier()).authenticate({"authorization":"Bearer synthetic","x-trace-id":"trace-1"})
