"""Add Thread, Run, Event, and Idempotency runtime control tables.

Revision ID: p03_002_run_event_idempotency
Revises: p03_001_runtime_baseline
Create Date: 2026-08-01 05:30:00+08:00
"""

from collections.abc import Sequence

from alembic import op
import sqlalchemy as sa
from sqlalchemy.dialects import postgresql


revision: str = "p03_002_run_event_idempotency"
down_revision: str | Sequence[str] | None = "p03_001_runtime_baseline"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None

RUNTIME_SCHEMA = "agent_runtime"


def upgrade() -> None:
    op.execute(sa.schema.CreateSchema(RUNTIME_SCHEMA))
    op.create_table(
        "threads",
        sa.Column("thread_id", postgresql.UUID(as_uuid=True), nullable=False),
        sa.Column("tenant_id", sa.String(length=128), nullable=False),
        sa.Column("owner_principal_id", sa.String(length=256), nullable=False),
        sa.Column(
            "created_at",
            sa.DateTime(timezone=True),
            server_default=sa.text("statement_timestamp()"),
            nullable=False,
        ),
        sa.CheckConstraint("length(tenant_id) > 0", name="ck_threads_tenant_nonempty"),
        sa.CheckConstraint(
            "length(owner_principal_id) > 0",
            name="ck_threads_owner_nonempty",
        ),
        sa.PrimaryKeyConstraint("thread_id", name="pk_threads"),
        sa.UniqueConstraint("thread_id", "tenant_id", name="uq_threads_id_tenant"),
        schema=RUNTIME_SCHEMA,
    )
    op.create_index(
        "ix_threads_tenant_created",
        "threads",
        ["tenant_id", "created_at"],
        schema=RUNTIME_SCHEMA,
    )

    op.create_table(
        "runs",
        sa.Column("run_id", postgresql.UUID(as_uuid=True), nullable=False),
        sa.Column("thread_id", postgresql.UUID(as_uuid=True), nullable=False),
        sa.Column("tenant_id", sa.String(length=128), nullable=False),
        sa.Column("principal_id", sa.String(length=256), nullable=False),
        sa.Column("state", sa.String(length=32), nullable=False),
        sa.Column("manifest_digest", sa.String(length=64), nullable=False),
        sa.Column("manifest", postgresql.JSONB(astext_type=sa.Text()), nullable=False),
        sa.Column(
            "next_event_seq",
            sa.BigInteger(),
            server_default=sa.text("1"),
            nullable=False,
        ),
        sa.Column(
            "version",
            sa.BigInteger(),
            server_default=sa.text("0"),
            nullable=False,
        ),
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
            "state IN ('created','queued','running','waiting_input','resuming',"
            "'recovering','cancelling','succeeded','blocked','failed','cancelled')",
            name="ck_runs_state",
        ),
        sa.CheckConstraint(
            "manifest_digest ~ '^[0-9a-f]{64}$'",
            name="ck_runs_manifest_digest",
        ),
        sa.CheckConstraint("next_event_seq >= 1", name="ck_runs_next_event_seq"),
        sa.CheckConstraint("version >= 0", name="ck_runs_version_nonnegative"),
        sa.ForeignKeyConstraint(
            ["thread_id", "tenant_id"],
            [f"{RUNTIME_SCHEMA}.threads.thread_id", f"{RUNTIME_SCHEMA}.threads.tenant_id"],
            name="fk_runs_thread_tenant",
            ondelete="RESTRICT",
        ),
        sa.PrimaryKeyConstraint("run_id", name="pk_runs"),
        sa.UniqueConstraint("run_id", "tenant_id", name="uq_runs_id_tenant"),
        schema=RUNTIME_SCHEMA,
    )
    op.create_index(
        "ix_runs_tenant_thread_created",
        "runs",
        ["tenant_id", "thread_id", "created_at"],
        schema=RUNTIME_SCHEMA,
    )

    op.create_table(
        "events",
        sa.Column("event_id", postgresql.UUID(as_uuid=True), nullable=False),
        sa.Column("run_id", postgresql.UUID(as_uuid=True), nullable=False),
        sa.Column("tenant_id", sa.String(length=128), nullable=False),
        sa.Column("seq", sa.BigInteger(), nullable=False),
        sa.Column("event_type", sa.String(length=127), nullable=False),
        sa.Column("payload", postgresql.JSONB(astext_type=sa.Text()), nullable=False),
        sa.Column("audit_receipt_id", sa.String(length=128), nullable=False),
        sa.Column(
            "created_at",
            sa.DateTime(timezone=True),
            server_default=sa.text("statement_timestamp()"),
            nullable=False,
        ),
        sa.CheckConstraint("seq >= 1", name="ck_events_seq_positive"),
        sa.CheckConstraint(
            "event_type ~ '^[a-z][a-z0-9_.-]{0,126}$'",
            name="ck_events_type",
        ),
        sa.CheckConstraint(
            "length(audit_receipt_id) > 0",
            name="ck_events_audit_receipt_nonempty",
        ),
        sa.ForeignKeyConstraint(
            ["run_id", "tenant_id"],
            [f"{RUNTIME_SCHEMA}.runs.run_id", f"{RUNTIME_SCHEMA}.runs.tenant_id"],
            name="fk_events_run_tenant",
            ondelete="CASCADE",
        ),
        sa.PrimaryKeyConstraint("event_id", name="pk_events"),
        sa.UniqueConstraint("run_id", "seq", name="uq_events_run_seq"),
        schema=RUNTIME_SCHEMA,
    )
    op.create_index(
        "ix_events_run_replay",
        "events",
        ["run_id", "seq"],
        schema=RUNTIME_SCHEMA,
    )
    op.create_index(
        "ix_events_tenant_created",
        "events",
        ["tenant_id", "created_at"],
        schema=RUNTIME_SCHEMA,
    )

    op.create_table(
        "idempotency_records",
        sa.Column("idempotency_id", postgresql.UUID(as_uuid=True), nullable=False),
        sa.Column("tenant_id", sa.String(length=128), nullable=False),
        sa.Column("principal_id", sa.String(length=256), nullable=False),
        sa.Column("request_scope", sa.String(length=128), nullable=False),
        sa.Column("idempotency_key", sa.String(length=128), nullable=False),
        sa.Column("request_hash", sa.String(length=64), nullable=False),
        sa.Column("run_id", postgresql.UUID(as_uuid=True), nullable=False),
        sa.Column(
            "created_at",
            sa.DateTime(timezone=True),
            server_default=sa.text("statement_timestamp()"),
            nullable=False,
        ),
        sa.CheckConstraint(
            "request_hash ~ '^[0-9a-f]{64}$'",
            name="ck_idempotency_request_hash",
        ),
        sa.CheckConstraint(
            "length(idempotency_key) > 0 AND length(request_scope) > 0",
            name="ck_idempotency_key_scope_nonempty",
        ),
        sa.ForeignKeyConstraint(
            ["run_id", "tenant_id"],
            [f"{RUNTIME_SCHEMA}.runs.run_id", f"{RUNTIME_SCHEMA}.runs.tenant_id"],
            name="fk_idempotency_run_tenant",
            ondelete="RESTRICT",
            deferrable=True,
            initially="DEFERRED",
        ),
        sa.PrimaryKeyConstraint("idempotency_id", name="pk_idempotency_records"),
        sa.UniqueConstraint(
            "tenant_id",
            "principal_id",
            "request_scope",
            "idempotency_key",
            name="uq_idempotency_request_key",
        ),
        schema=RUNTIME_SCHEMA,
    )
    op.create_index(
        "ix_idempotency_run",
        "idempotency_records",
        ["run_id"],
        schema=RUNTIME_SCHEMA,
    )

    op.execute(
        sa.text(
            """
            CREATE FUNCTION agent_runtime.enforce_run_state_transition()
            RETURNS trigger
            LANGUAGE plpgsql
            SET search_path = pg_catalog, pg_temp
            AS $$
            BEGIN
              IF NEW.state = OLD.state THEN
                RETURN NEW;
              END IF;
              IF NOT (
                (OLD.state = 'created' AND NEW.state = 'queued') OR
                (OLD.state = 'queued' AND NEW.state IN ('running','cancelling','blocked','failed')) OR
                (OLD.state = 'running' AND NEW.state IN ('waiting_input','recovering','cancelling','succeeded','blocked','failed')) OR
                (OLD.state = 'waiting_input' AND NEW.state IN ('resuming','cancelling','blocked','failed')) OR
                (OLD.state = 'resuming' AND NEW.state IN ('running','cancelling','succeeded','blocked','failed')) OR
                (OLD.state = 'recovering' AND NEW.state IN ('running','cancelling','succeeded','blocked','failed')) OR
                (OLD.state = 'cancelling' AND NEW.state = 'cancelled')
              ) THEN
                RAISE EXCEPTION 'run.state_conflict' USING ERRCODE = '23514';
              END IF;
              NEW.updated_at := statement_timestamp();
              RETURN NEW;
            END;
            $$
            """
        )
    )
    op.execute(
        sa.text(
            """
            CREATE TRIGGER runs_state_transition_guard
            BEFORE UPDATE OF state ON agent_runtime.runs
            FOR EACH ROW EXECUTE FUNCTION agent_runtime.enforce_run_state_transition()
            """
        )
    )
    op.execute(
        sa.text(
            """
            CREATE FUNCTION agent_runtime.assert_run_not_created_at_commit()
            RETURNS trigger
            LANGUAGE plpgsql
            SET search_path = pg_catalog, pg_temp
            AS $$
            DECLARE committed_state text;
            BEGIN
              SELECT state INTO committed_state
                FROM agent_runtime.runs
                WHERE run_id = NEW.run_id;
              IF FOUND AND committed_state = 'created' THEN
                RAISE EXCEPTION 'run.created_not_committable' USING ERRCODE = '23514';
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
            CREATE CONSTRAINT TRIGGER runs_created_commit_guard
            AFTER INSERT OR UPDATE ON agent_runtime.runs
            DEFERRABLE INITIALLY DEFERRED
            FOR EACH ROW EXECUTE FUNCTION agent_runtime.assert_run_not_created_at_commit()
            """
        )
    )


def downgrade() -> None:
    op.execute(sa.text("DROP TRIGGER runs_created_commit_guard ON agent_runtime.runs"))
    op.execute(sa.text("DROP TRIGGER runs_state_transition_guard ON agent_runtime.runs"))
    op.execute(sa.text("DROP FUNCTION agent_runtime.assert_run_not_created_at_commit()"))
    op.execute(sa.text("DROP FUNCTION agent_runtime.enforce_run_state_transition()"))
    op.drop_index("ix_idempotency_run", table_name="idempotency_records", schema=RUNTIME_SCHEMA)
    op.drop_table("idempotency_records", schema=RUNTIME_SCHEMA)
    op.drop_index("ix_events_tenant_created", table_name="events", schema=RUNTIME_SCHEMA)
    op.drop_index("ix_events_run_replay", table_name="events", schema=RUNTIME_SCHEMA)
    op.drop_table("events", schema=RUNTIME_SCHEMA)
    op.drop_index("ix_runs_tenant_thread_created", table_name="runs", schema=RUNTIME_SCHEMA)
    op.drop_table("runs", schema=RUNTIME_SCHEMA)
    op.drop_index("ix_threads_tenant_created", table_name="threads", schema=RUNTIME_SCHEMA)
    op.drop_table("threads", schema=RUNTIME_SCHEMA)
    op.execute(sa.schema.DropSchema(RUNTIME_SCHEMA))
