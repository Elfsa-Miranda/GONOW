"""Authenticated Run event stream route factory."""

from __future__ import annotations

from collections.abc import Callable
from typing import Annotated
import uuid

from fastapi import APIRouter, Header, HTTPException, Request
from fastapi.responses import StreamingResponse

from app.api.sse import LastEventIdInvalid, SseReplayService, parse_last_event_id
from app.auth.context import AuthorizationPolicy, RequestContext
from app.runtime.event_writer import EventWriter


ContextResolver = Callable[[Request], RequestContext]


def create_events_router(
    writer: EventWriter,
    context_resolver: ContextResolver,
    *,
    heartbeat_interval_seconds: float = 20.0,
    buffer_capacity: int = 128,
) -> APIRouter:
    service = SseReplayService(
        writer,
        heartbeat_interval_seconds=heartbeat_interval_seconds,
        buffer_capacity=buffer_capacity,
    )
    policy = AuthorizationPolicy()
    router = APIRouter(prefix="/v1/runs", tags=["run-events"])

    @router.get("/{run_id}/events", response_class=StreamingResponse)
    async def stream_run_events(
        run_id: uuid.UUID,
        request: Request,
        last_event_id: Annotated[str | None, Header(alias="Last-Event-ID")] = None,
    ) -> StreamingResponse:
        context = context_resolver(request)
        policy.authorize(
            context,
            action="run.events.read",
            resource_tenant_id=context.tenant_id,
        )
        try:
            cursor = parse_last_event_id(last_event_id)
        except LastEventIdInvalid as error:
            raise HTTPException(status_code=400, detail=error.code) from error
        return StreamingResponse(
            service.stream(
                tenant_id=context.tenant_id,
                run_id=run_id,
                last_event_id=cursor,
                disconnected=request.is_disconnected,
            ),
            media_type="text/event-stream",
            headers={
                "Cache-Control": "no-cache, no-transform",
                "Connection": "keep-alive",
                "X-Accel-Buffering": "no",
            },
        )

    return router
