"""Tenant-scoped physical Tool invocation budgets and durable receipts."""

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


class InvocationBudgetRecord(RuntimeBase):
    __tablename__ = "invocation_budgets"
    __table_args__ = (
        ForeignKeyConstraint(
            ["run_id", "tenant_id"],
            [f"{RUNTIME_SCHEMA}.runs.run_id", f"{RUNTIME_SCHEMA}.runs.tenant_id"],
            name="fk_invocation_budgets_run_tenant",
            ondelete="CASCADE",
        ),
        UniqueConstraint(
            "run_id", "tenant_id", name="uq_invocation_budgets_run_tenant"
        ),
        CheckConstraint(
            "max_physical_calls BETWEEN 1 AND 1024",
            name="ck_invocation_budgets_limit",
        ),
        CheckConstraint(
            "reserved_calls >= 0 AND reserved_calls <= max_physical_calls",
            name="ck_invocation_budgets_reserved",
        ),
        CheckConstraint(
            "length(audit_receipt_id) > 0",
            name="ck_invocation_budgets_audit",
        ),
        {"schema": RUNTIME_SCHEMA},
    )

    run_id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), primary_key=True)
    tenant_id: Mapped[str] = mapped_column(String(128), nullable=False)
    max_physical_calls: Mapped[int] = mapped_column(BigInteger, nullable=False)
    reserved_calls: Mapped[int] = mapped_column(BigInteger, nullable=False, default=0)
    audit_receipt_id: Mapped[str] = mapped_column(String(128), nullable=False)
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False, server_default=func.statement_timestamp()
    )
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False, server_default=func.statement_timestamp()
    )


class PhysicalInvocationRecord(RuntimeBase):
    __tablename__ = "physical_invocations"
    __table_args__ = (
        ForeignKeyConstraint(
            ["job_id", "tenant_id", "run_id"],
            [
                f"{RUNTIME_SCHEMA}.jobs.job_id",
                f"{RUNTIME_SCHEMA}.jobs.tenant_id",
                f"{RUNTIME_SCHEMA}.jobs.run_id",
            ],
            name="fk_physical_invocations_job_scope",
            ondelete="CASCADE",
        ),
        ForeignKeyConstraint(
            ["run_id", "tenant_id"],
            [
                f"{RUNTIME_SCHEMA}.invocation_budgets.run_id",
                f"{RUNTIME_SCHEMA}.invocation_budgets.tenant_id",
            ],
            name="fk_physical_invocations_budget_scope",
            ondelete="CASCADE",
        ),
        UniqueConstraint(
            "run_id", "tool_call_id", name="uq_physical_invocations_run_call"
        ),
        CheckConstraint(
            "tool_call_id ~ '^[A-Za-z0-9][A-Za-z0-9_.:-]{0,127}$'",
            name="ck_physical_invocations_call_id",
        ),
        CheckConstraint(
            "tool_name ~ '^[a-z][a-z0-9_.-]{0,126}$'",
            name="ck_physical_invocations_tool_name",
        ),
        CheckConstraint(
            "tool_version ~ '^[0-9]+\\.[0-9]+\\.[0-9]+$'",
            name="ck_physical_invocations_tool_version",
        ),
        CheckConstraint(
            "request_fingerprint ~ '^[0-9a-f]{64}$'",
            name="ck_physical_invocations_fingerprint",
        ),
        CheckConstraint(
            "status IN ('reserved','succeeded','failed','unknown_outcome')",
            name="ck_physical_invocations_status",
        ),
        CheckConstraint(
            "reservation_fencing_token > 0",
            name="ck_physical_invocations_reservation_fence",
        ),
        CheckConstraint(
            "length(reservation_holder_id) > 0 AND length(audit_receipt_id) > 0",
            name="ck_physical_invocations_reservation_audit",
        ),
        CheckConstraint(
            "(status = 'reserved' AND result_ref IS NULL AND result_digest IS NULL "
            "AND error_code IS NULL AND completion_holder_id IS NULL "
            "AND completion_fencing_token IS NULL AND completion_audit_receipt_id IS NULL "
            "AND completed_at IS NULL) OR "
            "(status = 'succeeded' AND result_ref ~ '^tool-result://sha256/[0-9a-f]{64}$' "
            "AND result_digest ~ '^[0-9a-f]{64}$' AND error_code IS NULL "
            "AND completion_holder_id IS NOT NULL AND completion_fencing_token > 0 "
            "AND completion_audit_receipt_id IS NOT NULL AND completed_at IS NOT NULL) OR "
            "(status IN ('failed','unknown_outcome') AND result_ref IS NULL "
            "AND result_digest IS NULL AND error_code ~ '^[a-z][a-z0-9_.-]{0,126}$' "
            "AND completion_holder_id IS NOT NULL AND completion_fencing_token > 0 "
            "AND completion_audit_receipt_id IS NOT NULL AND completed_at IS NOT NULL)",
            name="ck_physical_invocations_outcome_shape",
        ),
        Index(
            "ix_physical_invocations_tenant_status",
            "tenant_id",
            "status",
            "reserved_at",
        ),
        {"schema": RUNTIME_SCHEMA},
    )

    invocation_id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), primary_key=True)
    tenant_id: Mapped[str] = mapped_column(String(128), nullable=False)
    run_id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), nullable=False)
    job_id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), nullable=False)
    tool_call_id: Mapped[str] = mapped_column(String(128), nullable=False)
    tool_name: Mapped[str] = mapped_column(String(127), nullable=False)
    tool_version: Mapped[str] = mapped_column(String(32), nullable=False)
    request_fingerprint: Mapped[str] = mapped_column(String(64), nullable=False)
    status: Mapped[str] = mapped_column(String(32), nullable=False)
    reservation_holder_id: Mapped[str] = mapped_column(String(128), nullable=False)
    reservation_fencing_token: Mapped[int] = mapped_column(BigInteger, nullable=False)
    result_ref: Mapped[str | None] = mapped_column(String(103), nullable=True)
    result_digest: Mapped[str | None] = mapped_column(String(64), nullable=True)
    error_code: Mapped[str | None] = mapped_column(String(127), nullable=True)
    audit_receipt_id: Mapped[str] = mapped_column(String(128), nullable=False)
    completion_holder_id: Mapped[str | None] = mapped_column(String(128), nullable=True)
    completion_fencing_token: Mapped[int | None] = mapped_column(
        BigInteger, nullable=True
    )
    completion_audit_receipt_id: Mapped[str | None] = mapped_column(
        String(128), nullable=True
    )
    reserved_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False, server_default=func.statement_timestamp()
    )
    completed_at: Mapped[datetime | None] = mapped_column(
        DateTime(timezone=True), nullable=True
    )
