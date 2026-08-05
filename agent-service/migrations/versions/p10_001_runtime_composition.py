"""Add structured Job inputs, one-use resume capabilities, and Candidates.

Revision ID: p10_001_runtime_composition
Revises: p09_006_domain_commands
Create Date: 2026-08-02 17:00:00+08:00

This additive, forward-fix-only migration supplies persistence required by the
approved API/Worker composition repair. It does not change formal itinerary
tables or enable production allocation.
"""

from collections.abc import Sequence

from alembic import op
import sqlalchemy as sa
from sqlalchemy.dialects import postgresql


revision: str = "p10_001_runtime_composition"
down_revision: str | Sequence[str] | None = "p09_006_domain_commands"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None

RUNTIME_SCHEMA = "agent_runtime"
NEW_TABLES = ("job_inputs", "resume_capabilities", "candidates")


def _execute(statement: str) -> None:
    op.execute(sa.text(statement))


def upgrade() -> None:
    op.create_table(
        "job_inputs",
        sa.Column("input_id", postgresql.UUID(as_uuid=True), nullable=False),
        sa.Column("tenant_id", sa.String(length=128), nullable=False),
        sa.Column("input_ref", sa.String(length=96), nullable=False),
        sa.Column("input_sha256", sa.String(length=64), nullable=False),
        sa.Column("schema_version", sa.String(length=16), nullable=False),
        sa.Column("payload", postgresql.JSONB(astext_type=sa.Text()), nullable=False),
        sa.Column(
            "created_at",
            sa.DateTime(timezone=True),
            server_default=sa.text("statement_timestamp()"),
            nullable=False,
        ),
        sa.Column("expires_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("deletion_requested_at", sa.DateTime(timezone=True), nullable=True),
        sa.PrimaryKeyConstraint("input_id", name="pk_job_inputs"),
        sa.UniqueConstraint(
            "tenant_id", "input_ref", name="uq_job_inputs_tenant_ref"
        ),
        sa.CheckConstraint(
            "input_ref ~ '^job-input://sha256/[0-9a-f]{64}$'",
            name="ck_job_inputs_ref",
        ),
        sa.CheckConstraint(
            "input_sha256 ~ '^[0-9a-f]{64}$'", name="ck_job_inputs_digest"
        ),
        sa.CheckConstraint(
            "schema_version = '1.0'", name="ck_job_inputs_schema_version"
        ),
        sa.CheckConstraint(
            "expires_at > created_at", name="ck_job_inputs_expiry"
        ),
        schema=RUNTIME_SCHEMA,
    )
    op.create_index(
        "ix_job_inputs_tenant_created",
        "job_inputs",
        ["tenant_id", "created_at"],
        schema=RUNTIME_SCHEMA,
    )

    op.create_table(
        "resume_capabilities",
        sa.Column("capability_id", postgresql.UUID(as_uuid=True), nullable=False),
        sa.Column("token_hash", sa.String(length=64), nullable=False),
        sa.Column("nonce", postgresql.UUID(as_uuid=True), nullable=False),
        sa.Column("tenant_id", sa.String(length=128), nullable=False),
        sa.Column("principal_id", sa.String(length=256), nullable=False),
        sa.Column("run_id", postgresql.UUID(as_uuid=True), nullable=False),
        sa.Column("interrupt_id", postgresql.UUID(as_uuid=True), nullable=False),
        sa.Column("command_hash", sa.String(length=64), nullable=False),
        sa.Column("command_version", sa.String(length=32), nullable=False),
        sa.Column("issued_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("expires_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("consumed_at", sa.DateTime(timezone=True), nullable=True),
        sa.ForeignKeyConstraint(
            ["run_id", "tenant_id"],
            [f"{RUNTIME_SCHEMA}.runs.run_id", f"{RUNTIME_SCHEMA}.runs.tenant_id"],
            name="fk_resume_capabilities_run_tenant",
            ondelete="CASCADE",
        ),
        sa.PrimaryKeyConstraint("capability_id", name="pk_resume_capabilities"),
        sa.UniqueConstraint(
            "token_hash", name="uq_resume_capabilities_token_hash"
        ),
        sa.CheckConstraint(
            "token_hash ~ '^[0-9a-f]{64}$' AND "
            "command_hash ~ '^[0-9a-f]{64}$'",
            name="ck_resume_capabilities_hashes",
        ),
        sa.CheckConstraint(
            "command_version ~ '^[0-9]+\\.[0-9]+$'",
            name="ck_resume_capabilities_command_version",
        ),
        sa.CheckConstraint(
            "expires_at > issued_at", name="ck_resume_capabilities_expiry"
        ),
        schema=RUNTIME_SCHEMA,
    )
    op.create_index(
        "ix_resume_capabilities_binding",
        "resume_capabilities",
        ["tenant_id", "principal_id", "run_id", "interrupt_id"],
        schema=RUNTIME_SCHEMA,
    )

    op.create_table(
        "candidates",
        sa.Column("candidate_record_id", postgresql.UUID(as_uuid=True), nullable=False),
        sa.Column("candidate_id", sa.String(length=37), nullable=False),
        sa.Column("candidate_ref", sa.String(length=96), nullable=False),
        sa.Column("candidate_digest", sa.String(length=64), nullable=False),
        sa.Column("tenant_id", sa.String(length=128), nullable=False),
        sa.Column("run_id", postgresql.UUID(as_uuid=True), nullable=False),
        sa.Column("source_job_id", postgresql.UUID(as_uuid=True), nullable=False),
        sa.Column("fencing_token", sa.BigInteger(), nullable=False),
        sa.Column("behavior_digest", sa.String(length=64), nullable=False),
        sa.Column("input_digest", sa.String(length=64), nullable=False),
        sa.Column("schema_version", sa.String(length=16), nullable=False),
        sa.Column("payload", postgresql.JSONB(astext_type=sa.Text()), nullable=False),
        sa.Column(
            "created_at",
            sa.DateTime(timezone=True),
            server_default=sa.text("statement_timestamp()"),
            nullable=False,
        ),
        sa.Column("deletion_requested_at", sa.DateTime(timezone=True), nullable=True),
        sa.ForeignKeyConstraint(
            ["source_job_id", "tenant_id", "run_id"],
            [
                f"{RUNTIME_SCHEMA}.jobs.job_id",
                f"{RUNTIME_SCHEMA}.jobs.tenant_id",
                f"{RUNTIME_SCHEMA}.jobs.run_id",
            ],
            name="fk_candidates_job_tenant_run",
            ondelete="CASCADE",
        ),
        sa.PrimaryKeyConstraint("candidate_record_id", name="pk_candidates"),
        sa.UniqueConstraint("tenant_id", "candidate_id", name="uq_candidates_tenant_id"),
        sa.UniqueConstraint("tenant_id", "run_id", name="uq_candidates_tenant_run"),
        sa.CheckConstraint(
            "candidate_id ~ '^cand_[0-9a-f]{32}$'",
            name="ck_candidates_public_id",
        ),
        sa.CheckConstraint(
            "candidate_digest ~ '^[0-9a-f]{64}$' AND "
            "behavior_digest ~ '^[0-9a-f]{64}$' AND "
            "input_digest ~ '^[0-9a-f]{64}$'",
            name="ck_candidates_digests",
        ),
        sa.CheckConstraint(
            "candidate_ref = 'candidate://sha256/' || candidate_digest",
            name="ck_candidates_ref",
        ),
        sa.CheckConstraint(
            "schema_version = '1.0'", name="ck_candidates_schema_version"
        ),
        sa.CheckConstraint(
            "fencing_token > 0", name="ck_candidates_fence_positive"
        ),
        schema=RUNTIME_SCHEMA,
    )
    op.create_index(
        "ix_candidates_tenant_created",
        "candidates",
        ["tenant_id", "created_at"],
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
        "GRANT SELECT, INSERT ON agent_runtime.job_inputs TO gonow_agent_api"
    )
    _execute("GRANT SELECT ON agent_runtime.job_inputs TO gonow_agent_worker")
    _execute(
        "GRANT SELECT, UPDATE ON agent_runtime.resume_capabilities TO gonow_agent_api"
    )
    _execute(
        "GRANT SELECT, INSERT ON agent_runtime.resume_capabilities TO gonow_agent_worker"
    )
    _execute("GRANT SELECT ON agent_runtime.candidates TO gonow_agent_api")
    _execute("GRANT SELECT, INSERT ON agent_runtime.candidates TO gonow_agent_worker")
    _execute("GRANT SELECT ON agent_runtime.candidates TO gonow_command_service")


def downgrade() -> None:
    raise RuntimeError(
        "p10_001_runtime_composition is forward-fix only; dropping durable input or capability data is forbidden"
    )
