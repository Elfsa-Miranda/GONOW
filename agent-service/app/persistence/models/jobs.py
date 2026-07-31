"""Durable Job, Lease, fencing, and checkpoint metadata models."""

from __future__ import annotations

import uuid
from datetime import datetime

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
from sqlalchemy.dialects.postgresql import UUID
from sqlalchemy.orm import Mapped, mapped_column

from app.persistence.models.runtime import RUNTIME_SCHEMA, RuntimeBase


class JobRecord(RuntimeBase):
    __tablename__ = "jobs"
    __table_args__ = (
        ForeignKeyConstraint(
            ["run_id", "tenant_id"],
            [f"{RUNTIME_SCHEMA}.runs.run_id", f"{RUNTIME_SCHEMA}.runs.tenant_id"],
            name="fk_jobs_run_tenant",
            ondelete="CASCADE",
        ),
        UniqueConstraint("job_id", "tenant_id", name="uq_jobs_id_tenant"),
        UniqueConstraint("job_id", "tenant_id", "run_id", name="uq_jobs_id_tenant_run"),
        CheckConstraint(
            "status IN ('queued','leased','completed','failed','cancelled')",
            name="ck_jobs_status",
        ),
        CheckConstraint("current_fencing_token >= 0", name="ck_jobs_fence_nonnegative"),
        CheckConstraint("attempt_count >= 0", name="ck_jobs_attempt_nonnegative"),
        CheckConstraint("max_attempts IN (1,2)", name="ck_jobs_max_attempts"),
        CheckConstraint(
            "input_ref ~ '^job-input://sha256/[0-9a-f]{64}$'",
            name="ck_jobs_input_ref",
        ),
        CheckConstraint(
            "length(audit_receipt_id) > 0",
            name="ck_jobs_audit_receipt_nonempty",
        ),
        Index("ix_jobs_tenant_status_available", "tenant_id", "status", "available_at"),
        {"schema": RUNTIME_SCHEMA},
    )

    job_id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), primary_key=True)
    run_id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), nullable=False)
    tenant_id: Mapped[str] = mapped_column(String(128), nullable=False)
    job_type: Mapped[str] = mapped_column(String(64), nullable=False)
    status: Mapped[str] = mapped_column(String(16), nullable=False)
    input_ref: Mapped[str] = mapped_column(String(96), nullable=False)
    current_fencing_token: Mapped[int] = mapped_column(BigInteger, nullable=False, default=0)
    attempt_count: Mapped[int] = mapped_column(BigInteger, nullable=False, default=0)
    max_attempts: Mapped[int] = mapped_column(BigInteger, nullable=False)
    available_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False, server_default=func.statement_timestamp()
    )
    audit_receipt_id: Mapped[str] = mapped_column(String(128), nullable=False)
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False, server_default=func.statement_timestamp()
    )
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False, server_default=func.statement_timestamp()
    )


class LeaseRecord(RuntimeBase):
    __tablename__ = "leases"
    __table_args__ = (
        ForeignKeyConstraint(
            ["job_id", "tenant_id"],
            [f"{RUNTIME_SCHEMA}.jobs.job_id", f"{RUNTIME_SCHEMA}.jobs.tenant_id"],
            name="fk_leases_job_tenant",
            ondelete="CASCADE",
        ),
        UniqueConstraint("job_id", "fencing_token", name="uq_leases_job_fence"),
        CheckConstraint("fencing_token > 0", name="ck_leases_fence_positive"),
        CheckConstraint("expires_at > acquired_at", name="ck_leases_expiry_after_acquire"),
        CheckConstraint(
            "length(holder_id) > 0 AND length(audit_receipt_id) > 0",
            name="ck_leases_holder_audit_nonempty",
        ),
        Index("ix_leases_job_expiry", "job_id", "expires_at"),
        {"schema": RUNTIME_SCHEMA},
    )

    lease_id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), primary_key=True)
    job_id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), nullable=False)
    tenant_id: Mapped[str] = mapped_column(String(128), nullable=False)
    holder_id: Mapped[str] = mapped_column(String(128), nullable=False)
    fencing_token: Mapped[int] = mapped_column(BigInteger, nullable=False)
    audit_receipt_id: Mapped[str] = mapped_column(String(128), nullable=False)
    acquired_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False, server_default=func.statement_timestamp()
    )
    heartbeat_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False, server_default=func.statement_timestamp()
    )
    expires_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)
    released_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)


Index(
    "uq_leases_one_active_per_job",
    LeaseRecord.job_id,
    unique=True,
    postgresql_where=LeaseRecord.released_at.is_(None),
)


class CheckpointMetadataRecord(RuntimeBase):
    __tablename__ = "checkpoint_metadata"
    __table_args__ = (
        ForeignKeyConstraint(
            ["job_id", "tenant_id", "run_id"],
            [
                f"{RUNTIME_SCHEMA}.jobs.job_id",
                f"{RUNTIME_SCHEMA}.jobs.tenant_id",
                f"{RUNTIME_SCHEMA}.jobs.run_id",
            ],
            name="fk_checkpoints_job_tenant_run",
            ondelete="CASCADE",
        ),
        ForeignKeyConstraint(
            ["parent_checkpoint_id", "tenant_id", "run_id"],
            [
                f"{RUNTIME_SCHEMA}.checkpoint_metadata.checkpoint_id",
                f"{RUNTIME_SCHEMA}.checkpoint_metadata.tenant_id",
                f"{RUNTIME_SCHEMA}.checkpoint_metadata.run_id",
            ],
            name="fk_checkpoints_parent",
            ondelete="RESTRICT",
        ),
        UniqueConstraint(
            "checkpoint_id",
            "tenant_id",
            "run_id",
            name="uq_checkpoints_id_tenant_run",
        ),
        UniqueConstraint("run_id", "checkpoint_seq", name="uq_checkpoints_run_seq"),
        CheckConstraint("checkpoint_seq >= 1", name="ck_checkpoints_seq_positive"),
        CheckConstraint("fencing_token > 0", name="ck_checkpoints_fence_positive"),
        CheckConstraint(
            "state_ref ~ '^checkpoint://sha256/[0-9a-f]{64}$'",
            name="ck_checkpoints_state_ref",
        ),
        CheckConstraint(
            "pending_writes_ref IS NULL OR pending_writes_ref ~ '^pending://sha256/[0-9a-f]{64}$'",
            name="ck_checkpoints_pending_ref",
        ),
        CheckConstraint(
            "state_digest ~ '^[0-9a-f]{64}$' AND state_schema_digest ~ '^[0-9a-f]{64}$'",
            name="ck_checkpoints_digests",
        ),
        CheckConstraint(
            "length(audit_receipt_id) > 0",
            name="ck_checkpoints_audit_receipt_nonempty",
        ),
        Index("ix_checkpoints_run_latest", "run_id", "checkpoint_seq"),
        {"schema": RUNTIME_SCHEMA},
    )

    checkpoint_id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), primary_key=True)
    parent_checkpoint_id: Mapped[uuid.UUID | None] = mapped_column(
        UUID(as_uuid=True), nullable=True
    )
    job_id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), nullable=False)
    run_id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), nullable=False)
    tenant_id: Mapped[str] = mapped_column(String(128), nullable=False)
    checkpoint_seq: Mapped[int] = mapped_column(BigInteger, nullable=False)
    fencing_token: Mapped[int] = mapped_column(BigInteger, nullable=False)
    state_ref: Mapped[str] = mapped_column(String(103), nullable=False)
    state_digest: Mapped[str] = mapped_column(String(64), nullable=False)
    state_schema_digest: Mapped[str] = mapped_column(String(64), nullable=False)
    pending_writes_ref: Mapped[str | None] = mapped_column(String(100), nullable=True)
    audit_receipt_id: Mapped[str] = mapped_column(String(128), nullable=False)
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False, server_default=func.statement_timestamp()
    )
