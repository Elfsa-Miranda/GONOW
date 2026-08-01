"""Add transactional outbox, delivery receipts, and metadata-only dead letters.

Revision ID: p03_006_outbox_receipts
Revises: p03_004_behavior_releases
Create Date: 2026-08-01 06:45:00+08:00
"""

from collections.abc import Sequence

from alembic import op
import sqlalchemy as sa
from sqlalchemy.dialects import postgresql


revision: str = "p03_006_outbox_receipts"
down_revision: str | Sequence[str] | None = "p03_004_behavior_releases"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None

RUNTIME_SCHEMA = "agent_runtime"


def upgrade() -> None:
    op.create_table(
        "outbox_messages",
        sa.Column("outbox_id", postgresql.UUID(as_uuid=True), nullable=False),
        sa.Column("event_id", postgresql.UUID(as_uuid=True), nullable=False),
        sa.Column("tenant_id", sa.String(length=128), nullable=False),
        sa.Column("topic", sa.String(length=127), nullable=False),
        sa.Column("payload_reference", sa.String(length=64), nullable=False),
        sa.Column("payload_digest", sa.String(length=64), nullable=False),
        sa.Column("status", sa.String(length=16), nullable=False),
        sa.Column("attempt_count", sa.BigInteger(), server_default="0", nullable=False),
        sa.Column("max_attempts", sa.BigInteger(), nullable=False),
        sa.Column("available_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("claim_token", postgresql.UUID(as_uuid=True), nullable=True),
        sa.Column("claimed_by", sa.String(length=128), nullable=True),
        sa.Column("claimed_until", sa.DateTime(timezone=True), nullable=True),
        sa.Column("last_error_code", sa.String(length=127), nullable=True),
        sa.Column("audit_receipt_id", sa.String(length=128), nullable=False),
        sa.Column(
            "created_at",
            sa.DateTime(timezone=True),
            server_default=sa.text("statement_timestamp()"),
            nullable=False,
        ),
        sa.Column("delivered_at", sa.DateTime(timezone=True), nullable=True),
        sa.CheckConstraint(
            "status IN ('pending','claimed','delivered','dead_letter')",
            name="ck_outbox_status",
        ),
        sa.CheckConstraint("attempt_count >= 0", name="ck_outbox_attempt_nonnegative"),
        sa.CheckConstraint("max_attempts BETWEEN 1 AND 100", name="ck_outbox_max_attempts"),
        sa.CheckConstraint(
            "payload_digest ~ '^[0-9a-f]{64}$'", name="ck_outbox_payload_digest"
        ),
        sa.CheckConstraint(
            "payload_reference ~ '^runtime-event://[0-9a-f-]{36}$'",
            name="ck_outbox_payload_reference",
        ),
        sa.CheckConstraint(
            "topic ~ '^[a-z][a-z0-9_.-]{0,126}$'", name="ck_outbox_topic"
        ),
        sa.CheckConstraint(
            "length(tenant_id) > 0 AND length(audit_receipt_id) > 0",
            name="ck_outbox_audit",
        ),
        sa.CheckConstraint(
            "(status = 'claimed' AND claim_token IS NOT NULL AND claimed_by IS NOT NULL "
            "AND claimed_until IS NOT NULL) OR "
            "(status <> 'claimed' AND claim_token IS NULL AND claimed_by IS NULL "
            "AND claimed_until IS NULL)",
            name="ck_outbox_claim_shape",
        ),
        sa.CheckConstraint(
            "(status = 'delivered' AND delivered_at IS NOT NULL) OR "
            "(status <> 'delivered' AND delivered_at IS NULL)",
            name="ck_outbox_delivery_shape",
        ),
        sa.ForeignKeyConstraint(
            ["event_id"],
            [f"{RUNTIME_SCHEMA}.events.event_id"],
            name="fk_outbox_event",
            ondelete="CASCADE",
        ),
        sa.PrimaryKeyConstraint("outbox_id", name="pk_outbox_messages"),
        sa.UniqueConstraint("event_id", "topic", name="uq_outbox_event_topic"),
        schema=RUNTIME_SCHEMA,
    )
    op.create_index(
        "ix_outbox_claim",
        "outbox_messages",
        ["status", "available_at", "created_at"],
        schema=RUNTIME_SCHEMA,
    )
    op.create_index(
        "ix_outbox_tenant_event",
        "outbox_messages",
        ["tenant_id", "event_id"],
        schema=RUNTIME_SCHEMA,
    )
    op.create_table(
        "delivery_receipts",
        sa.Column("receipt_id", postgresql.UUID(as_uuid=True), nullable=False),
        sa.Column("outbox_id", postgresql.UUID(as_uuid=True), nullable=False),
        sa.Column("event_id", postgresql.UUID(as_uuid=True), nullable=False),
        sa.Column("consumer_name", sa.String(length=127), nullable=False),
        sa.Column("delivered_by", sa.String(length=128), nullable=False),
        sa.Column("audit_receipt_id", sa.String(length=128), nullable=False),
        sa.Column(
            "delivered_at",
            sa.DateTime(timezone=True),
            server_default=sa.text("statement_timestamp()"),
            nullable=False,
        ),
        sa.CheckConstraint(
            "consumer_name ~ '^[a-z][a-z0-9_.-]{0,126}$'",
            name="ck_delivery_consumer",
        ),
        sa.CheckConstraint(
            "length(delivered_by) > 0 AND length(audit_receipt_id) > 0",
            name="ck_delivery_audit",
        ),
        sa.ForeignKeyConstraint(
            ["outbox_id"],
            [f"{RUNTIME_SCHEMA}.outbox_messages.outbox_id"],
            name="fk_delivery_outbox",
            ondelete="RESTRICT",
        ),
        sa.ForeignKeyConstraint(
            ["event_id"],
            [f"{RUNTIME_SCHEMA}.events.event_id"],
            name="fk_delivery_event",
            ondelete="RESTRICT",
        ),
        sa.PrimaryKeyConstraint("receipt_id", name="pk_delivery_receipts"),
        sa.UniqueConstraint(
            "consumer_name", "event_id", name="uq_delivery_consumer_event"
        ),
        schema=RUNTIME_SCHEMA,
    )
    op.create_index(
        "ix_delivery_outbox",
        "delivery_receipts",
        ["outbox_id"],
        schema=RUNTIME_SCHEMA,
    )
    op.create_table(
        "dead_letters",
        sa.Column("dead_letter_id", postgresql.UUID(as_uuid=True), nullable=False),
        sa.Column("outbox_id", postgresql.UUID(as_uuid=True), nullable=False),
        sa.Column("event_id", postgresql.UUID(as_uuid=True), nullable=False),
        sa.Column("retry_class", sa.String(length=32), nullable=False),
        sa.Column("reason_code", sa.String(length=127), nullable=False),
        sa.Column("attempt_count", sa.BigInteger(), nullable=False),
        sa.Column("audit_receipt_id", sa.String(length=128), nullable=False),
        sa.Column(
            "moved_at",
            sa.DateTime(timezone=True),
            server_default=sa.text("statement_timestamp()"),
            nullable=False,
        ),
        sa.CheckConstraint(
            "retry_class IN ('permanent','exhausted','unknown_outcome')",
            name="ck_dead_letter_retry_class",
        ),
        sa.CheckConstraint(
            "reason_code ~ '^[a-z][a-z0-9_.-]{0,126}$'",
            name="ck_dead_letter_reason",
        ),
        sa.CheckConstraint(
            "attempt_count >= 1 AND length(audit_receipt_id) > 0",
            name="ck_dead_letter_audit",
        ),
        sa.ForeignKeyConstraint(
            ["outbox_id"],
            [f"{RUNTIME_SCHEMA}.outbox_messages.outbox_id"],
            name="fk_dead_letter_outbox",
            ondelete="RESTRICT",
        ),
        sa.ForeignKeyConstraint(
            ["event_id"],
            [f"{RUNTIME_SCHEMA}.events.event_id"],
            name="fk_dead_letter_event",
            ondelete="RESTRICT",
        ),
        sa.PrimaryKeyConstraint("dead_letter_id", name="pk_dead_letters"),
        sa.UniqueConstraint("outbox_id", name="uq_dead_letter_outbox"),
        schema=RUNTIME_SCHEMA,
    )
    op.create_index(
        "ix_dead_letter_event",
        "dead_letters",
        ["event_id"],
        schema=RUNTIME_SCHEMA,
    )
    op.execute(
        sa.text(
            """
            CREATE FUNCTION agent_runtime.guard_outbox_identity()
            RETURNS trigger LANGUAGE plpgsql
            SET search_path = pg_catalog, pg_temp AS $$
            DECLARE event_tenant text;
            BEGIN
              SELECT tenant_id INTO event_tenant FROM agent_runtime.events
                WHERE event_id = NEW.event_id;
              IF NOT FOUND OR event_tenant <> NEW.tenant_id THEN
                RAISE EXCEPTION 'outbox.event_scope_mismatch' USING ERRCODE = '23514';
              END IF;
              IF TG_OP = 'UPDATE' AND (
                NEW.event_id IS DISTINCT FROM OLD.event_id OR
                NEW.tenant_id IS DISTINCT FROM OLD.tenant_id OR
                NEW.topic IS DISTINCT FROM OLD.topic OR
                NEW.payload_reference IS DISTINCT FROM OLD.payload_reference OR
                NEW.payload_digest IS DISTINCT FROM OLD.payload_digest OR
                NEW.max_attempts IS DISTINCT FROM OLD.max_attempts OR
                NEW.audit_receipt_id IS DISTINCT FROM OLD.audit_receipt_id
              ) THEN
                RAISE EXCEPTION 'outbox.identity_immutable' USING ERRCODE = '23514';
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
            CREATE TRIGGER outbox_identity_guard
            BEFORE INSERT OR UPDATE ON agent_runtime.outbox_messages
            FOR EACH ROW EXECUTE FUNCTION agent_runtime.guard_outbox_identity()
            """
        )
    )
    op.execute(
        sa.text(
            """
            CREATE FUNCTION agent_runtime.reject_delivery_metadata_change()
            RETURNS trigger LANGUAGE plpgsql
            SET search_path = pg_catalog, pg_temp AS $$
            BEGIN
              RAISE EXCEPTION 'delivery.metadata_immutable' USING ERRCODE = '23514';
            END;
            $$
            """
        )
    )
    for table_name in ("delivery_receipts", "dead_letters"):
        op.execute(
            sa.text(
                f"""
                CREATE TRIGGER {table_name}_immutable_guard
                BEFORE UPDATE OR DELETE ON agent_runtime.{table_name}
                FOR EACH ROW EXECUTE FUNCTION agent_runtime.reject_delivery_metadata_change()
                """
            )
        )
    op.execute(
        sa.text(
            """
            CREATE FUNCTION agent_runtime.assert_delivery_metadata()
            RETURNS trigger LANGUAGE plpgsql
            SET search_path = pg_catalog, pg_temp AS $$
            DECLARE message_status text; message_event uuid;
            BEGIN
              SELECT status, event_id INTO message_status, message_event
                FROM agent_runtime.outbox_messages WHERE outbox_id = NEW.outbox_id;
              IF NOT FOUND OR message_event <> NEW.event_id THEN
                RAISE EXCEPTION 'delivery.event_mismatch' USING ERRCODE = '23514';
              END IF;
              IF TG_TABLE_NAME = 'delivery_receipts' AND message_status <> 'delivered' THEN
                RAISE EXCEPTION 'delivery.receipt_without_delivery' USING ERRCODE = '23514';
              END IF;
              IF TG_TABLE_NAME = 'dead_letters' AND message_status <> 'dead_letter' THEN
                RAISE EXCEPTION 'delivery.dlq_without_terminal_state' USING ERRCODE = '23514';
              END IF;
              RETURN NULL;
            END;
            $$
            """
        )
    )
    op.execute(
        sa.text(
            """
            CREATE CONSTRAINT TRIGGER delivery_receipt_commit_guard
            AFTER INSERT ON agent_runtime.delivery_receipts
            DEFERRABLE INITIALLY DEFERRED
            FOR EACH ROW EXECUTE FUNCTION agent_runtime.assert_delivery_metadata()
            """
        )
    )
    op.execute(
        sa.text(
            """
            CREATE CONSTRAINT TRIGGER dead_letter_commit_guard
            AFTER INSERT ON agent_runtime.dead_letters
            DEFERRABLE INITIALLY DEFERRED
            FOR EACH ROW EXECUTE FUNCTION agent_runtime.assert_delivery_metadata()
            """
        )
    )


def downgrade() -> None:
    op.execute("DROP TRIGGER dead_letter_commit_guard ON agent_runtime.dead_letters")
    op.execute(
        "DROP TRIGGER delivery_receipt_commit_guard ON agent_runtime.delivery_receipts"
    )
    op.execute("DROP TRIGGER dead_letters_immutable_guard ON agent_runtime.dead_letters")
    op.execute(
        "DROP TRIGGER delivery_receipts_immutable_guard ON agent_runtime.delivery_receipts"
    )
    op.execute("DROP TRIGGER outbox_identity_guard ON agent_runtime.outbox_messages")
    op.execute("DROP FUNCTION agent_runtime.assert_delivery_metadata()")
    op.execute("DROP FUNCTION agent_runtime.reject_delivery_metadata_change()")
    op.execute("DROP FUNCTION agent_runtime.guard_outbox_identity()")
    op.drop_index("ix_dead_letter_event", table_name="dead_letters", schema=RUNTIME_SCHEMA)
    op.drop_table("dead_letters", schema=RUNTIME_SCHEMA)
    op.drop_index(
        "ix_delivery_outbox", table_name="delivery_receipts", schema=RUNTIME_SCHEMA
    )
    op.drop_table("delivery_receipts", schema=RUNTIME_SCHEMA)
    op.drop_index("ix_outbox_tenant_event", table_name="outbox_messages", schema=RUNTIME_SCHEMA)
    op.drop_index("ix_outbox_claim", table_name="outbox_messages", schema=RUNTIME_SCHEMA)
    op.drop_table("outbox_messages", schema=RUNTIME_SCHEMA)
