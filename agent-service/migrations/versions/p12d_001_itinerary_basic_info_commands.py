"""Add dormant persistence for the selected Basic Info Domain Command.

Revision ID: p12d_001_commands
Revises: p11_008_knowledge_tombstones
Create Date: 2026-08-04 17:10:00+08:00

This expand-only migration intentionally does not create, inspect, or alter a
``user_itineraries`` table. Its production schema and RLS remain unknown. The
business-row adapter is therefore a later, explicit runtime composition input.
"""

from collections.abc import Sequence

from alembic import op
import sqlalchemy as sa
from sqlalchemy.dialects import postgresql


revision: str = "p12d_001_commands"
down_revision: str | Sequence[str] | None = "p11_008_knowledge_tombstones"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None

COMMAND_SCHEMA = "domain_command"
COMMAND_TYPE = "itinerary.basic_info.update"
ROLES = ("gonow_command_service", "gonow_observer")
TENANT_TABLES = (
    "itinerary_basic_info_attempts",
    "itinerary_basic_info_outbox",
    "itinerary_basic_info_receipts",
)


def _execute(statement: str) -> None:
    op.execute(sa.text(statement))


def _uuid(name: str, *, nullable: bool = False) -> sa.Column:
    return sa.Column(name, postgresql.UUID(as_uuid=True), nullable=nullable)


def _digest(name: str) -> sa.Column:
    return sa.Column(name, sa.String(length=64), nullable=False)


def upgrade() -> None:
    role_list = ",".join(f"'{role}'" for role in ROLES)
    _execute(
        f"""
        DO $$
        DECLARE role_count integer; bypass_count integer;
        BEGIN
          SELECT count(*), count(*) FILTER (WHERE rolbypassrls OR rolsuper)
            INTO role_count, bypass_count
            FROM pg_roles WHERE rolname IN ({role_list});
          IF role_count <> {len(ROLES)} THEN
            RAISE EXCEPTION 'domain_command.required_roles_missing'
              USING ERRCODE = '42501';
          END IF;
          IF bypass_count <> 0 THEN
            RAISE EXCEPTION 'domain_command.bypass_role_forbidden'
              USING ERRCODE = '42501';
          END IF;
        END;
        $$
        """
    )
    op.execute(sa.schema.CreateSchema(COMMAND_SCHEMA))

    op.create_table(
        "itinerary_basic_info_attempts",
        _uuid("attempt_id"),
        sa.Column("tenant_id", sa.String(length=128), nullable=False),
        _uuid("command_id"),
        sa.Column("command_type", sa.String(length=64), nullable=False),
        _uuid("target_itinerary_id"),
        _digest("target_digest"),
        _digest("principal_digest"),
        _digest("idempotency_digest"),
        _digest("command_hash"),
        _digest("policy_digest"),
        _digest("schema_digest"),
        sa.Column("expected_version", sa.BigInteger(), nullable=False),
        sa.Column("state", sa.String(length=16), nullable=False),
        sa.Column("actual_version", sa.BigInteger(), nullable=True),
        _uuid("event_id", nullable=True),
        _uuid("outbox_id", nullable=True),
        sa.Column(
            "created_at",
            sa.DateTime(timezone=True),
            server_default=sa.text("statement_timestamp()"),
            nullable=False,
        ),
        sa.Column("resolved_at", sa.DateTime(timezone=True), nullable=True),
        sa.PrimaryKeyConstraint("attempt_id", name="pk_basic_info_attempts"),
        sa.UniqueConstraint("command_id", name="uq_basic_info_attempt_command"),
        sa.UniqueConstraint(
            "tenant_id",
            "idempotency_digest",
            name="uq_basic_info_attempt_idempotency",
        ),
        sa.UniqueConstraint("event_id", name="uq_basic_info_attempt_event"),
        sa.UniqueConstraint("outbox_id", name="uq_basic_info_attempt_outbox"),
        sa.CheckConstraint(
            f"command_type = '{COMMAND_TYPE}'", name="ck_basic_info_attempt_type"
        ),
        sa.CheckConstraint(
            "target_digest ~ '^[0-9a-f]{64}$' "
            "AND principal_digest ~ '^[0-9a-f]{64}$' "
            "AND idempotency_digest ~ '^[0-9a-f]{64}$' "
            "AND command_hash ~ '^[0-9a-f]{64}$' "
            "AND policy_digest ~ '^[0-9a-f]{64}$' "
            "AND schema_digest ~ '^[0-9a-f]{64}$'",
            name="ck_basic_info_attempt_digests",
        ),
        sa.CheckConstraint(
            "expected_version >= 0 AND length(tenant_id) > 0",
            name="ck_basic_info_attempt_scope",
        ),
        sa.CheckConstraint(
            "(state = 'received' AND resolved_at IS NULL AND actual_version IS NULL "
            "AND event_id IS NULL AND outbox_id IS NULL) OR "
            "(state = 'committed' AND resolved_at IS NOT NULL "
            "AND actual_version = expected_version + 1 "
            "AND event_id IS NOT NULL AND outbox_id IS NOT NULL) OR "
            "(state IN ('conflict','denied','rejected') AND resolved_at IS NOT NULL "
            "AND actual_version IS NULL AND event_id IS NULL AND outbox_id IS NULL)",
            name="ck_basic_info_attempt_state",
        ),
        schema=COMMAND_SCHEMA,
    )
    op.create_index(
        "ix_basic_info_attempt_target",
        "itinerary_basic_info_attempts",
        ["tenant_id", "target_itinerary_id", "created_at"],
        schema=COMMAND_SCHEMA,
    )

    op.create_table(
        "itinerary_basic_info_outbox",
        _uuid("outbox_id"),
        sa.Column("tenant_id", sa.String(length=128), nullable=False),
        _uuid("attempt_id"),
        _uuid("event_id"),
        sa.Column("event_type", sa.String(length=96), nullable=False),
        _digest("target_digest"),
        sa.Column("payload_ref", sa.String(length=96), nullable=False),
        _digest("payload_digest"),
        sa.Column("state", sa.String(length=16), nullable=False),
        sa.Column("attempt_count", sa.BigInteger(), nullable=False),
        sa.Column("max_attempts", sa.BigInteger(), nullable=False),
        sa.Column("available_at", sa.DateTime(timezone=True), nullable=False),
        _uuid("claim_token", nullable=True),
        sa.Column("claimed_by", sa.String(length=128), nullable=True),
        sa.Column("claimed_until", sa.DateTime(timezone=True), nullable=True),
        sa.Column("last_error_code", sa.String(length=127), nullable=True),
        sa.Column(
            "created_at",
            sa.DateTime(timezone=True),
            server_default=sa.text("statement_timestamp()"),
            nullable=False,
        ),
        sa.Column("delivered_at", sa.DateTime(timezone=True), nullable=True),
        sa.ForeignKeyConstraint(
            ["attempt_id"],
            [f"{COMMAND_SCHEMA}.itinerary_basic_info_attempts.attempt_id"],
            name="fk_basic_info_outbox_attempt",
            ondelete="RESTRICT",
        ),
        sa.PrimaryKeyConstraint("outbox_id", name="pk_basic_info_outbox"),
        sa.UniqueConstraint("attempt_id", name="uq_basic_info_outbox_attempt"),
        sa.UniqueConstraint("event_id", name="uq_basic_info_outbox_event"),
        sa.CheckConstraint(
            "event_type = 'itinerary.basic_info.updated'",
            name="ck_basic_info_outbox_event_type",
        ),
        sa.CheckConstraint(
            "target_digest ~ '^[0-9a-f]{64}$' "
            "AND payload_digest ~ '^[0-9a-f]{64}$' "
            "AND payload_ref ~ '^domain-command-event://sha256/[0-9a-f]{64}$'",
            name="ck_basic_info_outbox_payload",
        ),
        sa.CheckConstraint(
            "state IN ('pending','claimed','delivered','dead_letter') "
            "AND attempt_count >= 0 AND max_attempts BETWEEN 1 AND 10",
            name="ck_basic_info_outbox_delivery",
        ),
        sa.CheckConstraint(
            "(state = 'claimed' AND claim_token IS NOT NULL AND claimed_by IS NOT NULL "
            "AND claimed_until IS NOT NULL AND delivered_at IS NULL) OR "
            "(state = 'delivered' AND claim_token IS NULL AND claimed_by IS NULL "
            "AND claimed_until IS NULL AND delivered_at IS NOT NULL) OR "
            "(state IN ('pending','dead_letter') AND claim_token IS NULL "
            "AND claimed_by IS NULL AND claimed_until IS NULL AND delivered_at IS NULL)",
            name="ck_basic_info_outbox_claim",
        ),
        schema=COMMAND_SCHEMA,
    )
    op.create_index(
        "ix_basic_info_outbox_claim",
        "itinerary_basic_info_outbox",
        ["state", "available_at", "created_at"],
        schema=COMMAND_SCHEMA,
    )

    op.create_table(
        "itinerary_basic_info_receipts",
        _uuid("receipt_id"),
        sa.Column("tenant_id", sa.String(length=128), nullable=False),
        _uuid("attempt_id"),
        _uuid("command_id"),
        sa.Column("command_type", sa.String(length=64), nullable=False),
        sa.Column("state", sa.String(length=16), nullable=False),
        _digest("target_digest"),
        _digest("principal_digest"),
        _digest("idempotency_digest"),
        _digest("command_hash"),
        _digest("policy_digest"),
        _digest("schema_digest"),
        sa.Column("approval_reference", sa.String(length=96), nullable=False),
        sa.Column("expected_version", sa.BigInteger(), nullable=False),
        sa.Column("actual_version", sa.BigInteger(), nullable=True),
        _uuid("event_id", nullable=True),
        _uuid("outbox_id", nullable=True),
        sa.Column(
            "recorded_at",
            sa.DateTime(timezone=True),
            server_default=sa.text("statement_timestamp()"),
            nullable=False,
        ),
        sa.ForeignKeyConstraint(
            ["attempt_id"],
            [f"{COMMAND_SCHEMA}.itinerary_basic_info_attempts.attempt_id"],
            name="fk_basic_info_receipt_attempt",
            ondelete="RESTRICT",
        ),
        sa.ForeignKeyConstraint(
            ["outbox_id"],
            [f"{COMMAND_SCHEMA}.itinerary_basic_info_outbox.outbox_id"],
            name="fk_basic_info_receipt_outbox",
            ondelete="RESTRICT",
        ),
        sa.PrimaryKeyConstraint("receipt_id", name="pk_basic_info_receipts"),
        sa.UniqueConstraint("attempt_id", name="uq_basic_info_receipt_attempt"),
        sa.UniqueConstraint("command_id", name="uq_basic_info_receipt_command"),
        sa.UniqueConstraint(
            "tenant_id",
            "idempotency_digest",
            name="uq_basic_info_receipt_idempotency",
        ),
        sa.UniqueConstraint("event_id", name="uq_basic_info_receipt_event"),
        sa.UniqueConstraint("outbox_id", name="uq_basic_info_receipt_outbox"),
        sa.CheckConstraint(
            f"command_type = '{COMMAND_TYPE}'",
            name="ck_basic_info_receipt_type",
        ),
        sa.CheckConstraint(
            "target_digest ~ '^[0-9a-f]{64}$' "
            "AND principal_digest ~ '^[0-9a-f]{64}$' "
            "AND idempotency_digest ~ '^[0-9a-f]{64}$' "
            "AND command_hash ~ '^[0-9a-f]{64}$' "
            "AND policy_digest ~ '^[0-9a-f]{64}$' "
            "AND schema_digest ~ '^[0-9a-f]{64}$'",
            name="ck_basic_info_receipt_digests",
        ),
        sa.CheckConstraint(
            "approval_reference = 'policy:itinerary.basic_info.low-risk:v1'",
            name="ck_basic_info_receipt_policy",
        ),
        sa.CheckConstraint(
            "expected_version >= 0 AND ((state = 'committed' "
            "AND actual_version = expected_version + 1 AND event_id IS NOT NULL "
            "AND outbox_id IS NOT NULL) OR (state IN ('conflict','denied','rejected') "
            "AND actual_version IS NULL AND event_id IS NULL AND outbox_id IS NULL))",
            name="ck_basic_info_receipt_outcome",
        ),
        schema=COMMAND_SCHEMA,
    )

    _execute(f"REVOKE ALL ON SCHEMA {COMMAND_SCHEMA} FROM PUBLIC")
    _execute(f"REVOKE ALL ON ALL TABLES IN SCHEMA {COMMAND_SCHEMA} FROM PUBLIC")
    _execute(
        f"ALTER DEFAULT PRIVILEGES IN SCHEMA {COMMAND_SCHEMA} "
        "REVOKE ALL ON TABLES FROM PUBLIC"
    )
    _execute(
        f"GRANT USAGE ON SCHEMA {COMMAND_SCHEMA} TO "
        "gonow_command_service, gonow_observer"
    )
    for table_name in TENANT_TABLES:
        _execute(f"ALTER TABLE {COMMAND_SCHEMA}.{table_name} ENABLE ROW LEVEL SECURITY")
        _execute(f"ALTER TABLE {COMMAND_SCHEMA}.{table_name} FORCE ROW LEVEL SECURITY")
        _execute(
            f"""
            CREATE POLICY tenant_isolation ON {COMMAND_SCHEMA}.{table_name}
            USING (tenant_id = agent_runtime.current_tenant_id())
            WITH CHECK (tenant_id = agent_runtime.current_tenant_id())
            """
        )

    _execute(
        f"""
        CREATE FUNCTION {COMMAND_SCHEMA}.guard_basic_info_attempt()
        RETURNS trigger LANGUAGE plpgsql SECURITY INVOKER
        SET search_path = pg_catalog, pg_temp AS $$
        BEGIN
          IF TG_OP = 'DELETE' THEN
            RAISE EXCEPTION 'domain_command.attempt_delete_forbidden'
              USING ERRCODE = '23514';
          END IF;
          IF OLD.state <> 'received' OR NEW.state NOT IN
             ('committed','conflict','denied','rejected')
             OR NEW.attempt_id <> OLD.attempt_id
             OR NEW.tenant_id <> OLD.tenant_id
             OR NEW.command_id <> OLD.command_id
             OR NEW.command_type <> OLD.command_type
             OR NEW.target_itinerary_id <> OLD.target_itinerary_id
             OR NEW.target_digest <> OLD.target_digest
             OR NEW.principal_digest <> OLD.principal_digest
             OR NEW.idempotency_digest <> OLD.idempotency_digest
             OR NEW.command_hash <> OLD.command_hash
             OR NEW.policy_digest <> OLD.policy_digest
             OR NEW.schema_digest <> OLD.schema_digest
             OR NEW.expected_version <> OLD.expected_version
             OR NEW.created_at <> OLD.created_at
             OR NEW.resolved_at IS NULL THEN
            RAISE EXCEPTION 'domain_command.attempt_invalid_transition'
              USING ERRCODE = '23514';
          END IF;
          RETURN NEW;
        END;
        $$
        """
    )
    _execute(
        f"""
        CREATE TRIGGER basic_info_attempt_guard
        BEFORE UPDATE OR DELETE ON
          {COMMAND_SCHEMA}.itinerary_basic_info_attempts
        FOR EACH ROW EXECUTE FUNCTION
          {COMMAND_SCHEMA}.guard_basic_info_attempt()
        """
    )
    _execute(
        f"""
        CREATE FUNCTION {COMMAND_SCHEMA}.reject_basic_info_receipt_change()
        RETURNS trigger LANGUAGE plpgsql SECURITY INVOKER
        SET search_path = pg_catalog, pg_temp AS $$
        BEGIN
          RAISE EXCEPTION 'domain_command.receipt_immutable'
            USING ERRCODE = '23514';
        END;
        $$
        """
    )
    _execute(
        f"""
        CREATE TRIGGER basic_info_receipt_immutable
        BEFORE UPDATE OR DELETE ON
          {COMMAND_SCHEMA}.itinerary_basic_info_receipts
        FOR EACH ROW EXECUTE FUNCTION
          {COMMAND_SCHEMA}.reject_basic_info_receipt_change()
        """
    )

    _execute(
        f"GRANT SELECT, INSERT ON {COMMAND_SCHEMA}.itinerary_basic_info_attempts, "
        f"{COMMAND_SCHEMA}.itinerary_basic_info_outbox, "
        f"{COMMAND_SCHEMA}.itinerary_basic_info_receipts TO gonow_command_service"
    )
    _execute(
        f"GRANT UPDATE (state, actual_version, event_id, outbox_id, resolved_at) "
        f"ON {COMMAND_SCHEMA}.itinerary_basic_info_attempts TO gonow_command_service"
    )
    _execute(
        f"GRANT UPDATE (state, attempt_count, available_at, claim_token, claimed_by, "
        f"claimed_until, last_error_code, delivered_at) ON "
        f"{COMMAND_SCHEMA}.itinerary_basic_info_outbox TO gonow_command_service"
    )
    _execute(
        f"GRANT SELECT ON ALL TABLES IN SCHEMA {COMMAND_SCHEMA} TO gonow_observer"
    )


def downgrade() -> None:
    raise RuntimeError(
        "p12d_001_commands is forward-fix only; dropping command evidence or FORCE RLS is forbidden"
    )
