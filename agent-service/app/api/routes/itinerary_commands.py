"""Default-off public boundary for the selected Basic Info Domain Command."""

from __future__ import annotations

from datetime import date
from decimal import Decimal
from typing import Annotated, Literal, Protocol
from uuid import UUID

from fastapi import APIRouter, Header, HTTPException, Request
from fastapi.concurrency import run_in_threadpool
from pydantic import BaseModel, ConfigDict, Field, StringConstraints

from app.api.context_resolver import ContextResolver, resolve_request_context
from app.auth.context import AuthorizationForbidden, RequestContext
from app.commands.itinerary_basic_info import (
    ItineraryBasicInfoPatch,
    ItineraryBasicInfoReceipt,
    UpdateItineraryBasicInfoCommand,
)
from app.persistence.repositories.itinerary_basic_info_commands import (
    DomainCommandIdempotencyConflict,
    DomainCommandPersistenceError,
    DomainCommandTargetDenied,
)


class ItineraryBasicInfoCommandExecutor(Protocol):
    def execute(
        self,
        *,
        context: RequestContext,
        command: UpdateItineraryBasicInfoCommand,
    ) -> ItineraryBasicInfoReceipt: ...

    def lookup(
        self,
        *,
        context: RequestContext,
        target_itinerary_id: UUID,
        idempotency_key: str,
    ) -> ItineraryBasicInfoReceipt | None: ...


class ItineraryBasicInfoCommandRequest(BaseModel):
    model_config = ConfigDict(extra="forbid", frozen=True)

    schema_version: Literal["1.0"]
    command_id: UUID
    expected_version: int
    patch: "ItineraryBasicInfoPatchRequest"


SafeBodyText = Annotated[
    str, StringConstraints(strip_whitespace=True, min_length=1, max_length=160)
]
SafeBodyTag = Annotated[
    str,
    StringConstraints(
        strip_whitespace=True,
        min_length=1,
        max_length=48,
        pattern=r"^[^\x00-\x1f\x7f]+$",
    ),
]


class ItineraryBasicInfoPatchRequest(BaseModel):
    model_config = ConfigDict(extra="forbid", frozen=True)

    title: SafeBodyText
    destination: SafeBodyText
    start_date: date
    end_date: date
    budget: Decimal = Field(ge=0, max_digits=12, decimal_places=2)
    actual_cost: Decimal = Field(ge=0, max_digits=12, decimal_places=2)
    tags: tuple[SafeBodyTag, ...] = Field(max_length=16)


class ItineraryBasicInfoReceiptLookupResponse(BaseModel):
    model_config = ConfigDict(extra="forbid", frozen=True)

    receipt: ItineraryBasicInfoReceipt | None


def create_itinerary_commands_router(
    service: ItineraryBasicInfoCommandExecutor,
    context_resolver: ContextResolver,
    *,
    enabled: bool,
) -> APIRouter:
    router = APIRouter(
        prefix="/v1/itineraries/{itinerary_id}/commands/basic-info",
        tags=["itinerary-domain-command"],
    )

    @router.post("", response_model=ItineraryBasicInfoReceipt)
    async def update_itinerary_basic_info(
        itinerary_id: UUID,
        body: ItineraryBasicInfoCommandRequest,
        request: Request,
        idempotency_key: Annotated[
            str,
            Header(
                alias="Idempotency-Key",
                min_length=16,
                max_length=128,
                pattern=r"^[A-Za-z0-9][A-Za-z0-9_.:/-]+$",
            ),
        ],
    ) -> ItineraryBasicInfoReceipt:
        if not enabled:
            raise HTTPException(status_code=503, detail="service.unavailable")
        try:
            context = await resolve_request_context(context_resolver, request)
            command = UpdateItineraryBasicInfoCommand(
                schema_version=body.schema_version,
                command_id=body.command_id,
                idempotency_key=idempotency_key,
                target_itinerary_id=itinerary_id,
                expected_version=body.expected_version,
                patch=ItineraryBasicInfoPatch(**body.patch.model_dump(mode="python")),
            )
            return await run_in_threadpool(
                service.execute,
                context=context,
                command=command,
            )
        except (AuthorizationForbidden, DomainCommandTargetDenied) as error:
            raise HTTPException(status_code=403, detail="auth.forbidden") from error
        except DomainCommandIdempotencyConflict as error:
            raise HTTPException(status_code=409, detail="idempotency.conflict") from error
        except DomainCommandPersistenceError as error:
            raise HTTPException(status_code=503, detail="service.unavailable") from error

    @router.get("", response_model=ItineraryBasicInfoReceiptLookupResponse)
    async def lookup_itinerary_basic_info_receipt(
        itinerary_id: UUID,
        request: Request,
        idempotency_key: Annotated[
            str,
            Header(
                alias="Idempotency-Key",
                min_length=16,
                max_length=128,
                pattern=r"^[A-Za-z0-9][A-Za-z0-9_.:/-]+$",
            ),
        ],
    ) -> ItineraryBasicInfoReceiptLookupResponse:
        if not enabled:
            raise HTTPException(status_code=503, detail="service.unavailable")
        context = await resolve_request_context(context_resolver, request)
        receipt = await run_in_threadpool(
            service.lookup,
            context=context,
            target_itinerary_id=itinerary_id,
            idempotency_key=idempotency_key,
        )
        return ItineraryBasicInfoReceiptLookupResponse(receipt=receipt)

    return router
