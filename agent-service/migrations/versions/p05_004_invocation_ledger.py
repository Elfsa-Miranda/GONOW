"""Add atomic physical invocation budgets and receipts.

Revision ID: p05_004_invocation_ledger
Revises: p05_003_checkpoint_refs
Create Date: 2026-08-01 14:20:00+08:00
"""

from collections.abc import Sequence

from alembic import op
import sqlalchemy as sa
from sqlalchemy.dialects import postgresql


revision: str = "p05_004_invocation_ledger"
down_revision: str | Sequence[str] | None = "p05_003_checkpoint_refs"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None

RUNTIME_SCHEMA = "agent_runtime"
NEW_TABLES = ("invocation_budgets", "physical_invocations")


def _execute(statement: str) -> None:
    op.execute(sa.text(statement))


def upgrade() -> None:
    op.create_table(
        "invocation_budgets",
        sa.Column("run_id", postgresql.UUID(as_uuid=True), nullable=False),
        sa.Column("tenant_id", sa.String(length=128), nullable=False),
        sa.Column("max_physical_calls", sa.BigInteger(), nullable=False),
        sa.Column("reserved_calls", sa.BigInteger(), nullable=False),
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
        sa.ForeignKeyConstraint(
            ["run_id", "tenant_id"],
            [
                f"{RUNTIME_SCHEMA}.runs.run_id",
                f"{RUNTIME_SCHEMA}.runs.tenant_id",
            ],
            name="fk_invocation_budgets_run_tenant",
            ondelete="CASCADE",
        ),
        sa.PrimaryKeyConstraint("run_id", name="pk_invocation_budgets"),
        sa.UniqueConstraint(
            "run_id", "tenant_id", name="uq_invocation_budgets_run_tenant"
        ),
        sa.CheckConstraint(
            "max_physical_calls BETWEEN 1 AND 1024",
            name="ck_invocation_budgets_limit",
        ),
        sa.CheckConstraint(
            "reserved_calls >= 0 AND reserved_calls <= max_physical_calls",
            name="ck_invocation_budgets_reserved",
        ),
        sa.CheckConstraint(
            "length(audit_receipt_id) > 0",
            name="ck_invocation_budgets_audit",
        ),
        schema=RUNTIME_SCHEMA,
    )
    op.create_table(
        "physical_invocations",
        sa.Column("invocation_id", postgresql.UUID(as_uuid=True), nullable=False),
        sa.Column("tenant_id", sa.String(length=128), nullable=False),
        sa.Column("run_id", postgresql.UUID(as_uuid=True), nullable=False),
        sa.Column("job_id", postgresql.UUID(as_uuid=True), nullable=False),
        sa.Column("tool_call_id", sa.String(length=128), nullable=False),
        sa.Column("tool_name", sa.String(length=127), nullable=False),
        sa.Column("tool_version", sa.String(length=32), nullable=False),
        sa.Column("request_fingerprint", sa.String(length=64), nullable=False),
        sa.Column("status", sa.String(length=32), nullable=False),
        sa.Column("reservation_holder_id", sa.String(length=128), nullable=False),
        sa.Column("reservation_fencing_token", sa.BigInteger(), nullable=False),
        sa.Column("result_ref", sa.String(length=103), nullable=True),
        sa.Column("result_digest", sa.String(length=64), nullable=True),
        sa.Column("error_code", sa.String(length=127), nullable=True),
        sa.Column("audit_receipt_id", sa.String(length=128), nullable=False),
        sa.Column("completion_holder_id", sa.String(length=128), nullable=True),
        sa.Column("completion_fencing_token", sa.BigInteger(), nullable=True),
        sa.Column("completion_audit_receipt_id", sa.String(length=128), nullable=True),
        sa.Column(
            "reserved_at",
            sa.DateTime(timezone=True),
            server_default=sa.text("statement_timestamp()"),
            nullable=False,
        ),
        sa.Column("completed_at", sa.DateTime(timezone=True), nullable=True),
        sa.ForeignKeyConstraint(
            ["job_id", "tenant_id", "run_id"],
            [
                f"{RUNTIME_SCHEMA}.jobs.job_id",
                f"{RUNTIME_SCHEMA}.jobs.tenant_id",
                f"{RUNTIME_SCHEMA}.jobs.run_id",
            ],
            name="fk_physical_invocations_job_scope",
            ondelete="CASCADE",
        ),
        sa.ForeignKeyConstraint(
            ["run_id", "tenant_id"],
            [
                f"{RUNTIME_SCHEMA}.invocation_budgets.run_id",
                f"{RUNTIME_SCHEMA}.invocation_budgets.tenant_id",
            ],
            name="fk_physical_invocations_budget_scope",
            ondelete="CASCADE",
        ),
        sa.PrimaryKeyConstraint("invocation_id", name="pk_physical_invocations"),
        sa.UniqueConstraint(
            "run_id", "tool_call_id", name="uq_physical_invocations_run_call"
        ),
        sa.CheckConstraint(
            "tool_call_id ~ '^[A-Za-z0-9][A-Za-z0-9_.:-]{0,127}$'",
            name="ck_physical_invocations_call_id",
        ),
        sa.CheckConstraint(
            "tool_name ~ '^[a-z][a-z0-9_.-]{0,126}$'",
            name="ck_physical_invocations_tool_name",
        ),
        sa.CheckConstraint(
            "tool_version ~ '^[0-9]+\\.[0-9]+\\.[0-9]+$'",
            name="ck_physical_invocations_tool_version",
        ),
        sa.CheckConstraint(
            "request_fingerprint ~ '^[0-9a-f]{64}$'",
            name="ck_physical_invocations_fingerprint",
        ),
        sa.CheckConstraint(
            "status IN ('reserved','succeeded','failed','unknown_outcome')",
            name="ck_physical_invocations_status",
        ),
        sa.CheckConstraint(
            "reservation_fencing_token > 0",
            name="ck_physical_invocations_reservation_fence",
        ),
        sa.CheckConstraint(
            "length(reservation_holder_id) > 0 AND length(audit_receipt_id) > 0",
            name="ck_physical_invocations_reservation_audit",
        ),
        sa.CheckConstraint(
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
        schema=RUNTIME_SCHEMA,
    )
    op.create_index(
        "ix_physical_invocations_tenant_status",
        "physical_invocations",
        ["tenant_id", "status", "reserved_at"],
        schema=RUNTIME_SCHEMA,
    )

    for table_name in NEW_TABLES:
        _execute(f"REVOKE ALL ON agent_runtime.{table_name} FROM PUBLIC")
        _execute(f"ALTER TABLE agent_runtime.{table_name} ENABLE ROW LEVEL SECURITY")
        _execute(f"ALTER TABLE agent_runtime.{table_name} FORCE ROW LEVEL SECURITY")
        _execute(
            f"""
            CREATE POLICY tenant_isolation ON agent_runtime.{table_name}
            USING (tenant_id = agent_runtime.current_tenant_id())
            WITH CHECK (tenant_id = agent_runtime.current_tenant_id())
            """
        )

    _execute(
        """
        CREATE FUNCTION agent_runtime.enforce_invocation_budget_update()
        RETURNS trigger LANGUAGE plpgsql SECURITY INVOKER
        SET search_path = pg_catalog, pg_temp
        AS $$
        BEGIN
          IF NEW.run_id <> OLD.run_id OR NEW.tenant_id <> OLD.tenant_id
             OR NEW.max_physical_calls <> OLD.max_physical_calls
             OR NEW.audit_receipt_id <> OLD.audit_receipt_id
             OR NEW.created_at <> OLD.created_at
             OR NEW.reserved_calls < OLD.reserved_calls
             OR NEW.reserved_calls > OLD.reserved_calls + 1 THEN
            RAISE EXCEPTION 'budget.invocation_immutable' USING ERRCODE = '23514';
          END IF;
          NEW.updated_at := statement_timestamp();
          RETURN NEW;
        END;
        $$
        """
    )
    _execute(
        """
        CREATE TRIGGER invocation_budget_update_guard
        BEFORE UPDATE ON agent_runtime.invocation_budgets
        FOR EACH ROW EXECUTE FUNCTION agent_runtime.enforce_invocation_budget_update()
        """
    )
    _execute(
        """
        CREATE FUNCTION agent_runtime.enforce_physical_invocation_fence()
        RETURNS trigger LANGUAGE plpgsql SECURITY INVOKER
        SET search_path = pg_catalog, pg_temp
        AS $$
        DECLARE required_holder text; required_fence bigint;
        BEGIN
          IF TG_OP = 'INSERT' THEN
            IF NEW.status <> 'reserved' THEN
              RAISE EXCEPTION 'tool.invocation_invalid_transition' USING ERRCODE = '23514';
            END IF;
            required_holder := NEW.reservation_holder_id;
            required_fence := NEW.reservation_fencing_token;
          ELSE
            IF OLD.status <> 'reserved' OR NEW.status NOT IN ('succeeded','failed','unknown_outcome')
               OR NEW.invocation_id <> OLD.invocation_id
               OR NEW.tenant_id <> OLD.tenant_id OR NEW.run_id <> OLD.run_id
               OR NEW.job_id <> OLD.job_id OR NEW.tool_call_id <> OLD.tool_call_id
               OR NEW.tool_name <> OLD.tool_name OR NEW.tool_version <> OLD.tool_version
               OR NEW.request_fingerprint <> OLD.request_fingerprint
               OR NEW.reservation_holder_id <> OLD.reservation_holder_id
               OR NEW.reservation_fencing_token <> OLD.reservation_fencing_token
               OR NEW.audit_receipt_id <> OLD.audit_receipt_id
               OR NEW.reserved_at <> OLD.reserved_at THEN
              RAISE EXCEPTION 'tool.invocation_invalid_transition' USING ERRCODE = '23514';
            END IF;
            required_holder := NEW.completion_holder_id;
            required_fence := NEW.completion_fencing_token;
          END IF;
          IF required_holder IS NULL OR required_fence IS NULL OR NOT EXISTS (
            SELECT 1 FROM agent_runtime.jobs AS job
            JOIN agent_runtime.leases AS lease
              ON lease.job_id = job.job_id AND lease.tenant_id = job.tenant_id
            WHERE job.job_id = NEW.job_id AND job.tenant_id = NEW.tenant_id
              AND job.run_id = NEW.run_id AND job.status = 'leased'
              AND job.current_fencing_token = required_fence
              AND lease.holder_id = required_holder
              AND lease.fencing_token = required_fence
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
    _execute(
        """
        CREATE TRIGGER physical_invocation_fence_guard
        BEFORE INSERT OR UPDATE ON agent_runtime.physical_invocations
        FOR EACH ROW EXECUTE FUNCTION agent_runtime.enforce_physical_invocation_fence()
        """
    )
    _execute(
        "GRANT SELECT, INSERT, UPDATE ON agent_runtime.invocation_budgets, "
        "agent_runtime.physical_invocations TO gonow_agent_worker"
    )
    _execute(
        "GRANT SELECT ON agent_runtime.invocation_budgets, "
        "agent_runtime.physical_invocations TO gonow_observer"
    )


def downgrade() -> None:
    _execute(
        "DROP TRIGGER physical_invocation_fence_guard ON "
        "agent_runtime.physical_invocations"
    )
    _execute("DROP FUNCTION agent_runtime.enforce_physical_invocation_fence()")
    _execute(
        "DROP TRIGGER invocation_budget_update_guard ON "
        "agent_runtime.invocation_budgets"
    )
    _execute("DROP FUNCTION agent_runtime.enforce_invocation_budget_update()")
    op.drop_index(
        "ix_physical_invocations_tenant_status",
        table_name="physical_invocations",
        schema=RUNTIME_SCHEMA,
    )
    op.drop_table("physical_invocations", schema=RUNTIME_SCHEMA)
    op.drop_table("invocation_budgets", schema=RUNTIME_SCHEMA)
