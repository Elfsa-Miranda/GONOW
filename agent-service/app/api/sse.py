"""Bounded, replay-first Server-Sent Events transport."""

from __future__ import annotations

import asyncio
from collections.abc import AsyncIterator, Awaitable, Callable
from dataclasses import dataclass
import json
import re
import uuid

from app.runtime.event_writer import EventWriter, PersistentEvent


ALLOWED_BUSINESS_EVENTS = frozenset(
    {
        "run_created",
        "run_queued",
        "step_started",
        "step_completed",
        "tool_called",
        "tool_result",
        "candidate_ready",
        "waiting_input",
        "resuming",
        "recovering",
        "cancelling",
        "cancelled",
        "succeeded",
        "blocked",
        "failed",
    }
)
_DECIMAL_EVENT_ID = re.compile(r"^[0-9]+$")


class LastEventIdInvalid(ValueError):
    code = "sse.last_event_id_invalid"

    def __init__(self) -> None:
        super().__init__(self.code)


class SseSlowConsumer(RuntimeError):
    code = "sse.slow_consumer"

    def __init__(self) -> None:
        super().__init__(self.code)


class SseEventTypeInvalid(ValueError):
    code = "sse.event_type_invalid"

    def __init__(self) -> None:
        super().__init__(self.code)


@dataclass(frozen=True, slots=True)
class SseFrame:
    event: str
    data: str
    event_id: int | None

    def encode(self) -> str:
        event_id = "" if self.event_id is None else f"id: {self.event_id}\n"
        return f"event: {self.event}\n{event_id}data: {self.data}\n\n"


def parse_last_event_id(value: str | None) -> int:
    if value is None or value == "":
        return 0
    if _DECIMAL_EVENT_ID.fullmatch(value) is None:
        raise LastEventIdInvalid()
    parsed = int(value)
    if parsed < 0 or parsed > 9_223_372_036_854_775_807:
        raise LastEventIdInvalid()
    return parsed


def business_frame(event: PersistentEvent) -> SseFrame:
    wire_event = event.event_type.replace(".", "_").replace("-", "_")
    if wire_event not in ALLOWED_BUSINESS_EVENTS:
        raise SseEventTypeInvalid()
    return SseFrame(
        event=wire_event,
        event_id=event.seq,
        data=json.dumps(
            event.payload,
            allow_nan=False,
            ensure_ascii=False,
            separators=(",", ":"),
            sort_keys=True,
        ),
    )


def heartbeat_frame() -> SseFrame:
    return SseFrame(event="heartbeat", event_id=None, data="{}")


class SseReplayService:
    """Replay durable rows before polling live rows with a bounded backlog."""

    def __init__(
        self,
        writer: EventWriter,
        *,
        heartbeat_interval_seconds: float = 20.0,
        buffer_capacity: int = 128,
    ) -> None:
        if heartbeat_interval_seconds < 0 or not 1 <= buffer_capacity <= 999:
            raise ValueError("sse.invalid_configuration")
        self._writer = writer
        self._heartbeat_interval_seconds = heartbeat_interval_seconds
        self._buffer_capacity = buffer_capacity

    def replay_once(
        self,
        *,
        tenant_id: str,
        run_id: uuid.UUID,
        last_event_id: int,
    ) -> tuple[SseFrame, ...]:
        events = self._writer.replay_after(
            tenant_id=tenant_id,
            run_id=run_id,
            last_event_id=last_event_id,
            limit=self._buffer_capacity + 1,
        )
        if len(events) > self._buffer_capacity:
            raise SseSlowConsumer()
        return tuple(business_frame(event) for event in events)

    async def stream(
        self,
        *,
        tenant_id: str,
        run_id: uuid.UUID,
        last_event_id: int,
        disconnected: Callable[[], Awaitable[bool]],
    ) -> AsyncIterator[str]:
        cursor = last_event_id
        initial = self.replay_once(
            tenant_id=tenant_id,
            run_id=run_id,
            last_event_id=cursor,
        )
        for frame in initial:
            cursor = frame.event_id or cursor
            yield frame.encode()
        while not await disconnected():
            await asyncio.sleep(self._heartbeat_interval_seconds)
            live = self.replay_once(
                tenant_id=tenant_id,
                run_id=run_id,
                last_event_id=cursor,
            )
            if live:
                for frame in live:
                    cursor = frame.event_id or cursor
                    yield frame.encode()
            else:
                yield heartbeat_frame().encode()
