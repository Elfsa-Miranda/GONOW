"""Server-derived request, tenant, and authorization context."""

from __future__ import annotations

from dataclasses import dataclass
from types import MappingProxyType
from typing import Mapping

from app.auth.jwt import VerifiedIdentity


class ContextInvalid(RuntimeError):
    code = "context.invalid"

    def __init__(self) -> None:
        super().__init__(self.code)


class TenantScopeMissing(RuntimeError):
    code = "tenant.scope_missing"

    def __init__(self) -> None:
        super().__init__(self.code)


class AuthorizationForbidden(RuntimeError):
    code = "auth.forbidden"

    def __init__(self) -> None:
        super().__init__(self.code)


@dataclass(frozen=True, slots=True)
class RequestContext:
    principal_id: str
    tenant_id: str
    permissions: tuple[str, ...]
    locale: str
    timezone: str
    trace_id: str

    @classmethod
    def from_identity(cls, identity: VerifiedIdentity, headers: Mapping[str, str]) -> "RequestContext":
        normalized = {key.lower(): value for key, value in headers.items()}
        if "x-tenant-id" in normalized or not identity.tenant_id:
            raise ContextInvalid()
        trace_id = normalized.get("x-trace-id", "")
        if not trace_id or len(trace_id) > 128:
            raise ContextInvalid()
        return cls(
            principal_id=identity.subject,
            tenant_id=identity.tenant_id,
            permissions=identity.permissions,
            locale=normalized.get("x-locale", "en"),
            timezone=normalized.get("x-timezone", "UTC"),
            trace_id=trace_id,
        )

    def safe_log_fields(self) -> Mapping[str, str]:
        return MappingProxyType(
            {"principal_ref": self.principal_id, "tenant_ref": self.tenant_id, "trace_id": self.trace_id}
        )


@dataclass(frozen=True, slots=True)
class TenantScope:
    tenant_id: str

    @classmethod
    def from_context(cls, context: RequestContext) -> "TenantScope":
        if not context.tenant_id:
            raise TenantScopeMissing()
        return cls(tenant_id=context.tenant_id)

    def require_resource_tenant(self, resource_tenant_id: str) -> None:
        if resource_tenant_id != self.tenant_id:
            raise AuthorizationForbidden()


class AuthorizationPolicy:
    """Deny unless both the action and resource tenant are explicitly allowed."""

    def authorize(
        self,
        context: RequestContext,
        *,
        action: str,
        resource_tenant_id: str,
        requested_fields: set[str] | None = None,
        allowed_fields: set[str] | None = None,
        approval_valid: bool = True,
    ) -> None:
        TenantScope.from_context(context).require_resource_tenant(resource_tenant_id)
        if action not in context.permissions or not approval_valid:
            raise AuthorizationForbidden()
        if requested_fields is not None and allowed_fields is not None and not requested_fields <= allowed_fields:
            raise AuthorizationForbidden()
