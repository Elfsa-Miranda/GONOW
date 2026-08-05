"""Typed SQLAlchemy models for the PostgreSQL runtime control plane."""

from __future__ import annotations

import enum
import uuid
from datetime import datetime
from typing import Any

from sqlalchemy import (
    BigInteger,
    CheckConstraint,
    DateTime,
    ForeignKeyConstraint,
    Index,
    String,
    UniqueConstraint,
    func,
)
from sqlalchemy.dialects.postgresql import JSONB, UUID
from sqlalchemy.orm import DeclarativeBase, Mapped, mapped_column


RUNTIME_SCHEMA = "agent_runtime"


class RunState(str, enum.Enum):
    CREATED = "created"
    QUEUED = "queued"
    RUNNING = "running"
    WAITING_INPUT = "waiting_input"
    RESUMING = "resuming"
    RECOVERING = "recovering"
    CANCELLING = "cancelling"
    SUCCEEDED = "succeeded"
    BLOCKED = "blocked"
    FAILED = "failed"
    CANCELLED = "cancelled"


TERMINAL_RUN_STATES = frozenset(
    {RunState.SUCCEEDED, RunState.BLOCKED, RunState.FAILED, RunState.CANCELLED}
)


class RuntimeBase(DeclarativeBase):
    """Metadata root isolated from business and knowledge schemas."""


class ThreadRecord(RuntimeBase):
    __tablename__ = "threads"
    __table_args__ = (
        UniqueConstraint("thread_id", "tenant_id", name="uq_threads_id_tenant"),
        CheckConstraint("length(tenant_id) > 0", name="ck_threads_tenant_nonempty"),
        CheckConstraint(
            "length(owner_principal_id) > 0",
            name="ck_threads_owner_nonempty",
        ),
        Index("ix_threads_tenant_created", "tenant_id", "created_at"),
        {"schema": RUNTIME_SCHEMA},
    )

    thread_id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), primary_key=True)
    tenant_id: Mapped[str] = mapped_column(String(128), nullable=False)
    owner_principal_id: Mapped[str] = mapped_column(String(256), nullable=False)
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False, server_default=func.statement_timestamp()
    )


class RunRecord(RuntimeBase):
    __tablename__ = "runs"
    __table_args__ = (
        ForeignKeyConstraint(
            ["thread_id", "tenant_id"],
            [f"{RUNTIME_SCHEMA}.threads.thread_id", f"{RUNTIME_SCHEMA}.threads.tenant_id"],
            name="fk_runs_thread_tenant",
            ondelete="RESTRICT",
        ),
        UniqueConstraint("run_id", "tenant_id", name="uq_runs_id_tenant"),
        CheckConstraint(
            "state IN ('created','queued','running','waiting_input','resuming',"
            "'recovering','cancelling','succeeded','blocked','failed','cancelled')",
            name="ck_runs_state",
        ),
        CheckConstraint(
            "manifest_digest ~ '^[0-9a-f]{64}$'",
            name="ck_runs_manifest_digest",
        ),
        CheckConstraint("next_event_seq >= 1", name="ck_runs_next_event_seq"),
        CheckConstraint("version >= 0", name="ck_runs_version_nonnegative"),
        Index("ix_runs_tenant_thread_created", "tenant_id", "thread_id", "created_at"),
        {"schema": RUNTIME_SCHEMA},
    )

    run_id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), primary_key=True)
    thread_id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), nullable=False)
    tenant_id: Mapped[str] = mapped_column(String(128), nullable=False)
    principal_id: Mapped[str] = mapped_column(String(256), nullable=False)
    state: Mapped[str] = mapped_column(String(32), nullable=False)
    manifest_digest: Mapped[str] = mapped_column(String(64), nullable=False)
    manifest: Mapped[dict[str, Any]] = mapped_column(JSONB, nullable=False)
    next_event_seq: Mapped[int] = mapped_column(BigInteger, nullable=False, default=1)
    version: Mapped[int] = mapped_column(BigInteger, nullable=False, default=0)
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False, server_default=func.statement_timestamp()
    )
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False, server_default=func.statement_timestamp()
    )


class EventRecord(RuntimeBase):
    __tablename__ = "events"
    __table_args__ = (
        ForeignKeyConstraint(
            ["run_id", "tenant_id"],
            [f"{RUNTIME_SCHEMA}.runs.run_id", f"{RUNTIME_SCHEMA}.runs.tenant_id"],
            name="fk_events_run_tenant",
            ondelete="CASCADE",
        ),
        UniqueConstraint("run_id", "seq", name="uq_events_run_seq"),
        CheckConstraint("seq >= 1", name="ck_events_seq_positive"),
        CheckConstraint(
            "event_type ~ '^[a-z][a-z0-9_.-]{0,126}$'",
            name="ck_events_type",
        ),
        CheckConstraint(
            "length(audit_receipt_id) > 0",
            name="ck_events_audit_receipt_nonempty",
        ),
        Index("ix_events_run_replay", "run_id", "seq"),
        Index("ix_events_tenant_created", "tenant_id", "created_at"),
        {"schema": RUNTIME_SCHEMA},
    )

    event_id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), primary_key=True)
    run_id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), nullable=False)
    tenant_id: Mapped[str] = mapped_column(String(128), nullable=False)
    seq: Mapped[int] = mapped_column(BigInteger, nullable=False)
    event_type: Mapped[str] = mapped_column(String(127), nullable=False)
    payload: Mapped[dict[str, Any]] = mapped_column(JSONB, nullable=False)
    audit_receipt_id: Mapped[str] = mapped_column(String(128), nullable=False)
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False, server_default=func.statement_timestamp()
    )


class IdempotencyRecord(RuntimeBase):
    __tablename__ = "idempotency_records"
    __table_args__ = (
        ForeignKeyConstraint(
            ["run_id", "tenant_id"],
            [f"{RUNTIME_SCHEMA}.runs.run_id", f"{RUNTIME_SCHEMA}.runs.tenant_id"],
            name="fk_idempotency_run_tenant",
            ondelete="RESTRICT",
            deferrable=True,
            initially="DEFERRED",
        ),
        UniqueConstraint(
            "tenant_id",
            "principal_id",
            "request_scope",
            "idempotency_key",
            name="uq_idempotency_request_key",
        ),
        CheckConstraint(
            "request_hash ~ '^[0-9a-f]{64}$'",
            name="ck_idempotency_request_hash",
        ),
        CheckConstraint(
            "length(idempotency_key) > 0 AND length(request_scope) > 0",
            name="ck_idempotency_key_scope_nonempty",
        ),
        Index("ix_idempotency_run", "run_id"),
        {"schema": RUNTIME_SCHEMA},
    )

    idempotency_id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), primary_key=True)
    tenant_id: Mapped[str] = mapped_column(String(128), nullable=False)
    principal_id: Mapped[str] = mapped_column(String(256), nullable=False)
    request_scope: Mapped[str] = mapped_column(String(128), nullable=False)
    idempotency_key: Mapped[str] = mapped_column(String(128), nullable=False)
    request_hash: Mapped[str] = mapped_column(String(64), nullable=False)
    run_id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), nullable=False)
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False, server_default=func.statement_timestamp()
    )


class JobInputRecord(RuntimeBase):
    """Tenant-scoped, content-addressed structured input for one or more replayed Jobs."""

    __tablename__ = "job_inputs"
    __table_args__ = (
        UniqueConstraint("tenant_id", "input_ref", name="uq_job_inputs_tenant_ref"),
        CheckConstraint(
            "input_ref ~ '^job-input://sha256/[0-9a-f]{64}$'",
            name="ck_job_inputs_ref",
        ),
        CheckConstraint(
            "input_sha256 ~ '^[0-9a-f]{64}$'",
            name="ck_job_inputs_digest",
        ),
        CheckConstraint("schema_version = '1.0'", name="ck_job_inputs_schema_version"),
        Index("ix_job_inputs_tenant_created", "tenant_id", "created_at"),
        {"schema": RUNTIME_SCHEMA},
    )

    input_id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), primary_key=True)
    tenant_id: Mapped[str] = mapped_column(String(128), nullable=False)
    input_ref: Mapped[str] = mapped_column(String(96), nullable=False)
    input_sha256: Mapped[str] = mapped_column(String(64), nullable=False)
    schema_version: Mapped[str] = mapped_column(String(16), nullable=False)
    payload: Mapped[dict[str, Any]] = mapped_column(JSONB, nullable=False)
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False, server_default=func.statement_timestamp()
    )
    expires_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)
    deletion_requested_at: Mapped[datetime | None] = mapped_column(
        DateTime(timezone=True), nullable=True
    )


class ResumeCapabilityRow(RuntimeBase):
    """Persist only the digest and exact binding of a one-use resume capability."""

    __tablename__ = "resume_capabilities"
    __table_args__ = (
        ForeignKeyConstraint(
            ["run_id", "tenant_id"],
            [f"{RUNTIME_SCHEMA}.runs.run_id", f"{RUNTIME_SCHEMA}.runs.tenant_id"],
            name="fk_resume_capabilities_run_tenant",
            ondelete="CASCADE",
        ),
        UniqueConstraint("token_hash", name="uq_resume_capabilities_token_hash"),
        CheckConstraint(
            "token_hash ~ '^[0-9a-f]{64}$' AND command_hash ~ '^[0-9a-f]{64}$'",
            name="ck_resume_capabilities_hashes",
        ),
        CheckConstraint(
            "command_version ~ '^[0-9]+\\.[0-9]+$'",
            name="ck_resume_capabilities_command_version",
        ),
        CheckConstraint("expires_at > issued_at", name="ck_resume_capabilities_expiry"),
        Index(
            "ix_resume_capabilities_binding",
            "tenant_id",
            "principal_id",
            "run_id",
            "interrupt_id",
        ),
        {"schema": RUNTIME_SCHEMA},
    )

    capability_id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), primary_key=True)
    token_hash: Mapped[str] = mapped_column(String(64), nullable=False)
    nonce: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), nullable=False)
    tenant_id: Mapped[str] = mapped_column(String(128), nullable=False)
    principal_id: Mapped[str] = mapped_column(String(256), nullable=False)
    run_id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), nullable=False)
    interrupt_id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), nullable=False)
    command_hash: Mapped[str] = mapped_column(String(64), nullable=False)
    command_version: Mapped[str] = mapped_column(String(32), nullable=False)
    issued_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)
    expires_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)
    consumed_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)


class CandidateRecord(RuntimeBase):
    """A recoverable typed Candidate, separate from every formal itinerary table."""

    __tablename__ = "candidates"
    __table_args__ = (
        ForeignKeyConstraint(
            ["source_job_id", "tenant_id", "run_id"],
            [
                f"{RUNTIME_SCHEMA}.jobs.job_id",
                f"{RUNTIME_SCHEMA}.jobs.tenant_id",
                f"{RUNTIME_SCHEMA}.jobs.run_id",
            ],
            name="fk_candidates_job_tenant_run",
            ondelete="CASCADE",
        ),
        UniqueConstraint("tenant_id", "candidate_id", name="uq_candidates_tenant_id"),
        UniqueConstraint("tenant_id", "run_id", name="uq_candidates_tenant_run"),
        CheckConstraint(
            "candidate_id ~ '^cand_[0-9a-f]{32}$'",
            name="ck_candidates_public_id",
        ),
        CheckConstraint(
            "candidate_digest ~ '^[0-9a-f]{64}$' AND "
            "behavior_digest ~ '^[0-9a-f]{64}$' AND "
            "input_digest ~ '^[0-9a-f]{64}$'",
            name="ck_candidates_digests",
        ),
        CheckConstraint(
            "candidate_ref = 'candidate://sha256/' || candidate_digest",
            name="ck_candidates_ref",
        ),
        CheckConstraint("schema_version = '1.0'", name="ck_candidates_schema_version"),
        CheckConstraint("fencing_token > 0", name="ck_candidates_fence_positive"),
        Index("ix_candidates_tenant_created", "tenant_id", "created_at"),
        {"schema": RUNTIME_SCHEMA},
    )

    candidate_record_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), primary_key=True
    )
    candidate_id: Mapped[str] = mapped_column(String(37), nullable=False)
    candidate_ref: Mapped[str] = mapped_column(String(96), nullable=False)
    candidate_digest: Mapped[str] = mapped_column(String(64), nullable=False)
    tenant_id: Mapped[str] = mapped_column(String(128), nullable=False)
    run_id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), nullable=False)
    source_job_id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), nullable=False)
    fencing_token: Mapped[int] = mapped_column(BigInteger, nullable=False)
    behavior_digest: Mapped[str] = mapped_column(String(64), nullable=False)
    input_digest: Mapped[str] = mapped_column(String(64), nullable=False)
    schema_version: Mapped[str] = mapped_column(String(16), nullable=False)
    payload: Mapped[dict[str, Any]] = mapped_column(JSONB, nullable=False)
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False, server_default=func.statement_timestamp()
    )
    deletion_requested_at: Mapped[datetime | None] = mapped_column(
        DateTime(timezone=True), nullable=True
    )
