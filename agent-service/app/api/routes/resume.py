"""Authenticated, one-use Run resume route."""

from __future__ import annotations

from collections.abc import Callable
from typing import Annotated, Literal
from uuid import UUID

from fastapi import APIRouter, HTTPException, Request
from pydantic import BaseModel, ConfigDict, Field, SecretStr

from app.api.context_resolver import ContextResolver, resolve_request_context
from app.auth.context import AuthorizationPolicy, RequestContext
from app.auth.resume_token import (
    ResumeCapabilityRecord,
    ResumeCapabilityRejected,
    ResumeCapabilityService,
)


ResumeHandler = Callable[[RequestContext, ResumeCapabilityRecord], None]


class ResumeRequest(BaseModel):
    """Exact interrupt command and its opaque, short-lived capability."""

    model_config = ConfigDict(extra="forbid")

    resume_token: SecretStr
    interrupt_id: UUID
    command_hash: Annotated[str, Field(pattern=r"^[0-9a-f]{64}$")]
    command_version: Annotated[str, Field(pattern=r"^[0-9]+\.[0-9]+$")]


class ResumeResponse(BaseModel):
    model_config = ConfigDict(extra="forbid")

    status: Literal["resumed"] = "resumed"
    run_id: UUID
    interrupt_id: UUID
    command_version: str


def create_resume_router(
    capabilities: ResumeCapabilityService,
    context_resolver: ContextResolver,
    resume_handler: ResumeHandler,
) -> APIRouter:
    """Authorize identity, consume the exact capability once, then resume."""

    policy = AuthorizationPolicy()
    router = APIRouter(prefix="/v1/runs", tags=["run-resume"])

    @router.post("/{run_id}/resume", response_model=ResumeResponse)
    async def resume_run(
        run_id: UUID,
        body: ResumeRequest,
        request: Request,
    ) -> ResumeResponse:
        context = await resolve_request_context(context_resolver, request)
        policy.authorize(
            context,
            action="run.resume",
            resource_tenant_id=context.tenant_id,
        )
        try:
            capability = capabilities.consume(
                token=body.resume_token.get_secret_value(),
                tenant_id=context.tenant_id,
                principal_id=context.principal_id,
                run_id=run_id,
                interrupt_id=body.interrupt_id,
                command_hash=body.command_hash,
                command_version=body.command_version,
            )
        except ResumeCapabilityRejected as error:
            raise HTTPException(status_code=409, detail=error.code) from error
        try:
            resume_handler(context, capability)
        except ResumeCapabilityRejected as error:
            raise HTTPException(status_code=409, detail=error.code) from error
        return ResumeResponse(
            run_id=run_id,
            interrupt_id=body.interrupt_id,
            command_version=body.command_version,
        )

    return router
