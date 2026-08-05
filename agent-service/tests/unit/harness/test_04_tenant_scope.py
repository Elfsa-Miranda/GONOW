from __future__ import annotations
import site,sys
from pathlib import Path
import pytest
SERVICE_ROOT=Path(__file__).resolve().parents[3];site.addsitedir(str(SERVICE_ROOT/".venv"/"Lib"/"site-packages"));sys.path.insert(0,str(SERVICE_ROOT))
from app.auth.context import AuthorizationForbidden,ContextInvalid,RequestContext,TenantScope,TenantScopeMissing  # noqa: E402
from app.auth.jwt import VerifiedIdentity  # noqa: E402
CONTEXT=RequestContext(principal_id="principal-1",tenant_id="tenant-1",permissions=("read",),locale="en",timezone="UTC",trace_id="trace-1")
def test_04_tenant_scope_s_fixes_tenant_filter() -> None:assert TenantScope.from_context(CONTEXT).tenant_id=="tenant-1"
def test_04_tenant_scope_i_missing_tenant() -> None:
    with pytest.raises(TenantScopeMissing):TenantScope.from_context(RequestContext(principal_id="p",tenant_id="",permissions=(),locale="en",timezone="UTC",trace_id="t"))
def test_04_tenant_scope_i_client_override_denied() -> None:
    identity=VerifiedIdentity(subject="p",tenant_id="tenant-1",issuer="https://identity.test.invalid",permissions=(),key_id="k")
    with pytest.raises(ContextInvalid):RequestContext.from_identity(identity,{"x-trace-id":"t","x-tenant-id":"tenant-2"})
def test_04_tenant_scope_d_cross_tenant_canary_zero() -> None:
    leak_count=0
    try:TenantScope.from_context(CONTEXT).require_resource_tenant("tenant-2");leak_count+=1
    except AuthorizationForbidden:pass
    assert leak_count==0
def test_04_tenant_scope_d_resolver_failure_closed() -> None:
    with pytest.raises(TenantScopeMissing):TenantScope.from_context(RequestContext(principal_id="p",tenant_id="",permissions=(),locale="en",timezone="UTC",trace_id="t"))
