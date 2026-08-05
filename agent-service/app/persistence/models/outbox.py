"""Transactional outbox, consumer receipts, and metadata-only dead letters."""

from __future__ import annotations

import uuid
from datetime import datetime

from sqlalchemy import (
    BigInteger,
    CheckConstraint,
    DateTime,
    ForeignKey,
    Index,
    String,
    UniqueConstraint,
    func,
)
from sqlalchemy.dialects.postgresql import UUID
from sqlalchemy.orm import Mapped, mapped_column

from app.persistence.models.runtime import RUNTIME_SCHEMA, RuntimeBase


class OutboxMessageRecord(RuntimeBase):
    __tablename__ = "outbox_messages"
    __table_args__ = (
        UniqueConstraint("event_id", "topic", name="uq_outbox_event_topic"),
        CheckConstraint(
            "status IN ('pending','claimed','delivered','dead_letter')",
            name="ck_outbox_status",
        ),
        CheckConstraint("attempt_count >= 0", name="ck_outbox_attempt_nonnegative"),
        CheckConstraint("max_attempts BETWEEN 1 AND 100", name="ck_outbox_max_attempts"),
        CheckConstraint(
            "payload_digest ~ '^[0-9a-f]{64}$'",
            name="ck_outbox_payload_digest",
        ),
        CheckConstraint(
            "payload_reference ~ '^runtime-event://[0-9a-f-]{36}$'",
            name="ck_outbox_payload_reference",
        ),
        CheckConstraint(
            "topic ~ '^[a-z][a-z0-9_.-]{0,126}$'",
            name="ck_outbox_topic",
        ),
        CheckConstraint(
            "length(tenant_id) > 0 AND length(audit_receipt_id) > 0",
            name="ck_outbox_audit",
        ),
        CheckConstraint(
            "(status = 'claimed' AND claim_token IS NOT NULL AND claimed_by IS NOT NULL "
            "AND claimed_until IS NOT NULL) OR "
            "(status <> 'claimed' AND claim_token IS NULL AND claimed_by IS NULL "
            "AND claimed_until IS NULL)",
            name="ck_outbox_claim_shape",
        ),
        CheckConstraint(
            "(status = 'delivered' AND delivered_at IS NOT NULL) OR "
            "(status <> 'delivered' AND delivered_at IS NULL)",
            name="ck_outbox_delivery_shape",
        ),
        Index("ix_outbox_claim", "status", "available_at", "created_at"),
        Index("ix_outbox_tenant_event", "tenant_id", "event_id"),
        {"schema": RUNTIME_SCHEMA},
    )

    outbox_id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), primary_key=True)
    event_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True),
        ForeignKey(f"{RUNTIME_SCHEMA}.events.event_id", ondelete="CASCADE"),
        nullable=False,
    )
    tenant_id: Mapped[str] = mapped_column(String(128), nullable=False)
    topic: Mapped[str] = mapped_column(String(127), nullable=False)
    payload_reference: Mapped[str] = mapped_column(String(64), nullable=False)
    payload_digest: Mapped[str] = mapped_column(String(64), nullable=False)
    status: Mapped[str] = mapped_column(String(16), nullable=False)
    attempt_count: Mapped[int] = mapped_column(BigInteger, nullable=False, default=0)
    max_attempts: Mapped[int] = mapped_column(BigInteger, nullable=False)
    available_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)
    claim_token: Mapped[uuid.UUID | None] = mapped_column(UUID(as_uuid=True), nullable=True)
    claimed_by: Mapped[str | None] = mapped_column(String(128), nullable=True)
    claimed_until: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    last_error_code: Mapped[str | None] = mapped_column(String(127), nullable=True)
    audit_receipt_id: Mapped[str] = mapped_column(String(128), nullable=False)
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False, server_default=func.statement_timestamp()
    )
    delivered_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)


class DeliveryReceiptRecord(RuntimeBase):
    __tablename__ = "delivery_receipts"
    __table_args__ = (
        UniqueConstraint("consumer_name", "event_id", name="uq_delivery_consumer_event"),
        CheckConstraint(
            "consumer_name ~ '^[a-z][a-z0-9_.-]{0,126}$'",
            name="ck_delivery_consumer",
        ),
        CheckConstraint(
            "length(delivered_by) > 0 AND length(audit_receipt_id) > 0",
            name="ck_delivery_audit",
        ),
        Index("ix_delivery_outbox", "outbox_id"),
        {"schema": RUNTIME_SCHEMA},
    )

    receipt_id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), primary_key=True)
    outbox_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True),
        ForeignKey(f"{RUNTIME_SCHEMA}.outbox_messages.outbox_id", ondelete="RESTRICT"),
        nullable=False,
    )
    event_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True),
        ForeignKey(f"{RUNTIME_SCHEMA}.events.event_id", ondelete="RESTRICT"),
        nullable=False,
    )
    consumer_name: Mapped[str] = mapped_column(String(127), nullable=False)
    delivered_by: Mapped[str] = mapped_column(String(128), nullable=False)
    audit_receipt_id: Mapped[str] = mapped_column(String(128), nullable=False)
    delivered_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False, server_default=func.statement_timestamp()
    )


class DeadLetterRecord(RuntimeBase):
    __tablename__ = "dead_letters"
    __table_args__ = (
        UniqueConstraint("outbox_id", name="uq_dead_letter_outbox"),
        CheckConstraint(
            "retry_class IN ('permanent','exhausted','unknown_outcome')",
            name="ck_dead_letter_retry_class",
        ),
        CheckConstraint(
            "reason_code ~ '^[a-z][a-z0-9_.-]{0,126}$'",
            name="ck_dead_letter_reason",
        ),
        CheckConstraint(
            "attempt_count >= 1 AND length(audit_receipt_id) > 0",
            name="ck_dead_letter_audit",
        ),
        Index("ix_dead_letter_event", "event_id"),
        {"schema": RUNTIME_SCHEMA},
    )

    dead_letter_id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), primary_key=True)
    outbox_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True),
        ForeignKey(f"{RUNTIME_SCHEMA}.outbox_messages.outbox_id", ondelete="RESTRICT"),
        nullable=False,
    )
    event_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True),
        ForeignKey(f"{RUNTIME_SCHEMA}.events.event_id", ondelete="RESTRICT"),
        nullable=False,
    )
    retry_class: Mapped[str] = mapped_column(String(32), nullable=False)
    reason_code: Mapped[str] = mapped_column(String(127), nullable=False)
    attempt_count: Mapped[int] = mapped_column(BigInteger, nullable=False)
    audit_receipt_id: Mapped[str] = mapped_column(String(128), nullable=False)
    moved_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False, server_default=func.statement_timestamp()
    )
