"""Create the tenant-isolated Knowledge schema, ACLs, receipts, and outbox.

Revision ID: p11_002_knowledge_rls_outbox
Revises: p10_001_runtime_composition
Create Date: 2026-08-03 23:10:00+08:00

Service roles are provisioned by infrastructure. The migration validates their
least-privilege shape and never creates a login, database, or production identity.
"""

from collections.abc import Sequence

from alembic import op
import sqlalchemy as sa
from sqlalchemy.dialects import postgresql


revision: str = "p11_002_knowledge_rls_outbox"
down_revision: str | Sequence[str] | None = "p10_001_runtime_composition"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None

KNOWLEDGE_SCHEMA = "agent_knowledge"
ROLES = (
    "gonow_agent_api",
    "gonow_agent_worker",
    "gonow_command_service",
    "gonow_release_operator",
    "gonow_observer",
)
TENANT_TABLES = (
    "sources",
    "source_versions",
    "acl_entries",
    "chunks",
    "manifests",
    "manifest_entries",
    "ingestion_receipts",
    "outbox_messages",
)


def _execute(statement: str) -> None:
    op.execute(sa.text(statement))


def _timestamps() -> tuple[sa.Column, sa.Column]:
    return (
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
    )


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
            RAISE EXCEPTION 'knowledge.required_roles_missing' USING ERRCODE = '42501';
          END IF;
          IF bypass_count <> 0 THEN
            RAISE EXCEPTION 'knowledge.bypass_role_forbidden' USING ERRCODE = '42501';
          END IF;
        END;
        $$
        """
    )
    op.execute(sa.schema.CreateSchema(KNOWLEDGE_SCHEMA))

    created_at, updated_at = _timestamps()
    op.create_table(
        "sources",
        sa.Column("source_id", postgresql.UUID(as_uuid=True), nullable=False),
        sa.Column("tenant_id", sa.String(length=128), nullable=False),
        sa.Column("source_key", sa.String(length=191), nullable=False),
        sa.Column("source_class", sa.String(length=64), nullable=False),
        sa.Column("owner_principal_id", sa.String(length=256), nullable=False),
        sa.Column("license_identifier", sa.String(length=128), nullable=False),
        sa.Column("purpose", sa.String(length=64), nullable=False),
        sa.Column("status", sa.String(length=24), nullable=False),
        sa.Column("audit_receipt_id", sa.String(length=128), nullable=False),
        created_at,
        updated_at,
        sa.PrimaryKeyConstraint("source_id", name="pk_knowledge_sources"),
        sa.UniqueConstraint(
            "source_id", "tenant_id", name="uq_knowledge_source_id_tenant"
        ),
        sa.UniqueConstraint("tenant_id", "source_key", name="uq_knowledge_source_key"),
        sa.CheckConstraint(
            "source_class IN ('first_party_product_knowledge',"
            "'public_licensed_reference','tenant_private_curated')",
            name="ck_knowledge_source_class",
        ),
        sa.CheckConstraint(
            "status IN ('active','suspended','delete_pending','deleted')",
            name="ck_knowledge_source_status",
        ),
        sa.CheckConstraint(
            "source_key ~ '^[a-z][a-z0-9_.:/-]{0,190}$'",
            name="ck_knowledge_source_key",
        ),
        sa.CheckConstraint(
            "length(owner_principal_id) > 0 AND length(license_identifier) > 0 "
            "AND length(audit_receipt_id) > 0",
            name="ck_knowledge_source_authority",
        ),
        schema=KNOWLEDGE_SCHEMA,
    )
    op.create_index(
        "ix_knowledge_sources_tenant_status",
        "sources",
        ["tenant_id", "status", "created_at"],
        schema=KNOWLEDGE_SCHEMA,
    )

    op.create_table(
        "source_versions",
        sa.Column("version_id", postgresql.UUID(as_uuid=True), nullable=False),
        sa.Column("tenant_id", sa.String(length=128), nullable=False),
        sa.Column("source_id", postgresql.UUID(as_uuid=True), nullable=False),
        sa.Column("version_number", sa.BigInteger(), nullable=False),
        sa.Column("content_digest", sa.String(length=64), nullable=False),
        sa.Column("parser_digest", sa.String(length=64), nullable=False),
        sa.Column("object_ref", sa.String(length=96), nullable=False),
        sa.Column("status", sa.String(length=16), nullable=False),
        sa.Column(
            "metadata_payload",
            postgresql.JSONB(astext_type=sa.Text()),
            nullable=False,
        ),
        sa.Column("created_by_principal_id", sa.String(length=256), nullable=False),
        sa.Column("audit_receipt_id", sa.String(length=128), nullable=False),
        sa.Column(
            "created_at",
            sa.DateTime(timezone=True),
            server_default=sa.text("statement_timestamp()"),
            nullable=False,
        ),
        sa.ForeignKeyConstraint(
            ["source_id", "tenant_id"],
            [
                f"{KNOWLEDGE_SCHEMA}.sources.source_id",
                f"{KNOWLEDGE_SCHEMA}.sources.tenant_id",
            ],
            name="fk_knowledge_version_source_tenant",
            ondelete="RESTRICT",
        ),
        sa.PrimaryKeyConstraint("version_id", name="pk_knowledge_source_versions"),
        sa.UniqueConstraint(
            "version_id", "tenant_id", "source_id", name="uq_knowledge_version_identity"
        ),
        sa.UniqueConstraint(
            "tenant_id", "source_id", "version_number", name="uq_knowledge_version_number"
        ),
        sa.UniqueConstraint(
            "tenant_id", "source_id", "content_digest", name="uq_knowledge_version_digest"
        ),
        sa.CheckConstraint("version_number >= 1", name="ck_knowledge_version_positive"),
        sa.CheckConstraint(
            "content_digest ~ '^[0-9a-f]{64}$' AND "
            "parser_digest ~ '^[0-9a-f]{64}$'",
            name="ck_knowledge_version_digests",
        ),
        sa.CheckConstraint(
            "object_ref ~ '^knowledge-object://sha256/[0-9a-f]{64}$'",
            name="ck_knowledge_version_object_ref",
        ),
        sa.CheckConstraint(
            "status IN ('staged','indexed','retired','deleted')",
            name="ck_knowledge_version_status",
        ),
        schema=KNOWLEDGE_SCHEMA,
    )
    op.create_index(
        "ix_knowledge_versions_tenant_source",
        "source_versions",
        ["tenant_id", "source_id", "version_number"],
        schema=KNOWLEDGE_SCHEMA,
    )

    op.create_table(
        "acl_entries",
        sa.Column("acl_entry_id", postgresql.UUID(as_uuid=True), nullable=False),
        sa.Column("tenant_id", sa.String(length=128), nullable=False),
        sa.Column("source_id", postgresql.UUID(as_uuid=True), nullable=False),
        sa.Column("subject_type", sa.String(length=16), nullable=False),
        sa.Column("subject_id", sa.String(length=256), nullable=False),
        sa.Column("permission", sa.String(length=16), nullable=False),
        sa.Column("granted_by_principal_id", sa.String(length=256), nullable=False),
        sa.Column("audit_receipt_id", sa.String(length=128), nullable=False),
        sa.Column(
            "granted_at",
            sa.DateTime(timezone=True),
            server_default=sa.text("statement_timestamp()"),
            nullable=False,
        ),
        sa.Column("revoked_at", sa.DateTime(timezone=True), nullable=True),
        sa.ForeignKeyConstraint(
            ["source_id", "tenant_id"],
            [
                f"{KNOWLEDGE_SCHEMA}.sources.source_id",
                f"{KNOWLEDGE_SCHEMA}.sources.tenant_id",
            ],
            name="fk_knowledge_acl_source_tenant",
            ondelete="CASCADE",
        ),
        sa.PrimaryKeyConstraint("acl_entry_id", name="pk_knowledge_acl_entries"),
        sa.UniqueConstraint(
            "tenant_id",
            "source_id",
            "subject_type",
            "subject_id",
            "permission",
            name="uq_knowledge_acl_grant",
        ),
        sa.CheckConstraint(
            "subject_type IN ('principal','group','tenant') AND permission = 'read'",
            name="ck_knowledge_acl_shape",
        ),
        sa.CheckConstraint(
            "length(subject_id) > 0 AND length(audit_receipt_id) > 0",
            name="ck_knowledge_acl_audit",
        ),
        schema=KNOWLEDGE_SCHEMA,
    )
    op.create_index(
        "ix_knowledge_acl_lookup",
        "acl_entries",
        ["tenant_id", "subject_type", "subject_id", "source_id"],
        schema=KNOWLEDGE_SCHEMA,
    )

    op.create_table(
        "chunks",
        sa.Column("chunk_id", postgresql.UUID(as_uuid=True), nullable=False),
        sa.Column("tenant_id", sa.String(length=128), nullable=False),
        sa.Column("source_id", postgresql.UUID(as_uuid=True), nullable=False),
        sa.Column("version_id", postgresql.UUID(as_uuid=True), nullable=False),
        sa.Column("chunk_ordinal", sa.BigInteger(), nullable=False),
        sa.Column("chunk_digest", sa.String(length=64), nullable=False),
        sa.Column("text_content", sa.Text(), nullable=False),
        sa.Column("token_count", sa.BigInteger(), nullable=False),
        sa.Column(
            "metadata_payload",
            postgresql.JSONB(astext_type=sa.Text()),
            nullable=False,
        ),
        sa.Column(
            "created_at",
            sa.DateTime(timezone=True),
            server_default=sa.text("statement_timestamp()"),
            nullable=False,
        ),
        sa.ForeignKeyConstraint(
            ["version_id", "tenant_id", "source_id"],
            [
                f"{KNOWLEDGE_SCHEMA}.source_versions.version_id",
                f"{KNOWLEDGE_SCHEMA}.source_versions.tenant_id",
                f"{KNOWLEDGE_SCHEMA}.source_versions.source_id",
            ],
            name="fk_knowledge_chunk_version_identity",
            ondelete="CASCADE",
        ),
        sa.PrimaryKeyConstraint("chunk_id", name="pk_knowledge_chunks"),
        sa.UniqueConstraint(
            "chunk_id", "tenant_id", name="uq_knowledge_chunk_id_tenant"
        ),
        sa.UniqueConstraint(
            "tenant_id", "version_id", "chunk_ordinal", name="uq_knowledge_chunk_ordinal"
        ),
        sa.UniqueConstraint(
            "tenant_id", "version_id", "chunk_digest", name="uq_knowledge_chunk_digest"
        ),
        sa.CheckConstraint("chunk_ordinal >= 0", name="ck_knowledge_chunk_ordinal"),
        sa.CheckConstraint("token_count > 0", name="ck_knowledge_chunk_token_count"),
        sa.CheckConstraint(
            "chunk_digest ~ '^[0-9a-f]{64}$' AND length(text_content) > 0",
            name="ck_knowledge_chunk_content",
        ),
        schema=KNOWLEDGE_SCHEMA,
    )
    op.create_index(
        "ix_knowledge_chunks_version",
        "chunks",
        ["tenant_id", "version_id", "chunk_ordinal"],
        schema=KNOWLEDGE_SCHEMA,
    )

    op.create_table(
        "manifests",
        sa.Column("manifest_id", postgresql.UUID(as_uuid=True), nullable=False),
        sa.Column("tenant_id", sa.String(length=128), nullable=False),
        sa.Column("manifest_digest", sa.String(length=64), nullable=False),
        sa.Column("status", sa.String(length=16), nullable=False),
        sa.Column("tokenizer_version", sa.String(length=64), nullable=False),
        sa.Column("embedding_model_ref", sa.String(length=191), nullable=False),
        sa.Column("created_by_principal_id", sa.String(length=256), nullable=False),
        sa.Column("audit_receipt_id", sa.String(length=128), nullable=False),
        sa.Column(
            "created_at",
            sa.DateTime(timezone=True),
            server_default=sa.text("statement_timestamp()"),
            nullable=False,
        ),
        sa.PrimaryKeyConstraint("manifest_id", name="pk_knowledge_manifests"),
        sa.UniqueConstraint(
            "manifest_id", "tenant_id", name="uq_knowledge_manifest_id_tenant"
        ),
        sa.UniqueConstraint(
            "tenant_id", "manifest_digest", name="uq_knowledge_manifest_digest"
        ),
        sa.CheckConstraint(
            "manifest_digest ~ '^[0-9a-f]{64}$'",
            name="ck_knowledge_manifest_digest",
        ),
        sa.CheckConstraint(
            "status IN ('building','ready','retired','quarantined')",
            name="ck_knowledge_manifest_status",
        ),
        sa.CheckConstraint(
            "length(created_by_principal_id) > 0 AND length(audit_receipt_id) > 0",
            name="ck_knowledge_manifest_audit",
        ),
        schema=KNOWLEDGE_SCHEMA,
    )
    op.create_index(
        "ix_knowledge_manifests_tenant_status",
        "manifests",
        ["tenant_id", "status", "created_at"],
        schema=KNOWLEDGE_SCHEMA,
    )

    op.create_table(
        "manifest_entries",
        sa.Column("manifest_entry_id", postgresql.UUID(as_uuid=True), nullable=False),
        sa.Column("tenant_id", sa.String(length=128), nullable=False),
        sa.Column("manifest_id", postgresql.UUID(as_uuid=True), nullable=False),
        sa.Column("chunk_id", postgresql.UUID(as_uuid=True), nullable=False),
        sa.Column("entry_ordinal", sa.BigInteger(), nullable=False),
        sa.ForeignKeyConstraint(
            ["manifest_id", "tenant_id"],
            [
                f"{KNOWLEDGE_SCHEMA}.manifests.manifest_id",
                f"{KNOWLEDGE_SCHEMA}.manifests.tenant_id",
            ],
            name="fk_knowledge_manifest_entry_manifest",
            ondelete="CASCADE",
        ),
        sa.ForeignKeyConstraint(
            ["chunk_id", "tenant_id"],
            [
                f"{KNOWLEDGE_SCHEMA}.chunks.chunk_id",
                f"{KNOWLEDGE_SCHEMA}.chunks.tenant_id",
            ],
            name="fk_knowledge_manifest_entry_chunk",
            ondelete="RESTRICT",
        ),
        sa.PrimaryKeyConstraint(
            "manifest_entry_id", name="pk_knowledge_manifest_entries"
        ),
        sa.UniqueConstraint(
            "tenant_id", "manifest_id", "chunk_id", name="uq_knowledge_manifest_entry"
        ),
        sa.CheckConstraint(
            "entry_ordinal >= 0", name="ck_knowledge_manifest_entry_ordinal"
        ),
        schema=KNOWLEDGE_SCHEMA,
    )
    op.create_index(
        "ix_knowledge_manifest_entries_order",
        "manifest_entries",
        ["tenant_id", "manifest_id", "entry_ordinal"],
        schema=KNOWLEDGE_SCHEMA,
    )

    op.create_table(
        "ingestion_receipts",
        sa.Column("ingestion_receipt_id", postgresql.UUID(as_uuid=True), nullable=False),
        sa.Column("tenant_id", sa.String(length=128), nullable=False),
        sa.Column("source_id", postgresql.UUID(as_uuid=True), nullable=False),
        sa.Column("version_id", postgresql.UUID(as_uuid=True), nullable=False),
        sa.Column("pipeline_digest", sa.String(length=64), nullable=False),
        sa.Column("status", sa.String(length=16), nullable=False),
        sa.Column("chunk_count", sa.BigInteger(), nullable=False),
        sa.Column("failure_code", sa.String(length=127), nullable=True),
        sa.Column("audit_receipt_id", sa.String(length=128), nullable=False),
        sa.Column(
            "completed_at",
            sa.DateTime(timezone=True),
            server_default=sa.text("statement_timestamp()"),
            nullable=False,
        ),
        sa.ForeignKeyConstraint(
            ["version_id", "tenant_id", "source_id"],
            [
                f"{KNOWLEDGE_SCHEMA}.source_versions.version_id",
                f"{KNOWLEDGE_SCHEMA}.source_versions.tenant_id",
                f"{KNOWLEDGE_SCHEMA}.source_versions.source_id",
            ],
            name="fk_knowledge_receipt_version",
            ondelete="RESTRICT",
        ),
        sa.PrimaryKeyConstraint(
            "ingestion_receipt_id", name="pk_knowledge_ingestion_receipts"
        ),
        sa.UniqueConstraint(
            "tenant_id",
            "source_id",
            "version_id",
            "pipeline_digest",
            name="uq_knowledge_ingestion_receipt",
        ),
        sa.CheckConstraint(
            "pipeline_digest ~ '^[0-9a-f]{64}$'",
            name="ck_knowledge_receipt_pipeline",
        ),
        sa.CheckConstraint(
            "status IN ('succeeded','failed')",
            name="ck_knowledge_receipt_status",
        ),
        sa.CheckConstraint("chunk_count >= 0", name="ck_knowledge_receipt_chunks"),
        sa.CheckConstraint(
            "(status = 'failed' AND failure_code IS NOT NULL) OR "
            "(status = 'succeeded' AND failure_code IS NULL)",
            name="ck_knowledge_receipt_failure_shape",
        ),
        schema=KNOWLEDGE_SCHEMA,
    )

    op.create_table(
        "outbox_messages",
        sa.Column("outbox_id", postgresql.UUID(as_uuid=True), nullable=False),
        sa.Column("tenant_id", sa.String(length=128), nullable=False),
        sa.Column("event_type", sa.String(length=127), nullable=False),
        sa.Column("aggregate_type", sa.String(length=16), nullable=False),
        sa.Column("aggregate_id", postgresql.UUID(as_uuid=True), nullable=False),
        sa.Column("idempotency_key", sa.String(length=191), nullable=False),
        sa.Column("payload_ref", sa.String(length=96), nullable=False),
        sa.Column("payload_digest", sa.String(length=64), nullable=False),
        sa.Column("status", sa.String(length=16), nullable=False),
        sa.Column("attempt_count", sa.BigInteger(), nullable=False),
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
        sa.PrimaryKeyConstraint("outbox_id", name="pk_knowledge_outbox_messages"),
        sa.UniqueConstraint(
            "tenant_id", "idempotency_key", name="uq_knowledge_outbox_key"
        ),
        sa.CheckConstraint(
            "event_type ~ '^[a-z][a-z0-9_.-]{0,126}$'",
            name="ck_knowledge_outbox_event_type",
        ),
        sa.CheckConstraint(
            "aggregate_type IN ('source','version','manifest','deletion')",
            name="ck_knowledge_outbox_aggregate",
        ),
        sa.CheckConstraint(
            "payload_digest ~ '^[0-9a-f]{64}$' AND "
            "payload_ref ~ '^knowledge-event://sha256/[0-9a-f]{64}$'",
            name="ck_knowledge_outbox_payload",
        ),
        sa.CheckConstraint(
            "status IN ('pending','claimed','delivered','dead_letter')",
            name="ck_knowledge_outbox_status",
        ),
        sa.CheckConstraint(
            "attempt_count >= 0 AND max_attempts BETWEEN 1 AND 10",
            name="ck_knowledge_outbox_attempts",
        ),
        sa.CheckConstraint(
            "(status = 'claimed' AND claim_token IS NOT NULL AND claimed_by IS NOT NULL "
            "AND claimed_until IS NOT NULL) OR "
            "(status <> 'claimed' AND claim_token IS NULL AND claimed_by IS NULL "
            "AND claimed_until IS NULL)",
            name="ck_knowledge_outbox_claim_shape",
        ),
        schema=KNOWLEDGE_SCHEMA,
    )
    op.create_index(
        "ix_knowledge_outbox_claim",
        "outbox_messages",
        ["status", "available_at", "created_at"],
        schema=KNOWLEDGE_SCHEMA,
    )
    op.create_index(
        "ix_knowledge_outbox_tenant_event",
        "outbox_messages",
        ["tenant_id", "event_type", "created_at"],
        schema=KNOWLEDGE_SCHEMA,
    )

    _execute(f"REVOKE ALL ON SCHEMA {KNOWLEDGE_SCHEMA} FROM PUBLIC")
    _execute(f"REVOKE ALL ON ALL TABLES IN SCHEMA {KNOWLEDGE_SCHEMA} FROM PUBLIC")
    _execute(
        f"ALTER DEFAULT PRIVILEGES IN SCHEMA {KNOWLEDGE_SCHEMA} "
        "REVOKE ALL ON TABLES FROM PUBLIC"
    )
    _execute(
        f"GRANT USAGE ON SCHEMA {KNOWLEDGE_SCHEMA} TO "
        "gonow_agent_api, gonow_agent_worker, gonow_command_service, "
        "gonow_release_operator"
    )
    for table_name in TENANT_TABLES:
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

    _execute(
        f"GRANT SELECT ON ALL TABLES IN SCHEMA {KNOWLEDGE_SCHEMA} "
        "TO gonow_agent_api, gonow_agent_worker"
    )
    _execute(
        f"GRANT INSERT, UPDATE ON ALL TABLES IN SCHEMA {KNOWLEDGE_SCHEMA} "
        "TO gonow_agent_worker"
    )
    _execute(
        f"GRANT SELECT ON {KNOWLEDGE_SCHEMA}.sources, "
        f"{KNOWLEDGE_SCHEMA}.source_versions, {KNOWLEDGE_SCHEMA}.chunks, "
        f"{KNOWLEDGE_SCHEMA}.manifests, {KNOWLEDGE_SCHEMA}.manifest_entries "
        "TO gonow_release_operator"
    )
    _execute(
        f"GRANT INSERT, UPDATE ON {KNOWLEDGE_SCHEMA}.manifests, "
        f"{KNOWLEDGE_SCHEMA}.manifest_entries TO gonow_release_operator"
    )
    _execute(
        f"GRANT SELECT ON {KNOWLEDGE_SCHEMA}.sources, "
        f"{KNOWLEDGE_SCHEMA}.source_versions, {KNOWLEDGE_SCHEMA}.chunks, "
        f"{KNOWLEDGE_SCHEMA}.ingestion_receipts, {KNOWLEDGE_SCHEMA}.outbox_messages "
        "TO gonow_command_service"
    )
    _execute(
        f"GRANT UPDATE ON {KNOWLEDGE_SCHEMA}.sources, "
        f"{KNOWLEDGE_SCHEMA}.source_versions, {KNOWLEDGE_SCHEMA}.outbox_messages "
        "TO gonow_command_service"
    )


def downgrade() -> None:
    raise RuntimeError(
        "p11_002_knowledge_rls_outbox is forward-fix only; dropping tenant knowledge or FORCE RLS is forbidden"
    )
