"""Add irreversible Knowledge deletion tombstones and surface receipts.

Revision ID: p11_008_knowledge_tombstones
Revises: p11_004_pgvector_fts
"""

from __future__ import annotations

from alembic import op
import sqlalchemy as sa
from sqlalchemy.dialects import postgresql


revision = "p11_008_knowledge_tombstones"
down_revision = "p11_004_pgvector_fts"
branch_labels = None
depends_on = None

KNOWLEDGE_SCHEMA = "agent_knowledge"
DELETION_TABLES = (
    "deletion_requests",
    "deletion_tombstones",
    "deletion_surface_receipts",
)
GUARDED_TABLES = (
    "sources",
    "source_versions",
    "chunks",
    "acl_entries",
    "ingestion_receipts",
)


def _execute(statement: str) -> None:
    op.execute(sa.text(statement))


def upgrade() -> None:
    op.create_table(
        "deletion_requests",
        sa.Column("deletion_id", postgresql.UUID(as_uuid=True), nullable=False),
        sa.Column("tenant_id", sa.String(length=128), nullable=False),
        sa.Column("source_id", postgresql.UUID(as_uuid=True), nullable=False),
        sa.Column("request_digest", sa.String(length=64), nullable=False),
        sa.Column("status", sa.String(length=24), nullable=False),
        sa.Column("requested_by_principal_id", sa.String(length=256), nullable=False),
        sa.Column("audit_receipt_id", sa.String(length=128), nullable=False),
        sa.Column(
            "requested_at",
            sa.DateTime(timezone=True),
            server_default=sa.text("statement_timestamp()"),
            nullable=False,
        ),
        sa.Column("completed_at", sa.DateTime(timezone=True), nullable=True),
        sa.ForeignKeyConstraint(
            ["source_id", "tenant_id"],
            [
                f"{KNOWLEDGE_SCHEMA}.sources.source_id",
                f"{KNOWLEDGE_SCHEMA}.sources.tenant_id",
            ],
            name="fk_knowledge_deletion_source_tenant",
            ondelete="RESTRICT",
        ),
        sa.PrimaryKeyConstraint("deletion_id", name="pk_knowledge_deletion_requests"),
        sa.UniqueConstraint(
            "deletion_id",
            "tenant_id",
            "source_id",
            name="uq_knowledge_deletion_identity",
        ),
        sa.UniqueConstraint(
            "tenant_id", "source_id", name="uq_knowledge_deletion_source"
        ),
        sa.CheckConstraint(
            "request_digest ~ '^[0-9a-f]{64}$'",
            name="ck_knowledge_deletion_request_digest",
        ),
        sa.CheckConstraint(
            "status IN ('requested','fanout_pending','verifying','completed','failed')",
            name="ck_knowledge_deletion_request_status",
        ),
        schema=KNOWLEDGE_SCHEMA,
    )
    op.create_index(
        "ix_knowledge_deletion_status",
        "deletion_requests",
        ["tenant_id", "status", "requested_at"],
        schema=KNOWLEDGE_SCHEMA,
    )

    op.create_table(
        "deletion_tombstones",
        sa.Column("tombstone_id", postgresql.UUID(as_uuid=True), nullable=False),
        sa.Column("deletion_id", postgresql.UUID(as_uuid=True), nullable=False),
        sa.Column("tenant_id", sa.String(length=128), nullable=False),
        sa.Column("source_id", postgresql.UUID(as_uuid=True), nullable=False),
        sa.Column("tombstone_digest", sa.String(length=64), nullable=False),
        sa.Column("deletion_generation", sa.BigInteger(), nullable=False),
        sa.Column("audit_receipt_id", sa.String(length=128), nullable=False),
        sa.Column(
            "created_at",
            sa.DateTime(timezone=True),
            server_default=sa.text("statement_timestamp()"),
            nullable=False,
        ),
        sa.ForeignKeyConstraint(
            ["deletion_id", "tenant_id", "source_id"],
            [
                f"{KNOWLEDGE_SCHEMA}.deletion_requests.deletion_id",
                f"{KNOWLEDGE_SCHEMA}.deletion_requests.tenant_id",
                f"{KNOWLEDGE_SCHEMA}.deletion_requests.source_id",
            ],
            name="fk_knowledge_tombstone_deletion_identity",
            ondelete="RESTRICT",
        ),
        sa.PrimaryKeyConstraint(
            "tombstone_id", name="pk_knowledge_deletion_tombstones"
        ),
        sa.UniqueConstraint(
            "tenant_id", "source_id", name="uq_knowledge_tombstone_source"
        ),
        sa.CheckConstraint(
            "tombstone_digest ~ '^[0-9a-f]{64}$' AND deletion_generation >= 1",
            name="ck_knowledge_tombstone_identity",
        ),
        schema=KNOWLEDGE_SCHEMA,
    )

    op.create_table(
        "deletion_surface_receipts",
        sa.Column("surface_receipt_id", postgresql.UUID(as_uuid=True), nullable=False),
        sa.Column("deletion_id", postgresql.UUID(as_uuid=True), nullable=False),
        sa.Column("tenant_id", sa.String(length=128), nullable=False),
        sa.Column("source_id", postgresql.UUID(as_uuid=True), nullable=False),
        sa.Column("surface_name", sa.String(length=16), nullable=False),
        sa.Column("status", sa.String(length=16), nullable=False),
        sa.Column("attempt_count", sa.BigInteger(), nullable=False),
        sa.Column("evidence_digest", sa.String(length=64), nullable=True),
        sa.Column("audit_receipt_id", sa.String(length=128), nullable=False),
        sa.Column(
            "updated_at",
            sa.DateTime(timezone=True),
            server_default=sa.text("statement_timestamp()"),
            nullable=False,
        ),
        sa.ForeignKeyConstraint(
            ["deletion_id", "tenant_id", "source_id"],
            [
                f"{KNOWLEDGE_SCHEMA}.deletion_requests.deletion_id",
                f"{KNOWLEDGE_SCHEMA}.deletion_requests.tenant_id",
                f"{KNOWLEDGE_SCHEMA}.deletion_requests.source_id",
            ],
            name="fk_knowledge_deletion_surface_identity",
            ondelete="RESTRICT",
        ),
        sa.PrimaryKeyConstraint(
            "surface_receipt_id", name="pk_knowledge_deletion_surface_receipts"
        ),
        sa.UniqueConstraint(
            "tenant_id",
            "deletion_id",
            "surface_name",
            name="uq_knowledge_deletion_surface",
        ),
        sa.CheckConstraint(
            "surface_name IN ('source','chunk','vector','cache','eval','backup')",
            name="ck_knowledge_deletion_surface_name",
        ),
        sa.CheckConstraint(
            "status IN ('pending','purged','verified','failed')",
            name="ck_knowledge_deletion_surface_status",
        ),
        sa.CheckConstraint(
            "attempt_count >= 0 AND (evidence_digest IS NULL OR "
            "evidence_digest ~ '^[0-9a-f]{64}$')",
            name="ck_knowledge_deletion_surface_evidence",
        ),
        schema=KNOWLEDGE_SCHEMA,
    )
    op.create_index(
        "ix_knowledge_deletion_surface_pending",
        "deletion_surface_receipts",
        ["tenant_id", "status", "updated_at"],
        schema=KNOWLEDGE_SCHEMA,
    )

    for table_name in DELETION_TABLES:
        _execute(
            f"ALTER TABLE {KNOWLEDGE_SCHEMA}.{table_name} ENABLE ROW LEVEL SECURITY"
        )
        _execute(
            f"ALTER TABLE {KNOWLEDGE_SCHEMA}.{table_name} FORCE ROW LEVEL SECURITY"
        )
        _execute(
            f"""
            CREATE POLICY tenant_isolation ON {KNOWLEDGE_SCHEMA}.{table_name}
            USING (tenant_id = agent_runtime.current_tenant_id())
            WITH CHECK (tenant_id = agent_runtime.current_tenant_id())
            """
        )
        _execute(f"REVOKE ALL ON {KNOWLEDGE_SCHEMA}.{table_name} FROM PUBLIC")

    _execute(
        f"""
        CREATE FUNCTION {KNOWLEDGE_SCHEMA}.block_tombstoned_source_writes()
        RETURNS trigger
        LANGUAGE plpgsql
        SECURITY DEFINER
        SET search_path = pg_catalog, {KNOWLEDGE_SCHEMA}
        AS $guard$
        BEGIN
          IF TG_TABLE_NAME = 'sources' AND NEW.status = 'deleted' THEN
            RETURN NEW;
          END IF;
          IF EXISTS (
            SELECT 1 FROM {KNOWLEDGE_SCHEMA}.deletion_tombstones AS tombstone
            WHERE tombstone.tenant_id = NEW.tenant_id
              AND tombstone.source_id = NEW.source_id
          ) THEN
            RAISE EXCEPTION 'knowledge.deleted_source_cannot_be_restored'
              USING ERRCODE = '55000';
          END IF;
          RETURN NEW;
        END
        $guard$
        """
    )
    for table_name in GUARDED_TABLES:
        _execute(
            f"""
            CREATE TRIGGER trg_{table_name}_tombstone_guard
            BEFORE INSERT OR UPDATE ON {KNOWLEDGE_SCHEMA}.{table_name}
            FOR EACH ROW EXECUTE FUNCTION
              {KNOWLEDGE_SCHEMA}.block_tombstoned_source_writes()
            """
        )

    _execute(
        f"GRANT SELECT, INSERT, UPDATE ON "
        f"{KNOWLEDGE_SCHEMA}.deletion_requests, "
        f"{KNOWLEDGE_SCHEMA}.deletion_tombstones, "
        f"{KNOWLEDGE_SCHEMA}.deletion_surface_receipts TO gonow_command_service"
    )
    _execute(
        f"GRANT SELECT, UPDATE ON {KNOWLEDGE_SCHEMA}.deletion_requests, "
        f"{KNOWLEDGE_SCHEMA}.deletion_surface_receipts TO gonow_agent_worker"
    )
    _execute(
        f"GRANT SELECT ON {KNOWLEDGE_SCHEMA}.deletion_tombstones "
        "TO gonow_agent_api, gonow_agent_worker"
    )


def downgrade() -> None:
    raise RuntimeError(
        "P11-008 is forward-fix only; deletion tombstones must never be rolled back"
    )
