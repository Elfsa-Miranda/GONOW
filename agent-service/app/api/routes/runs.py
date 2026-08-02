"""Typed public route for idempotent itinerary Run creation."""

from __future__ import annotations

from datetime import date
from typing import Annotated, Literal
from uuid import UUID

from fastapi import APIRouter, Header, HTTPException, Request
from fastapi.concurrency import run_in_threadpool
from pydantic import BaseModel, ConfigDict, Field, StringConstraints

from app.api.context_resolver import ContextResolver, resolve_request_context
from app.auth.context import AuthorizationForbidden
from app.persistence.repositories.runs import IdempotencyConflict
from app.runtime.run_start import RunStartRejected, RunStartService


SafePlace = Annotated[str, StringConstraints(strip_whitespace=True, min_length=1, max_length=160)]
SafeConstraint = Annotated[
    str, StringConstraints(strip_whitespace=True, min_length=1, max_length=160)
]


class ItineraryPlanningInput(BaseModel):
    model_config = ConfigDict(extra="forbid", frozen=True)

    schema_version: Literal["1.0"] = "1.0"
    origin: SafePlace
    destination: SafePlace
    starts_on: date
    days: int = Field(ge=1, le=31)
    budget_minor: int = Field(ge=0, le=1_000_000_000)
    currency: str = Field(pattern=r"^[A-Z]{3}$")
    locale: str = Field(pattern=r"^[a-z]{2}(?:-[A-Z]{2})?$")
    timezone: str = Field(min_length=1, max_length=64, pattern=r"^[A-Za-z0-9_+./-]+$")
    hard_constraints: tuple[SafeConstraint, ...] = Field(default=(), max_length=20)


class RunStartRequest(BaseModel):
    model_config = ConfigDict(extra="forbid", frozen=True)

    schema_version: Literal["1.0"] = "1.0"
    thread_id: UUID
    itinerary: ItineraryPlanningInput


class RunStartResponse(BaseModel):
    model_config = ConfigDict(extra="forbid", frozen=True)

    run_id: UUID
    thread_id: UUID
    state: Literal["queued"]
    version: int = Field(ge=1)
    replayed: bool
    behavior_digest: str = Field(pattern=r"^[0-9a-f]{64}$")


def create_runs_router(
    service: RunStartService,
    context_resolver: ContextResolver,
) -> APIRouter:
    router = APIRouter(prefix="/v1/runs", tags=["runs"])

    @router.post("", response_model=RunStartResponse, status_code=202)
    async def start_run(
        body: RunStartRequest,
        request: Request,
        idempotency_key: Annotated[
            str,
            Header(alias="Idempotency-Key", min_length=16, max_length=128),
        ],
    ) -> RunStartResponse:
        try:
            context = await resolve_request_context(context_resolver, request)
            result = await run_in_threadpool(
                service.start,
                context=context,
                thread_id=body.thread_id,
                idempotency_key=idempotency_key,
                structured_input=body.itinerary.model_dump(mode="json"),
            )
        except AuthorizationForbidden as error:
            raise HTTPException(status_code=403, detail=error.code) from error
        except IdempotencyConflict as error:
            raise HTTPException(status_code=409, detail=error.code) from error
        except RunStartRejected as error:
            raise HTTPException(status_code=409, detail=error.code) from error
        return RunStartResponse(
            run_id=result.run_id,
            thread_id=result.thread_id,
            state="queued",
            version=result.version,
            replayed=result.replayed,
            behavior_digest=result.behavior_digest,
        )

    return router
