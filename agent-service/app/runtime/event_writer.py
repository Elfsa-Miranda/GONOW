"""Commit-first event writer for durable Run event streams."""

from __future__ import annotations

from collections.abc import Callable
from dataclasses import dataclass, field
from datetime import datetime
import json
import math
import re
from typing import Any
import uuid

from sqlalchemy import func, select
from sqlalchemy.orm import Session, sessionmaker

from app.persistence.models.runtime import EventRecord
from app.persistence.repositories.events import EventsRepository


MAX_EVENT_PAYLOAD_BYTES = 65_536
_FORBIDDEN_KEY_PARTS = (
    "access_token",
    "api_key",
    "authorization",
    "credential",
    "prompt",
    "raw_body",
    "reasoning",
    "refresh_token",
    "secret",
    "transcript",
)
_SECRET_CANARY = re.compile(
    r"(?i)(sk-[a-z0-9]{16,}|github_pat_[a-z0-9_]+|-----BEGIN [A-Z ]*PRIVATE KEY-----)"
)


class UnsafeEventPayload(ValueError):
    code = "event.unsafe_payload"

    def __init__(self) -> None:
        super().__init__(self.code)


@dataclass(frozen=True, slots=True)
class PersistentEvent:
    event_id: uuid.UUID
    run_id: uuid.UUID
    seq: int
    event_type: str
    payload: dict[str, Any]
    audit_receipt_id: str
    created_at: datetime


@dataclass(frozen=True, slots=True)
class TransientHeartbeat:
    event_type: str = "heartbeat"
    data: dict[str, Any] = field(default_factory=dict)
    seq: None = None


def _normalize_payload(value: Any, *, depth: int = 0) -> Any:
    if depth > 12:
        raise UnsafeEventPayload()
    if value is None or isinstance(value, (bool, int)):
        return value
    if isinstance(value, float):
        if not math.isfinite(value):
            raise UnsafeEventPayload()
        return value
    if isinstance(value, str):
        if _SECRET_CANARY.search(value):
            raise UnsafeEventPayload()
        return value
    if isinstance(value, (list, tuple)):
        return [_normalize_payload(item, depth=depth + 1) for item in value]
    if isinstance(value, dict):
        normalized: dict[str, Any] = {}
        for key, item in value.items():
            if not isinstance(key, str):
                raise UnsafeEventPayload()
            lowered = key.casefold()
            if any(part in lowered for part in _FORBIDDEN_KEY_PARTS):
                raise UnsafeEventPayload()
            normalized[key] = _normalize_payload(item, depth=depth + 1)
        return normalized
    raise UnsafeEventPayload()


def _safe_payload(payload: dict[str, Any]) -> dict[str, Any]:
    normalized = _normalize_payload(payload)
    if not isinstance(normalized, dict):
        raise UnsafeEventPayload()
    encoded = json.dumps(
        normalized,
        allow_nan=False,
        ensure_ascii=False,
        separators=(",", ":"),
        sort_keys=True,
    ).encode("utf-8")
    if len(encoded) > MAX_EVENT_PAYLOAD_BYTES:
        raise UnsafeEventPayload()
    return normalized


def _persistent(record: EventRecord) -> PersistentEvent:
    return PersistentEvent(
        event_id=record.event_id,
        run_id=record.run_id,
        seq=record.seq,
        event_type=record.event_type,
        payload=record.payload,
        audit_receipt_id=record.audit_receipt_id,
        created_at=record.created_at,
    )


class EventWriter:
    """Allocate and append under the Run row lock, then notify after commit."""

    def __init__(
        self,
        session_factory: sessionmaker[Session],
        *,
        after_commit: Callable[[PersistentEvent], None] | None = None,
    ) -> None:
        self._session_factory = session_factory
        self._after_commit = after_commit

    @staticmethod
    def heartbeat() -> TransientHeartbeat:
        """Return a transport-only heartbeat; it never allocates a business seq."""

        return TransientHeartbeat()

    def append(
        self,
        *,
        tenant_id: str,
        run_id: uuid.UUID,
        event_type: str,
        payload: dict[str, Any],
        audit_receipt_id: str,
        event_id: uuid.UUID | None = None,
    ) -> PersistentEvent:
        normalized = _safe_payload(payload)
        with self._session_factory.begin() as session:
            session.execute(select(func.set_config("app.tenant_id", tenant_id, True)))
            record = EventsRepository(session).append(
                tenant_id=tenant_id,
                run_id=run_id,
                event_type=event_type,
                payload=normalized,
                audit_receipt_id=audit_receipt_id,
                event_id=event_id,
            )
            result = _persistent(record)
        if self._after_commit is not None:
            self._after_commit(result)
        return result

    def replay_after(
        self,
        *,
        tenant_id: str,
        run_id: uuid.UUID,
        last_event_id: int,
        limit: int = 100,
    ) -> tuple[PersistentEvent, ...]:
        with self._session_factory.begin() as session:
            session.execute(select(func.set_config("app.tenant_id", tenant_id, True)))
            records = EventsRepository(session).replay_after(
                tenant_id=tenant_id,
                run_id=run_id,
                last_event_id=last_event_id,
                limit=limit,
            )
            return tuple(_persistent(record) for record in records)
