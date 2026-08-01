"""Add durable Job, Lease, fencing, and checkpoint metadata.

Revision ID: p03_003_jobs_leases_checkpoints
Revises: p03_002_run_event_idempotency
Create Date: 2026-08-01 05:45:00+08:00
"""

from collections.abc import Sequence

from alembic import op
import sqlalchemy as sa
from sqlalchemy.dialects import postgresql


revision: str = "p03_003_jobs_leases_checkpoints"
down_revision: str | Sequence[str] | None = "p03_002_run_event_idempotency"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None

RUNTIME_SCHEMA = "agent_runtime"


def upgrade() -> None:
    op.create_table(
        "jobs",
        sa.Column("job_id", postgresql.UUID(as_uuid=True), nullable=False),
        sa.Column("run_id", postgresql.UUID(as_uuid=True), nullable=False),
        sa.Column("tenant_id", sa.String(length=128), nullable=False),
        sa.Column("job_type", sa.String(length=64), nullable=False),
        sa.Column("status", sa.String(length=16), nullable=False),
        sa.Column("input_ref", sa.String(length=96), nullable=False),
        sa.Column(
            "current_fencing_token",
            sa.BigInteger(),
            server_default=sa.text("0"),
            nullable=False,
        ),
        sa.Column(
            "attempt_count",
            sa.BigInteger(),
            server_default=sa.text("0"),
            nullable=False,
        ),
        sa.Column("max_attempts", sa.BigInteger(), nullable=False),
        sa.Column(
            "available_at",
            sa.DateTime(timezone=True),
            server_default=sa.text("statement_timestamp()"),
            nullable=False,
        ),
        sa.Column("audit_receipt_id", sa.String(length=128), nullable=False),
        sa.Column(
            "created_at",
            sa.DateTime(timezone=True),
            server_default=sa.text("statement_timestamp()"),
            nullable=False,
        ),
        sa.Column(
            "updated_at",
            sa.DateTime(timezone=True),
            server_default=sa.text("statement_timestamp()"),
            nullable=False,
        ),
        sa.CheckConstraint(
            "status IN ('queued','leased','completed','failed','cancelled')",
            name="ck_jobs_status",
        ),
        sa.CheckConstraint(
            "current_fencing_token >= 0",
            name="ck_jobs_fence_nonnegative",
        ),
        sa.CheckConstraint("attempt_count >= 0", name="ck_jobs_attempt_nonnegative"),
        sa.CheckConstraint("max_attempts IN (1,2)", name="ck_jobs_max_attempts"),
        sa.CheckConstraint(
            "input_ref ~ '^job-input://sha256/[0-9a-f]{64}$'",
            name="ck_jobs_input_ref",
        ),
        sa.CheckConstraint(
            "length(audit_receipt_id) > 0",
            name="ck_jobs_audit_receipt_nonempty",
        ),
        sa.ForeignKeyConstraint(
            ["run_id", "tenant_id"],
            [f"{RUNTIME_SCHEMA}.runs.run_id", f"{RUNTIME_SCHEMA}.runs.tenant_id"],
            name="fk_jobs_run_tenant",
            ondelete="CASCADE",
        ),
        sa.PrimaryKeyConstraint("job_id", name="pk_jobs"),
        sa.UniqueConstraint("job_id", "tenant_id", name="uq_jobs_id_tenant"),
        sa.UniqueConstraint(
            "job_id",
            "tenant_id",
            "run_id",
            name="uq_jobs_id_tenant_run",
        ),
        schema=RUNTIME_SCHEMA,
    )
    op.create_index(
        "ix_jobs_tenant_status_available",
        "jobs",
        ["tenant_id", "status", "available_at"],
        schema=RUNTIME_SCHEMA,
    )

    op.create_table(
        "leases",
        sa.Column("lease_id", postgresql.UUID(as_uuid=True), nullable=False),
        sa.Column("job_id", postgresql.UUID(as_uuid=True), nullable=False),
        sa.Column("tenant_id", sa.String(length=128), nullable=False),
        sa.Column("holder_id", sa.String(length=128), nullable=False),
        sa.Column("fencing_token", sa.BigInteger(), nullable=False),
        sa.Column("audit_receipt_id", sa.String(length=128), nullable=False),
        sa.Column(
            "acquired_at",
            sa.DateTime(timezone=True),
            server_default=sa.text("statement_timestamp()"),
            nullable=False,
        ),
        sa.Column(
            "heartbeat_at",
            sa.DateTime(timezone=True),
            server_default=sa.text("statement_timestamp()"),
            nullable=False,
        ),
        sa.Column("expires_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("released_at", sa.DateTime(timezone=True), nullable=True),
        sa.CheckConstraint("fencing_token > 0", name="ck_leases_fence_positive"),
        sa.CheckConstraint(
            "expires_at > acquired_at",
            name="ck_leases_expiry_after_acquire",
        ),
        sa.CheckConstraint(
            "length(holder_id) > 0 AND length(audit_receipt_id) > 0",
            name="ck_leases_holder_audit_nonempty",
        ),
        sa.ForeignKeyConstraint(
            ["job_id", "tenant_id"],
            [f"{RUNTIME_SCHEMA}.jobs.job_id", f"{RUNTIME_SCHEMA}.jobs.tenant_id"],
            name="fk_leases_job_tenant",
            ondelete="CASCADE",
        ),
        sa.PrimaryKeyConstraint("lease_id", name="pk_leases"),
        sa.UniqueConstraint("job_id", "fencing_token", name="uq_leases_job_fence"),
        schema=RUNTIME_SCHEMA,
    )
    op.create_index(
        "ix_leases_job_expiry",
        "leases",
        ["job_id", "expires_at"],
        schema=RUNTIME_SCHEMA,
    )
    op.create_index(
        "uq_leases_one_active_per_job",
        "leases",
        ["job_id"],
        unique=True,
        schema=RUNTIME_SCHEMA,
        postgresql_where=sa.text("released_at IS NULL"),
    )

    op.create_table(
        "checkpoint_metadata",
        sa.Column("checkpoint_id", postgresql.UUID(as_uuid=True), nullable=False),
        sa.Column("parent_checkpoint_id", postgresql.UUID(as_uuid=True), nullable=True),
        sa.Column("job_id", postgresql.UUID(as_uuid=True), nullable=False),
        sa.Column("run_id", postgresql.UUID(as_uuid=True), nullable=False),
        sa.Column("tenant_id", sa.String(length=128), nullable=False),
        sa.Column("checkpoint_seq", sa.BigInteger(), nullable=False),
        sa.Column("fencing_token", sa.BigInteger(), nullable=False),
        sa.Column("state_ref", sa.String(length=103), nullable=False),
        sa.Column("state_digest", sa.String(length=64), nullable=False),
        sa.Column("state_schema_digest", sa.String(length=64), nullable=False),
        sa.Column("pending_writes_ref", sa.String(length=100), nullable=True),
        sa.Column("audit_receipt_id", sa.String(length=128), nullable=False),
        sa.Column(
            "created_at",
            sa.DateTime(timezone=True),
            server_default=sa.text("statement_timestamp()"),
            nullable=False,
        ),
        sa.CheckConstraint("checkpoint_seq >= 1", name="ck_checkpoints_seq_positive"),
        sa.CheckConstraint("fencing_token > 0", name="ck_checkpoints_fence_positive"),
        sa.CheckConstraint(
            "state_ref ~ '^checkpoint://sha256/[0-9a-f]{64}$'",
            name="ck_checkpoints_state_ref",
        ),
        sa.CheckConstraint(
            "pending_writes_ref IS NULL OR pending_writes_ref ~ '^pending://sha256/[0-9a-f]{64}$'",
            name="ck_checkpoints_pending_ref",
        ),
        sa.CheckConstraint(
            "state_digest ~ '^[0-9a-f]{64}$' AND state_schema_digest ~ '^[0-9a-f]{64}$'",
            name="ck_checkpoints_digests",
        ),
        sa.CheckConstraint(
            "length(audit_receipt_id) > 0",
            name="ck_checkpoints_audit_receipt_nonempty",
        ),
        sa.ForeignKeyConstraint(
            ["job_id", "tenant_id", "run_id"],
            [
                f"{RUNTIME_SCHEMA}.jobs.job_id",
                f"{RUNTIME_SCHEMA}.jobs.tenant_id",
                f"{RUNTIME_SCHEMA}.jobs.run_id",
            ],
            name="fk_checkpoints_job_tenant_run",
            ondelete="CASCADE",
        ),
        sa.ForeignKeyConstraint(
            ["parent_checkpoint_id", "tenant_id", "run_id"],
            [
                f"{RUNTIME_SCHEMA}.checkpoint_metadata.checkpoint_id",
                f"{RUNTIME_SCHEMA}.checkpoint_metadata.tenant_id",
                f"{RUNTIME_SCHEMA}.checkpoint_metadata.run_id",
            ],
            name="fk_checkpoints_parent",
            ondelete="RESTRICT",
        ),
        sa.PrimaryKeyConstraint("checkpoint_id", name="pk_checkpoint_metadata"),
        sa.UniqueConstraint(
            "checkpoint_id",
            "tenant_id",
            "run_id",
            name="uq_checkpoints_id_tenant_run",
        ),
        sa.UniqueConstraint("run_id", "checkpoint_seq", name="uq_checkpoints_run_seq"),
        schema=RUNTIME_SCHEMA,
    )
    op.create_index(
        "ix_checkpoints_run_latest",
        "checkpoint_metadata",
        ["run_id", "checkpoint_seq"],
        schema=RUNTIME_SCHEMA,
    )

    op.execute(
        sa.text(
            """
            CREATE FUNCTION agent_runtime.enforce_lease_fence()
            RETURNS trigger
            LANGUAGE plpgsql
            SET search_path = pg_catalog, pg_temp
            AS $$
            BEGIN
              IF NOT EXISTS (
                SELECT 1 FROM agent_runtime.jobs AS job
                WHERE job.job_id = NEW.job_id
                  AND job.tenant_id = NEW.tenant_id
                  AND job.current_fencing_token = NEW.fencing_token
              ) THEN
                RAISE EXCEPTION 'consistency.stale_fence' USING ERRCODE = '23514';
              END IF;
              RETURN NEW;
            END;
            $$
            """
        )
    )
    op.execute(
        sa.text(
            """
            CREATE TRIGGER leases_fence_guard
            BEFORE INSERT ON agent_runtime.leases
            FOR EACH ROW EXECUTE FUNCTION agent_runtime.enforce_lease_fence()
            """
        )
    )
    op.execute(
        sa.text(
            """
            CREATE FUNCTION agent_runtime.enforce_checkpoint_fence()
            RETURNS trigger
            LANGUAGE plpgsql
            SET search_path = pg_catalog, pg_temp
            AS $$
            BEGIN
              IF NOT EXISTS (
                SELECT 1
                FROM agent_runtime.jobs AS job
                JOIN agent_runtime.leases AS lease
                  ON lease.job_id = job.job_id
                 AND lease.tenant_id = job.tenant_id
                WHERE job.job_id = NEW.job_id
                  AND job.run_id = NEW.run_id
                  AND job.tenant_id = NEW.tenant_id
                  AND job.current_fencing_token = NEW.fencing_token
                  AND lease.fencing_token = NEW.fencing_token
                  AND lease.released_at IS NULL
                  AND lease.expires_at > statement_timestamp()
              ) THEN
                RAISE EXCEPTION 'consistency.stale_fence' USING ERRCODE = '23514';
              END IF;
              RETURN NEW;
            END;
            $$
            """
        )
    )
    op.execute(
        sa.text(
            """
            CREATE TRIGGER checkpoints_fence_guard
            BEFORE INSERT OR UPDATE ON agent_runtime.checkpoint_metadata
            FOR EACH ROW EXECUTE FUNCTION agent_runtime.enforce_checkpoint_fence()
            """
        )
    )


def downgrade() -> None:
    op.execute(
        sa.text("DROP TRIGGER checkpoints_fence_guard ON agent_runtime.checkpoint_metadata")
    )
    op.execute(sa.text("DROP TRIGGER leases_fence_guard ON agent_runtime.leases"))
    op.execute(sa.text("DROP FUNCTION agent_runtime.enforce_checkpoint_fence()"))
    op.execute(sa.text("DROP FUNCTION agent_runtime.enforce_lease_fence()"))
    op.drop_index(
        "ix_checkpoints_run_latest",
        table_name="checkpoint_metadata",
        schema=RUNTIME_SCHEMA,
    )
    op.drop_table("checkpoint_metadata", schema=RUNTIME_SCHEMA)
    op.drop_index(
        "uq_leases_one_active_per_job",
        table_name="leases",
        schema=RUNTIME_SCHEMA,
    )
    op.drop_index("ix_leases_job_expiry", table_name="leases", schema=RUNTIME_SCHEMA)
    op.drop_table("leases", schema=RUNTIME_SCHEMA)
    op.drop_index(
        "ix_jobs_tenant_status_available",
        table_name="jobs",
        schema=RUNTIME_SCHEMA,
    )
    op.drop_table("jobs", schema=RUNTIME_SCHEMA)
