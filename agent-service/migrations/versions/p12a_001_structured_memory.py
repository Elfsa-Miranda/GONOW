"""Add dormant tenant/principal-isolated Structured Memory persistence.

Revision ID: p12a_001_memory
Revises: p12d_001_commands
"""

from __future__ import annotations

from alembic import op
import sqlalchemy as sa
from sqlalchemy.dialects import postgresql


revision = "p12a_001_memory"
down_revision = "p12d_001_commands"
branch_labels = None
depends_on = None

SCHEMA = "agent_memory"
TABLES = ("consent_events", "candidates", "records", "derivatives", "tombstones", "command_attempts", "outbox_events")


def _execute(sql: str) -> None:
    op.execute(sa.text(sql))


def _identity_columns() -> list[sa.Column]:
    return [
        sa.Column("tenant_id", sa.String(128), nullable=False),
        sa.Column("principal_id", sa.String(256), nullable=False),
    ]


def upgrade() -> None:
    _execute(f"CREATE SCHEMA IF NOT EXISTS {SCHEMA}")
    _execute(
        f"""CREATE OR REPLACE FUNCTION {SCHEMA}.current_principal_id() RETURNS text
        LANGUAGE sql STABLE AS $$ SELECT nullif(current_setting('app.principal_id', true), '') $$"""
    )

    op.create_table(
        "consent_events",
        sa.Column("consent_event_id", postgresql.UUID(as_uuid=True), primary_key=True),
        *_identity_columns(),
        sa.Column("purpose", sa.String(64), nullable=False),
        sa.Column("state", sa.String(16), nullable=False),
        sa.Column("version", sa.BigInteger(), nullable=False),
        sa.Column("valid_until", sa.DateTime(timezone=True), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), server_default=sa.text("statement_timestamp()"), nullable=False),
        sa.UniqueConstraint("tenant_id", "principal_id", "purpose", "version", name="uq_memory_consent_version"),
        sa.CheckConstraint("purpose = 'itinerary.personalization'", name="ck_memory_consent_purpose"),
        sa.CheckConstraint("state IN ('granted','denied','revoked','expired')", name="ck_memory_consent_state"),
        sa.CheckConstraint("version >= 1", name="ck_memory_consent_version"),
        schema=SCHEMA,
    )
    op.create_table(
        "candidates",
        sa.Column("candidate_id", postgresql.UUID(as_uuid=True), primary_key=True),
        *_identity_columns(),
        sa.Column("purpose", sa.String(64), nullable=False),
        sa.Column("memory_type", sa.String(32), nullable=False),
        sa.Column("enum_value", sa.String(32), nullable=False),
        sa.Column("provenance", postgresql.JSONB(), nullable=False),
        sa.Column("state", sa.String(16), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), server_default=sa.text("statement_timestamp()"), nullable=False),
        sa.CheckConstraint("state IN ('proposed','confirmed','rejected','deleted')", name="ck_memory_candidate_state"),
        schema=SCHEMA,
    )
    op.create_table(
        "records",
        sa.Column("memory_id", postgresql.UUID(as_uuid=True), primary_key=True),
        *_identity_columns(),
        sa.Column("purpose", sa.String(64), nullable=False),
        sa.Column("memory_type", sa.String(32), nullable=False),
        sa.Column("enum_value", sa.String(32), nullable=False),
        sa.Column("provenance", postgresql.JSONB(), nullable=False),
        sa.Column("state", sa.String(16), nullable=False),
        sa.Column("version", sa.BigInteger(), nullable=False),
        sa.Column("consent_version", sa.BigInteger(), nullable=False),
        sa.Column("retention_until", sa.DateTime(timezone=True), nullable=False),
        sa.Column("deletion_generation", sa.BigInteger(), server_default="0", nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), server_default=sa.text("statement_timestamp()"), nullable=False),
        sa.UniqueConstraint("tenant_id", "principal_id", "purpose", "memory_type", name="uq_memory_active_slot"),
        sa.CheckConstraint("purpose = 'itinerary.personalization'", name="ck_memory_record_purpose"),
        sa.CheckConstraint("memory_type IN ('travel_pace','mobility_requirement','dietary_requirement','transport_preference')", name="ck_memory_record_type"),
        sa.CheckConstraint("state IN ('active','conflicted','superseded','revoked','deleted','quarantined')", name="ck_memory_record_state"),
        sa.CheckConstraint("version >= 1 AND consent_version >= 1 AND deletion_generation >= 0", name="ck_memory_record_versions"),
        schema=SCHEMA,
    )
    op.create_index("ix_memory_records_authorized_read", "records", ["tenant_id", "principal_id", "purpose", "state"], schema=SCHEMA)
    op.create_table(
        "derivatives",
        sa.Column("derivative_id", postgresql.UUID(as_uuid=True), primary_key=True),
        sa.Column("memory_id", postgresql.UUID(as_uuid=True), nullable=False),
        *_identity_columns(),
        sa.Column("surface", sa.String(16), nullable=False),
        sa.Column("digest", sa.String(64), nullable=False),
        sa.Column("deleted", sa.Boolean(), server_default=sa.false(), nullable=False),
        sa.UniqueConstraint("tenant_id", "memory_id", "surface", name="uq_memory_derivative_surface"),
        sa.CheckConstraint("surface IN ('index','cache','export','eval_trace','restore_ledger')", name="ck_memory_derivative_surface"),
        sa.CheckConstraint("digest ~ '^[0-9a-f]{64}$'", name="ck_memory_derivative_digest"),
        schema=SCHEMA,
    )
    op.create_table(
        "tombstones",
        sa.Column("tombstone_id", postgresql.UUID(as_uuid=True), primary_key=True),
        sa.Column("memory_id", postgresql.UUID(as_uuid=True), nullable=False),
        *_identity_columns(),
        sa.Column("deletion_generation", sa.BigInteger(), nullable=False),
        sa.Column("reason_code", sa.String(32), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), server_default=sa.text("statement_timestamp()"), nullable=False),
        sa.UniqueConstraint("tenant_id", "memory_id", name="uq_memory_tombstone"),
        sa.CheckConstraint("deletion_generation >= 1", name="ck_memory_tombstone_generation"),
        schema=SCHEMA,
    )
    op.create_table(
        "command_attempts",
        sa.Column("attempt_id", postgresql.UUID(as_uuid=True), primary_key=True),
        *_identity_columns(),
        sa.Column("idempotency_key", sa.String(128), nullable=False),
        sa.Column("request_digest", sa.String(64), nullable=False),
        sa.Column("outcome", sa.String(24), nullable=False),
        sa.Column("receipt", postgresql.JSONB(), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), server_default=sa.text("statement_timestamp()"), nullable=False),
        sa.UniqueConstraint("tenant_id", "principal_id", "idempotency_key", name="uq_memory_command_idempotency"),
        schema=SCHEMA,
    )
    op.create_table(
        "outbox_events",
        sa.Column("event_id", postgresql.UUID(as_uuid=True), primary_key=True),
        *_identity_columns(),
        sa.Column("aggregate_id", postgresql.UUID(as_uuid=True), nullable=False),
        sa.Column("event_type", sa.String(64), nullable=False),
        sa.Column("payload", postgresql.JSONB(), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), server_default=sa.text("statement_timestamp()"), nullable=False),
        schema=SCHEMA,
    )

    for table in TABLES:
        _execute(f"ALTER TABLE {SCHEMA}.{table} ENABLE ROW LEVEL SECURITY")
        _execute(f"ALTER TABLE {SCHEMA}.{table} FORCE ROW LEVEL SECURITY")
        _execute(
            f"""CREATE POLICY tenant_principal_isolation ON {SCHEMA}.{table}
            USING (tenant_id = agent_runtime.current_tenant_id() AND principal_id = {SCHEMA}.current_principal_id())
            WITH CHECK (tenant_id = agent_runtime.current_tenant_id() AND principal_id = {SCHEMA}.current_principal_id())"""
        )
        _execute(f"REVOKE ALL ON {SCHEMA}.{table} FROM PUBLIC")
    _execute(f"GRANT USAGE ON SCHEMA {SCHEMA} TO gonow_agent_api, gonow_agent_worker")
    _execute(f"GRANT SELECT, INSERT, UPDATE ON ALL TABLES IN SCHEMA {SCHEMA} TO gonow_agent_api")
    _execute(f"GRANT SELECT, INSERT ON {SCHEMA}.candidates, {SCHEMA}.outbox_events TO gonow_agent_worker")


def downgrade() -> None:
    for table in reversed(TABLES):
        op.drop_table(table, schema=SCHEMA)
    _execute(f"DROP FUNCTION IF EXISTS {SCHEMA}.current_principal_id()")
    _execute(f"DROP SCHEMA IF EXISTS {SCHEMA}")
