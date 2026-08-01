"""Add strict checkpoint payload and pending-write references.

Revision ID: p05_003_checkpoint_refs
Revises: p03_007_runtime_rls
Create Date: 2026-08-01 13:05:00+08:00
"""

from collections.abc import Sequence

from alembic import op
import sqlalchemy as sa
from sqlalchemy.dialects import postgresql


revision: str = "p05_003_checkpoint_refs"
down_revision: str | Sequence[str] | None = "p03_007_runtime_rls"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None

RUNTIME_SCHEMA = "agent_runtime"
NEW_TABLES = ("checkpoint_payloads", "checkpoint_pending_writes")


def _execute(statement: str) -> None:
    op.execute(sa.text(statement))


def upgrade() -> None:
    op.create_table(
        "checkpoint_payloads",
        sa.Column("tenant_id", sa.String(length=128), nullable=False),
        sa.Column("state_ref", sa.String(length=103), nullable=False),
        sa.Column("state_digest", sa.String(length=64), nullable=False),
        sa.Column("state_schema_digest", sa.String(length=64), nullable=False),
        sa.Column("envelope_version", sa.SmallInteger(), nullable=False),
        sa.Column("payload", postgresql.JSONB(astext_type=sa.Text()), nullable=False),
        sa.Column(
            "created_at",
            sa.DateTime(timezone=True),
            server_default=sa.text("statement_timestamp()"),
            nullable=False,
        ),
        sa.CheckConstraint(
            "state_ref ~ '^checkpoint://sha256/[0-9a-f]{64}$'",
            name="ck_checkpoint_payloads_state_ref",
        ),
        sa.CheckConstraint(
            "state_digest ~ '^[0-9a-f]{64}$' "
            "AND state_schema_digest ~ '^[0-9a-f]{64}$'",
            name="ck_checkpoint_payloads_digests",
        ),
        sa.CheckConstraint(
            "envelope_version IN (1,2)",
            name="ck_checkpoint_payloads_version",
        ),
        sa.PrimaryKeyConstraint(
            "tenant_id",
            "state_ref",
            name="pk_checkpoint_payloads",
        ),
        schema=RUNTIME_SCHEMA,
    )
    op.create_table(
        "checkpoint_pending_writes",
        sa.Column("tenant_id", sa.String(length=128), nullable=False),
        sa.Column(
            "checkpoint_id", postgresql.UUID(as_uuid=True), nullable=False
        ),
        sa.Column("run_id", postgresql.UUID(as_uuid=True), nullable=False),
        sa.Column("task_id", sa.String(length=128), nullable=False),
        sa.Column("task_path", sa.String(length=256), nullable=False),
        sa.Column("write_index", sa.Integer(), nullable=False),
        sa.Column("channel", sa.String(length=128), nullable=False),
        sa.Column("value_json", postgresql.JSONB(astext_type=sa.Text()), nullable=False),
        sa.Column("value_digest", sa.String(length=64), nullable=False),
        sa.Column(
            "created_at",
            sa.DateTime(timezone=True),
            server_default=sa.text("statement_timestamp()"),
            nullable=False,
        ),
        sa.CheckConstraint(
            "write_index >= 0 AND length(task_id) > 0 AND length(channel) > 0",
            name="ck_checkpoint_writes_identity",
        ),
        sa.CheckConstraint(
            "value_digest ~ '^[0-9a-f]{64}$'",
            name="ck_checkpoint_writes_digest",
        ),
        sa.ForeignKeyConstraint(
            ["checkpoint_id", "tenant_id", "run_id"],
            [
                f"{RUNTIME_SCHEMA}.checkpoint_metadata.checkpoint_id",
                f"{RUNTIME_SCHEMA}.checkpoint_metadata.tenant_id",
                f"{RUNTIME_SCHEMA}.checkpoint_metadata.run_id",
            ],
            name="fk_checkpoint_writes_checkpoint_scope",
            ondelete="CASCADE",
        ),
        sa.PrimaryKeyConstraint(
            "tenant_id",
            "checkpoint_id",
            "task_id",
            "write_index",
            name="pk_checkpoint_pending_writes",
        ),
        schema=RUNTIME_SCHEMA,
    )
    op.create_index(
        "ix_checkpoint_writes_checkpoint",
        "checkpoint_pending_writes",
        ["tenant_id", "run_id", "checkpoint_id", "task_id", "write_index"],
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
        "GRANT SELECT, INSERT ON agent_runtime.checkpoint_payloads, "
        "agent_runtime.checkpoint_pending_writes TO gonow_agent_worker"
    )
    _execute(
        "GRANT SELECT ON agent_runtime.checkpoint_payloads, "
        "agent_runtime.checkpoint_pending_writes TO gonow_observer"
    )


def downgrade() -> None:
    op.drop_index(
        "ix_checkpoint_writes_checkpoint",
        table_name="checkpoint_pending_writes",
        schema=RUNTIME_SCHEMA,
    )
    op.drop_table("checkpoint_pending_writes", schema=RUNTIME_SCHEMA)
    op.drop_table("checkpoint_payloads", schema=RUNTIME_SCHEMA)
