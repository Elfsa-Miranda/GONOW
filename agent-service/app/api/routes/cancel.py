"""Authenticated Run cancellation route factory."""

from __future__ import annotations

from collections.abc import Callable
from typing import Literal
from uuid import UUID

from fastapi import APIRouter, HTTPException, Request
from pydantic import BaseModel, ConfigDict, Field

from app.auth.context import AuthorizationPolicy, RequestContext
from app.runtime.cancellation import CancelRejected, CancellationService


ContextResolver = Callable[[Request], RequestContext]
AuditReceiptResolver = Callable[[RequestContext, UUID], str]


class CancelRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")

    expected_version: int = Field(ge=0)


class CancelResponse(BaseModel):
    model_config = ConfigDict(extra="forbid")

    status: Literal["cancelling", "cancelled"]
    run_id: UUID
    version: int
    replayed: bool


def create_cancel_router(
    cancellation: CancellationService,
    context_resolver: ContextResolver,
    audit_receipt_resolver: AuditReceiptResolver,
) -> APIRouter:
    """Persist intent after authorization; connection lifetime has no cancel effect."""

    policy = AuthorizationPolicy()
    router = APIRouter(prefix="/v1/runs", tags=["run-cancel"])

    @router.post("/{run_id}/cancel", response_model=CancelResponse)
    async def cancel_run(
        run_id: UUID,
        body: CancelRequest,
        request: Request,
    ) -> CancelResponse:
        context = context_resolver(request)
        policy.authorize(
            context,
            action="run.cancel",
            resource_tenant_id=context.tenant_id,
        )
        try:
            result = cancellation.request_cancel(
                tenant_id=context.tenant_id,
                principal_id=context.principal_id,
                run_id=run_id,
                expected_version=body.expected_version,
                audit_receipt_id=audit_receipt_resolver(context, run_id),
            )
        except CancelRejected as error:
            raise HTTPException(status_code=409, detail=error.code) from error
        return CancelResponse(
            status=result.state.value,
            run_id=result.run_id,
            version=result.version,
            replayed=result.replayed,
        )

    return router
