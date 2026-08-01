"""PostgreSQL-serialized event writing and replay."""

from __future__ import annotations

import uuid
from typing import Any

from sqlalchemy import select
from sqlalchemy.exc import IntegrityError
from sqlalchemy.orm import Session

from app.persistence.models.runtime import (
    EventRecord,
    RunRecord,
    RunState,
    TERMINAL_RUN_STATES,
)
from app.persistence.repositories.runs import RuntimeRecordNotFound, TransactionRequired


class AuditReceiptRequired(RuntimeError):
    code = "audit.receipt_required"

    def __init__(self) -> None:
        super().__init__(self.code)


class RunTerminal(RuntimeError):
    code = "run.terminal"

    def __init__(self) -> None:
        super().__init__(self.code)


class EventSequenceConflict(RuntimeError):
    """Stable error for a database uniqueness race while allocating an event."""

    code = "event.sequence_conflict"

    def __init__(self) -> None:
        super().__init__(self.code)


class EventsRepository:
    """Use the Run row as the per-Run serialization point for event sequence."""

    def __init__(self, session: Session) -> None:
        self._session = session

    def _require_transaction(self) -> None:
        if not self._session.in_transaction():
            raise TransactionRequired()

    def append(
        self,
        *,
        tenant_id: str,
        run_id: uuid.UUID,
        event_type: str,
        payload: dict[str, Any],
        audit_receipt_id: str,
        event_id: uuid.UUID | None = None,
    ) -> EventRecord:
        self._require_transaction()
        if not audit_receipt_id:
            raise AuditReceiptRequired()
        run = self._session.execute(
            select(RunRecord)
            .where(RunRecord.run_id == run_id, RunRecord.tenant_id == tenant_id)
            .with_for_update()
        ).scalar_one_or_none()
        if run is None:
            raise RuntimeRecordNotFound()
        if RunState(run.state) in TERMINAL_RUN_STATES:
            raise RunTerminal()
        event = EventRecord(
            event_id=event_id or uuid.uuid4(),
            run_id=run_id,
            tenant_id=tenant_id,
            seq=run.next_event_seq,
            event_type=event_type,
            payload=payload,
            audit_receipt_id=audit_receipt_id,
        )
        run.next_event_seq += 1
        self._session.add(event)
        try:
            self._session.flush()
        except IntegrityError as error:
            raise EventSequenceConflict() from error
        return event

    def replay_after(
        self,
        *,
        tenant_id: str,
        run_id: uuid.UUID,
        last_event_id: int,
        limit: int = 100,
    ) -> tuple[EventRecord, ...]:
        self._require_transaction()
        if last_event_id < 0 or limit < 1 or limit > 1000:
            raise ValueError("invalid replay boundary")
        records = self._session.execute(
            select(EventRecord)
            .where(
                EventRecord.run_id == run_id,
                EventRecord.tenant_id == tenant_id,
                EventRecord.seq > last_event_id,
            )
            .order_by(EventRecord.seq)
            .limit(limit)
        ).scalars()
        return tuple(records)
