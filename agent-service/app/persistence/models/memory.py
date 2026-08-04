"""SQLAlchemy metadata for tenant-isolated Structured Memory storage."""

from __future__ import annotations

import uuid
from datetime import datetime

from sqlalchemy import BigInteger, Boolean, CheckConstraint, DateTime, Index, String, UniqueConstraint, func
from sqlalchemy.dialects.postgresql import JSONB, UUID
from sqlalchemy.orm import Mapped, mapped_column

from app.persistence.models.runtime import RuntimeBase


MEMORY_SCHEMA = "agent_memory"


class MemoryRecordRow(RuntimeBase):
    __tablename__ = "records"
    __table_args__ = (
        UniqueConstraint("tenant_id", "principal_id", "purpose", "memory_type", name="uq_memory_active_slot"),
        CheckConstraint("purpose = 'itinerary.personalization'", name="ck_memory_purpose"),
        CheckConstraint("memory_type IN ('travel_pace','mobility_requirement','dietary_requirement','transport_preference')", name="ck_memory_type"),
        CheckConstraint("state IN ('active','conflicted','superseded','revoked','deleted','quarantined')", name="ck_memory_state"),
        CheckConstraint("version >= 1 AND consent_version >= 1 AND deletion_generation >= 0", name="ck_memory_versions"),
        Index("ix_memory_records_authorized_read", "tenant_id", "principal_id", "purpose", "state"),
        {"schema": MEMORY_SCHEMA},
    )
    memory_id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), primary_key=True)
    tenant_id: Mapped[str] = mapped_column(String(128), nullable=False)
    principal_id: Mapped[str] = mapped_column(String(256), nullable=False)
    purpose: Mapped[str] = mapped_column(String(64), nullable=False)
    memory_type: Mapped[str] = mapped_column(String(32), nullable=False)
    enum_value: Mapped[str] = mapped_column(String(32), nullable=False)
    state: Mapped[str] = mapped_column(String(16), nullable=False)
    version: Mapped[int] = mapped_column(BigInteger, nullable=False)
    consent_version: Mapped[int] = mapped_column(BigInteger, nullable=False)
    provenance: Mapped[dict] = mapped_column(JSONB, nullable=False)
    retention_until: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)
    deletion_generation: Mapped[int] = mapped_column(BigInteger, nullable=False, server_default="0")
    updated_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False, server_default=func.statement_timestamp())


class MemoryCandidateRow(RuntimeBase):
    __tablename__ = "candidates"
    __table_args__ = (
        CheckConstraint("state IN ('proposed','confirmed','rejected','deleted')", name="ck_memory_candidate_state"),
        Index("ix_memory_candidates_owner", "tenant_id", "principal_id", "state"),
        {"schema": MEMORY_SCHEMA},
    )
    candidate_id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), primary_key=True)
    tenant_id: Mapped[str] = mapped_column(String(128), nullable=False)
    principal_id: Mapped[str] = mapped_column(String(256), nullable=False)
    payload: Mapped[dict] = mapped_column(JSONB, nullable=False)
    state: Mapped[str] = mapped_column(String(16), nullable=False)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False, server_default=func.statement_timestamp())


class MemoryConsentRow(RuntimeBase):
    __tablename__ = "consent_events"
    __table_args__ = (UniqueConstraint("tenant_id", "principal_id", "purpose", "version", name="uq_memory_consent_version"), {"schema": MEMORY_SCHEMA})
    consent_event_id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), primary_key=True)
    tenant_id: Mapped[str] = mapped_column(String(128), nullable=False)
    principal_id: Mapped[str] = mapped_column(String(256), nullable=False)
    purpose: Mapped[str] = mapped_column(String(64), nullable=False)
    state: Mapped[str] = mapped_column(String(16), nullable=False)
    version: Mapped[int] = mapped_column(BigInteger, nullable=False)
    valid_until: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False, server_default=func.statement_timestamp())


class MemoryDerivativeRow(RuntimeBase):
    __tablename__ = "derivatives"
    __table_args__ = (UniqueConstraint("tenant_id", "memory_id", "surface", name="uq_memory_derivative_surface"), {"schema": MEMORY_SCHEMA})
    derivative_id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), primary_key=True)
    memory_id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), nullable=False)
    tenant_id: Mapped[str] = mapped_column(String(128), nullable=False)
    surface: Mapped[str] = mapped_column(String(16), nullable=False)
    digest: Mapped[str] = mapped_column(String(64), nullable=False)
    deleted: Mapped[bool] = mapped_column(Boolean, nullable=False, server_default="false")


class MemoryTombstoneRow(RuntimeBase):
    __tablename__ = "tombstones"
    __table_args__ = (UniqueConstraint("tenant_id", "memory_id", name="uq_memory_tombstone"), {"schema": MEMORY_SCHEMA})
    tombstone_id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), primary_key=True)
    memory_id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), nullable=False)
    tenant_id: Mapped[str] = mapped_column(String(128), nullable=False)
    principal_id: Mapped[str] = mapped_column(String(256), nullable=False)
    deletion_generation: Mapped[int] = mapped_column(BigInteger, nullable=False)
    reason_code: Mapped[str] = mapped_column(String(32), nullable=False)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False, server_default=func.statement_timestamp())
