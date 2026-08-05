from __future__ import annotations

import site
import sys
from pathlib import Path

import pytest


SERVICE_ROOT = Path(__file__).resolve().parents[2]
site.addsitedir(str(SERVICE_ROOT / ".venv" / "Lib" / "site-packages"))
sys.path.insert(0, str(SERVICE_ROOT))

from app.auth.context import (  # noqa: E402
    AuthorizationForbidden,
    AuthorizationPolicy,
    ContextInvalid,
    RequestContext,
    TenantScope,
)
from app.auth.jwt import VerifiedIdentity  # noqa: E402


IDENTITY = VerifiedIdentity(
    subject="principal-1",
    tenant_id="tenant-1",
    issuer="https://identity.test.invalid",
    permissions=("itinerary.read",),
    key_id="key-1",
)


def _context() -> RequestContext:
    return RequestContext.from_identity(IDENTITY, {"x-trace-id": "trace-1"})


def test_request_context_is_server_derived() -> None:
    context = _context()
    assert context.principal_id == IDENTITY.subject
    assert context.tenant_id == IDENTITY.tenant_id


def test_client_tenant_override_is_rejected() -> None:
    with pytest.raises(ContextInvalid):
        RequestContext.from_identity(IDENTITY, {"x-trace-id": "trace-1", "x-tenant-id": "tenant-2"})


def test_cross_tenant_resource_is_denied() -> None:
    with pytest.raises(AuthorizationForbidden):
        TenantScope.from_context(_context()).require_resource_tenant("tenant-2")


def test_authorization_policy_denies_unlisted_action() -> None:
    with pytest.raises(AuthorizationForbidden):
        AuthorizationPolicy().authorize(
            _context(), action="itinerary.delete", resource_tenant_id="tenant-1"
        )
