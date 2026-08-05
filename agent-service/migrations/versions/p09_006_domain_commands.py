"""Add one-use Domain Command approvals and immutable adoption receipts.

Revision ID: p09_006_domain_commands
Revises: p05_004_invocation_ledger
Create Date: 2026-08-02 01:00:00+08:00

The production ``user_itineraries`` and activity-table mapping remains an
explicit repository adapter because the remote database schema is not yet a
reproducible repository fact. This migration therefore does not guess, create,
or alter those formal business tables.
"""

from collections.abc import Sequence

from alembic import op
import sqlalchemy as sa
from sqlalchemy.dialects import postgresql


revision: str = "p09_006_domain_commands"
down_revision: str | Sequence[str] | None = "p05_004_invocation_ledger"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None

RUNTIME_SCHEMA = "agent_runtime"
NEW_TABLES = ("domain_command_approvals", "domain_command_receipts")


def _execute(statement: str) -> None:
    op.execute(sa.text(statement))


def upgrade() -> None:
    op.create_table(
        "domain_command_approvals",
        sa.Column("approval_id", postgresql.UUID(as_uuid=True), nullable=False),
        sa.Column("tenant_id", sa.String(length=128), nullable=False),
        sa.Column("principal_id", sa.String(length=256), nullable=False),
        sa.Column("run_id", postgresql.UUID(as_uuid=True), nullable=False),
        sa.Column("action", sa.String(length=64), nullable=False),
        sa.Column("target_itinerary_id", postgresql.UUID(as_uuid=True), nullable=False),
        sa.Column("candidate_id", postgresql.UUID(as_uuid=True), nullable=False),
        sa.Column("candidate_hash", sa.String(length=64), nullable=False),
        sa.Column("command_hash", sa.String(length=64), nullable=False),
        sa.Column("expected_version", sa.BigInteger(), nullable=False),
        sa.Column("assurance", sa.String(length=16), nullable=False),
        sa.Column("nonce_hash", sa.String(length=64), nullable=False),
        sa.Column("status", sa.String(length=16), nullable=False),
        sa.Column("expires_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("audit_receipt_id", sa.String(length=128), nullable=False),
        sa.Column(
            "created_at",
            sa.DateTime(timezone=True),
            server_default=sa.text("statement_timestamp()"),
            nullable=False,
        ),
        sa.Column("consumed_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("consumed_command_id", postgresql.UUID(as_uuid=True), nullable=True),
        sa.ForeignKeyConstraint(
            ["run_id", "tenant_id"],
            [f"{RUNTIME_SCHEMA}.runs.run_id", f"{RUNTIME_SCHEMA}.runs.tenant_id"],
            name="fk_domain_approvals_run_tenant",
            ondelete="CASCADE",
        ),
        sa.PrimaryKeyConstraint("approval_id", name="pk_domain_command_approvals"),
        sa.UniqueConstraint(
            "tenant_id",
            "candidate_id",
            "approval_id",
            name="uq_domain_approval_idempotency",
        ),
        sa.CheckConstraint(
            "action = 'itinerary.adopt'", name="ck_domain_approval_action"
        ),
        sa.CheckConstraint("assurance = 'aal2'", name="ck_domain_approval_assurance"),
        sa.CheckConstraint(
            "candidate_hash ~ '^[0-9a-f]{64}$' AND command_hash ~ '^[0-9a-f]{64}$' "
            "AND nonce_hash ~ '^[0-9a-f]{64}$'",
            name="ck_domain_approval_hashes",
        ),
        sa.CheckConstraint(
            "expected_version >= 0 AND length(principal_id) > 0 "
            "AND length(tenant_id) > 0 AND length(audit_receipt_id) > 0",
            name="ck_domain_approval_scope",
        ),
        sa.CheckConstraint(
            "expires_at > created_at AND expires_at <= created_at + interval '5 minutes'",
            name="ck_domain_approval_expiry",
        ),
        sa.CheckConstraint(
            "(status = 'approved' AND consumed_at IS NULL AND consumed_command_id IS NULL) OR "
            "(status = 'consumed' AND consumed_at IS NOT NULL AND consumed_command_id IS NOT NULL)",
            name="ck_domain_approval_status_shape",
        ),
        schema=RUNTIME_SCHEMA,
    )
    op.create_index(
        "ix_domain_approval_scope",
        "domain_command_approvals",
        ["tenant_id", "principal_id", "status", "expires_at"],
        schema=RUNTIME_SCHEMA,
    )
    op.create_table(
        "domain_command_receipts",
        sa.Column("command_id", postgresql.UUID(as_uuid=True), nullable=False),
        sa.Column("tenant_id", sa.String(length=128), nullable=False),
        sa.Column("principal_id", sa.String(length=256), nullable=False),
        sa.Column("run_id", postgresql.UUID(as_uuid=True), nullable=False),
        sa.Column("action", sa.String(length=64), nullable=False),
        sa.Column("approval_id", postgresql.UUID(as_uuid=True), nullable=False),
        sa.Column("candidate_id", postgresql.UUID(as_uuid=True), nullable=False),
        sa.Column("candidate_hash", sa.String(length=64), nullable=False),
        sa.Column("command_hash", sa.String(length=64), nullable=False),
        sa.Column("target_itinerary_id", postgresql.UUID(as_uuid=True), nullable=False),
        sa.Column("expected_version", sa.BigInteger(), nullable=False),
        sa.Column("result_version", sa.BigInteger(), nullable=False),
        sa.Column("event_id", postgresql.UUID(as_uuid=True), nullable=False),
        sa.Column("outbox_id", postgresql.UUID(as_uuid=True), nullable=False),
        sa.Column("audit_receipt_id", sa.String(length=128), nullable=False),
        sa.Column(
            "created_at",
            sa.DateTime(timezone=True),
            server_default=sa.text("statement_timestamp()"),
            nullable=False,
        ),
        sa.ForeignKeyConstraint(
            ["approval_id"],
            [f"{RUNTIME_SCHEMA}.domain_command_approvals.approval_id"],
            name="fk_domain_receipt_approval",
            ondelete="RESTRICT",
        ),
        sa.ForeignKeyConstraint(
            ["event_id"],
            [f"{RUNTIME_SCHEMA}.events.event_id"],
            name="fk_domain_receipt_event",
            ondelete="RESTRICT",
        ),
        sa.ForeignKeyConstraint(
            ["outbox_id"],
            [f"{RUNTIME_SCHEMA}.outbox_messages.outbox_id"],
            name="fk_domain_receipt_outbox",
            ondelete="RESTRICT",
        ),
        sa.PrimaryKeyConstraint("command_id", name="pk_domain_command_receipts"),
        sa.UniqueConstraint(
            "tenant_id",
            "candidate_id",
            "approval_id",
            name="uq_domain_receipt_idempotency",
        ),
        sa.UniqueConstraint("event_id", name="uq_domain_receipt_event"),
        sa.UniqueConstraint("outbox_id", name="uq_domain_receipt_outbox"),
        sa.CheckConstraint(
            "action = 'itinerary.adopt'", name="ck_domain_receipt_action"
        ),
        sa.CheckConstraint(
            "candidate_hash ~ '^[0-9a-f]{64}$' AND command_hash ~ '^[0-9a-f]{64}$'",
            name="ck_domain_receipt_hashes",
        ),
        sa.CheckConstraint(
            "expected_version >= 0 AND result_version = expected_version + 1 "
            "AND length(principal_id) > 0 AND length(tenant_id) > 0 "
            "AND length(audit_receipt_id) > 0",
            name="ck_domain_receipt_result",
        ),
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
        CREATE FUNCTION agent_runtime.enforce_domain_approval_transition()
        RETURNS trigger LANGUAGE plpgsql SECURITY INVOKER
        SET search_path = pg_catalog, pg_temp AS $$
        BEGIN
          IF TG_OP = 'DELETE' THEN
            RAISE EXCEPTION 'approval.delete_forbidden' USING ERRCODE = '23514';
          END IF;
          IF OLD.status <> 'approved' OR NEW.status <> 'consumed'
             OR NEW.approval_id <> OLD.approval_id
             OR NEW.tenant_id <> OLD.tenant_id
             OR NEW.principal_id <> OLD.principal_id
             OR NEW.run_id <> OLD.run_id
             OR NEW.action <> OLD.action
             OR NEW.target_itinerary_id <> OLD.target_itinerary_id
             OR NEW.candidate_id <> OLD.candidate_id
             OR NEW.candidate_hash <> OLD.candidate_hash
             OR NEW.command_hash <> OLD.command_hash
             OR NEW.expected_version <> OLD.expected_version
             OR NEW.assurance <> OLD.assurance
             OR NEW.nonce_hash <> OLD.nonce_hash
             OR NEW.expires_at <> OLD.expires_at
             OR NEW.audit_receipt_id <> OLD.audit_receipt_id
             OR NEW.created_at <> OLD.created_at
             OR NEW.consumed_at IS NULL
             OR NEW.consumed_command_id IS NULL THEN
            RAISE EXCEPTION 'approval.invalid_transition' USING ERRCODE = '23514';
          END IF;
          RETURN NEW;
        END;
        $$
        """
    )
    _execute(
        """
        CREATE TRIGGER domain_approval_transition_guard
        BEFORE UPDATE OR DELETE ON agent_runtime.domain_command_approvals
        FOR EACH ROW EXECUTE FUNCTION agent_runtime.enforce_domain_approval_transition()
        """
    )
    _execute(
        """
        CREATE FUNCTION agent_runtime.reject_domain_receipt_change()
        RETURNS trigger LANGUAGE plpgsql SECURITY INVOKER
        SET search_path = pg_catalog, pg_temp AS $$
        BEGIN
          RAISE EXCEPTION 'domain_receipt.immutable' USING ERRCODE = '23514';
        END;
        $$
        """
    )
    _execute(
        """
        CREATE TRIGGER domain_receipt_immutable_guard
        BEFORE UPDATE OR DELETE ON agent_runtime.domain_command_receipts
        FOR EACH ROW EXECUTE FUNCTION agent_runtime.reject_domain_receipt_change()
        """
    )
    _execute(
        "GRANT SELECT, INSERT, UPDATE ON agent_runtime.domain_command_approvals "
        "TO gonow_command_service"
    )
    _execute(
        "GRANT SELECT, INSERT ON agent_runtime.domain_command_receipts "
        "TO gonow_command_service"
    )
    _execute("GRANT SELECT ON agent_runtime.runs TO gonow_command_service")
    _execute(
        "GRANT UPDATE (next_event_seq) ON agent_runtime.runs "
        "TO gonow_command_service"
    )
    _execute(
        "GRANT SELECT ON agent_runtime.domain_command_approvals, "
        "agent_runtime.domain_command_receipts TO gonow_observer"
    )


def downgrade() -> None:
    _execute(
        "DROP TRIGGER domain_receipt_immutable_guard ON "
        "agent_runtime.domain_command_receipts"
    )
    _execute("DROP FUNCTION agent_runtime.reject_domain_receipt_change()")
    _execute(
        "DROP TRIGGER domain_approval_transition_guard ON "
        "agent_runtime.domain_command_approvals"
    )
    _execute("DROP FUNCTION agent_runtime.enforce_domain_approval_transition()")
    op.drop_table("domain_command_receipts", schema=RUNTIME_SCHEMA)
    op.drop_index(
        "ix_domain_approval_scope",
        table_name="domain_command_approvals",
        schema=RUNTIME_SCHEMA,
    )
    op.drop_table("domain_command_approvals", schema=RUNTIME_SCHEMA)
