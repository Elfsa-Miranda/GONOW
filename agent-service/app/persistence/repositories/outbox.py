"""Transaction-owned outbox enqueue, claim, receipt, retry, and DLQ operations."""

from __future__ import annotations

import hashlib
import re
import uuid
from dataclasses import dataclass
from datetime import datetime, timedelta

from sqlalchemy import and_, func, or_, select
from sqlalchemy.orm import Session

from app.persistence.models.outbox import (
    DeadLetterRecord,
    DeliveryReceiptRecord,
    OutboxMessageRecord,
)
from app.persistence.models.runtime import EventRecord
from app.persistence.repositories.runs import RuntimeRecordNotFound, TransactionRequired
from app.runtime.behavior_manifest import canonicalize_jcs


NAME_PATTERN = re.compile(r"^[a-z][a-z0-9_.-]{0,126}$")
FAILURE_CLASSES = frozenset({"transient", "permanent", "unknown_outcome"})


class OutboxClaimConflict(RuntimeError):
    code = "outbox.claim_conflict"

    def __init__(self) -> None:
        super().__init__(self.code)


@dataclass(frozen=True, slots=True)
class DeliveryReceiptResult:
    receipt: DeliveryReceiptRecord
    created: bool


class OutboxRepository:
    def __init__(self, session: Session) -> None:
        self._session = session

    def _require_transaction(self) -> None:
        if not self._session.in_transaction():
            raise TransactionRequired()

    def enqueue_event(
        self,
        *,
        tenant_id: str,
        event_id: uuid.UUID,
        topic: str,
        audit_receipt_id: str,
        max_attempts: int = 5,
    ) -> OutboxMessageRecord:
        self._require_transaction()
        if (
            not tenant_id
            or not audit_receipt_id
            or NAME_PATTERN.fullmatch(topic) is None
            or not 1 <= max_attempts <= 100
        ):
            raise ValueError("outbox enqueue boundary is invalid")
        event = self._session.execute(
            select(EventRecord).where(
                EventRecord.event_id == event_id,
                EventRecord.tenant_id == tenant_id,
            )
        ).scalar_one_or_none()
        if event is None:
            raise RuntimeRecordNotFound()
        payload_digest = hashlib.sha256(canonicalize_jcs(event.payload)).hexdigest()
        record = OutboxMessageRecord(
            outbox_id=uuid.uuid4(),
            event_id=event.event_id,
            tenant_id=tenant_id,
            topic=topic,
            payload_reference=f"runtime-event://{event.event_id}",
            payload_digest=payload_digest,
            status="pending",
            attempt_count=0,
            max_attempts=max_attempts,
            available_at=func.statement_timestamp(),
            claim_token=None,
            claimed_by=None,
            claimed_until=None,
            last_error_code=None,
            audit_receipt_id=audit_receipt_id,
            delivered_at=None,
        )
        self._session.add(record)
        self._session.flush()
        return record

    def claim_pending(
        self,
        *,
        dispatcher_id: str,
        lease_seconds: int,
        limit: int = 10,
    ) -> tuple[OutboxMessageRecord, ...]:
        self._require_transaction()
        if not dispatcher_id or not 1 <= lease_seconds <= 300 or not 1 <= limit <= 100:
            raise ValueError("outbox claim boundary is invalid")
        now = func.statement_timestamp()
        records = tuple(
            self._session.execute(
                select(OutboxMessageRecord)
                .where(
                    or_(
                        and_(
                            OutboxMessageRecord.status == "pending",
                            OutboxMessageRecord.available_at <= now,
                        ),
                        and_(
                            OutboxMessageRecord.status == "claimed",
                            OutboxMessageRecord.claimed_until < now,
                        ),
                    ),
                    OutboxMessageRecord.attempt_count < OutboxMessageRecord.max_attempts,
                )
                .order_by(OutboxMessageRecord.available_at, OutboxMessageRecord.created_at)
                .limit(limit)
                .with_for_update(skip_locked=True)
            ).scalars()
        )
        database_now = self._session.execute(select(func.statement_timestamp())).scalar_one()
        for record in records:
            record.status = "claimed"
            record.attempt_count += 1
            record.claim_token = uuid.uuid4()
            record.claimed_by = dispatcher_id
            record.claimed_until = database_now + timedelta(seconds=lease_seconds)
        self._session.flush()
        return records

    def record_delivery(
        self,
        *,
        tenant_id: str,
        outbox_id: uuid.UUID,
        claim_token: uuid.UUID,
        consumer_name: str,
        delivered_by: str,
        audit_receipt_id: str,
    ) -> DeliveryReceiptResult:
        self._require_transaction()
        if (
            NAME_PATTERN.fullmatch(consumer_name) is None
            or not delivered_by
            or not audit_receipt_id
        ):
            raise ValueError("delivery receipt boundary is invalid")
        message = self._session.execute(
            select(OutboxMessageRecord)
            .where(
                OutboxMessageRecord.outbox_id == outbox_id,
                OutboxMessageRecord.tenant_id == tenant_id,
            )
            .with_for_update()
        ).scalar_one_or_none()
        if message is None:
            raise RuntimeRecordNotFound()
        existing = self._session.execute(
            select(DeliveryReceiptRecord).where(
                DeliveryReceiptRecord.consumer_name == consumer_name,
                DeliveryReceiptRecord.event_id == message.event_id,
            )
        ).scalar_one_or_none()
        if existing is not None:
            return DeliveryReceiptResult(receipt=existing, created=False)
        if message.status != "claimed" or message.claim_token != claim_token:
            raise OutboxClaimConflict()
        receipt = DeliveryReceiptRecord(
            receipt_id=uuid.uuid4(),
            outbox_id=message.outbox_id,
            event_id=message.event_id,
            consumer_name=consumer_name,
            delivered_by=delivered_by,
            audit_receipt_id=audit_receipt_id,
        )
        self._session.add(receipt)
        message.status = "delivered"
        message.claim_token = None
        message.claimed_by = None
        message.claimed_until = None
        message.delivered_at = func.statement_timestamp()
        self._session.flush()
        return DeliveryReceiptResult(receipt=receipt, created=True)

    def record_failure(
        self,
        *,
        tenant_id: str,
        outbox_id: uuid.UUID,
        claim_token: uuid.UUID,
        retry_class: str,
        reason_code: str,
        audit_receipt_id: str,
        retry_at: datetime | None = None,
    ) -> DeadLetterRecord | None:
        self._require_transaction()
        if (
            retry_class not in FAILURE_CLASSES
            or NAME_PATTERN.fullmatch(reason_code) is None
            or not audit_receipt_id
        ):
            raise ValueError("outbox failure boundary is invalid")
        message = self._session.execute(
            select(OutboxMessageRecord)
            .where(
                OutboxMessageRecord.outbox_id == outbox_id,
                OutboxMessageRecord.tenant_id == tenant_id,
            )
            .with_for_update()
        ).scalar_one_or_none()
        if (
            message is None
            or message.status != "claimed"
            or message.claim_token != claim_token
        ):
            raise OutboxClaimConflict()
        message.last_error_code = reason_code
        message.claim_token = None
        message.claimed_by = None
        message.claimed_until = None
        if retry_class == "transient" and message.attempt_count < message.max_attempts:
            if retry_at is None:
                raise ValueError("transient retry requires retry_at")
            message.status = "pending"
            message.available_at = retry_at
            self._session.flush()
            return None

        terminal_class = (
            "exhausted"
            if retry_class == "transient" and message.attempt_count >= message.max_attempts
            else retry_class
        )
        dead_letter = DeadLetterRecord(
            dead_letter_id=uuid.uuid4(),
            outbox_id=message.outbox_id,
            event_id=message.event_id,
            retry_class=terminal_class,
            reason_code=reason_code,
            attempt_count=message.attempt_count,
            audit_receipt_id=audit_receipt_id,
        )
        self._session.add(dead_letter)
        message.status = "dead_letter"
        self._session.flush()
        return dead_letter
