"""Tenant-isolated Knowledge records for ingestion, retrieval, and audit."""

from __future__ import annotations

import uuid
from datetime import datetime
from typing import Any

from sqlalchemy import (
    BigInteger,
    CheckConstraint,
    DateTime,
    ForeignKeyConstraint,
    Index,
    String,
    Text,
    UniqueConstraint,
    func,
)
from sqlalchemy.dialects.postgresql import JSONB, UUID
from sqlalchemy.orm import Mapped, mapped_column

from app.persistence.models.runtime import RuntimeBase


KNOWLEDGE_SCHEMA = "agent_knowledge"


class KnowledgeSourceRecord(RuntimeBase):
    __tablename__ = "sources"
    __table_args__ = (
        UniqueConstraint("source_id", "tenant_id", name="uq_knowledge_source_id_tenant"),
        UniqueConstraint("tenant_id", "source_key", name="uq_knowledge_source_key"),
        CheckConstraint(
            "source_class IN ('first_party_product_knowledge',"
            "'public_licensed_reference','tenant_private_curated')",
            name="ck_knowledge_source_class",
        ),
        CheckConstraint(
            "status IN ('active','suspended','delete_pending','deleted')",
            name="ck_knowledge_source_status",
        ),
        CheckConstraint(
            "source_key ~ '^[a-z][a-z0-9_.:/-]{0,190}$'",
            name="ck_knowledge_source_key",
        ),
        CheckConstraint(
            "length(owner_principal_id) > 0 AND length(license_identifier) > 0 "
            "AND length(audit_receipt_id) > 0",
            name="ck_knowledge_source_authority",
        ),
        Index("ix_knowledge_sources_tenant_status", "tenant_id", "status", "created_at"),
        {"schema": KNOWLEDGE_SCHEMA},
    )

    source_id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), primary_key=True)
    tenant_id: Mapped[str] = mapped_column(String(128), nullable=False)
    source_key: Mapped[str] = mapped_column(String(191), nullable=False)
    source_class: Mapped[str] = mapped_column(String(64), nullable=False)
    owner_principal_id: Mapped[str] = mapped_column(String(256), nullable=False)
    license_identifier: Mapped[str] = mapped_column(String(128), nullable=False)
    purpose: Mapped[str] = mapped_column(String(64), nullable=False)
    status: Mapped[str] = mapped_column(String(24), nullable=False)
    audit_receipt_id: Mapped[str] = mapped_column(String(128), nullable=False)
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False, server_default=func.statement_timestamp()
    )
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False, server_default=func.statement_timestamp()
    )


class KnowledgeSourceVersionRecord(RuntimeBase):
    __tablename__ = "source_versions"
    __table_args__ = (
        ForeignKeyConstraint(
            ["source_id", "tenant_id"],
            [
                f"{KNOWLEDGE_SCHEMA}.sources.source_id",
                f"{KNOWLEDGE_SCHEMA}.sources.tenant_id",
            ],
            name="fk_knowledge_version_source_tenant",
            ondelete="RESTRICT",
        ),
        UniqueConstraint(
            "version_id", "tenant_id", "source_id", name="uq_knowledge_version_identity"
        ),
        UniqueConstraint(
            "tenant_id", "source_id", "version_number", name="uq_knowledge_version_number"
        ),
        UniqueConstraint(
            "tenant_id", "source_id", "content_digest", name="uq_knowledge_version_digest"
        ),
        CheckConstraint("version_number >= 1", name="ck_knowledge_version_positive"),
        CheckConstraint(
            "content_digest ~ '^[0-9a-f]{64}$' AND "
            "parser_digest ~ '^[0-9a-f]{64}$'",
            name="ck_knowledge_version_digests",
        ),
        CheckConstraint(
            "object_ref ~ '^knowledge-object://sha256/[0-9a-f]{64}$'",
            name="ck_knowledge_version_object_ref",
        ),
        CheckConstraint(
            "status IN ('staged','indexed','retired','deleted')",
            name="ck_knowledge_version_status",
        ),
        Index(
            "ix_knowledge_versions_tenant_source",
            "tenant_id",
            "source_id",
            "version_number",
        ),
        {"schema": KNOWLEDGE_SCHEMA},
    )

    version_id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), primary_key=True)
    tenant_id: Mapped[str] = mapped_column(String(128), nullable=False)
    source_id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), nullable=False)
    version_number: Mapped[int] = mapped_column(BigInteger, nullable=False)
    content_digest: Mapped[str] = mapped_column(String(64), nullable=False)
    parser_digest: Mapped[str] = mapped_column(String(64), nullable=False)
    object_ref: Mapped[str] = mapped_column(String(96), nullable=False)
    status: Mapped[str] = mapped_column(String(16), nullable=False)
    metadata_payload: Mapped[dict[str, Any]] = mapped_column(JSONB, nullable=False)
    created_by_principal_id: Mapped[str] = mapped_column(String(256), nullable=False)
    audit_receipt_id: Mapped[str] = mapped_column(String(128), nullable=False)
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False, server_default=func.statement_timestamp()
    )


class KnowledgeAclEntryRecord(RuntimeBase):
    __tablename__ = "acl_entries"
    __table_args__ = (
        ForeignKeyConstraint(
            ["source_id", "tenant_id"],
            [
                f"{KNOWLEDGE_SCHEMA}.sources.source_id",
                f"{KNOWLEDGE_SCHEMA}.sources.tenant_id",
            ],
            name="fk_knowledge_acl_source_tenant",
            ondelete="CASCADE",
        ),
        UniqueConstraint(
            "tenant_id",
            "source_id",
            "subject_type",
            "subject_id",
            "permission",
            name="uq_knowledge_acl_grant",
        ),
        CheckConstraint(
            "subject_type IN ('principal','group','tenant') AND permission = 'read'",
            name="ck_knowledge_acl_shape",
        ),
        CheckConstraint(
            "length(subject_id) > 0 AND length(audit_receipt_id) > 0",
            name="ck_knowledge_acl_audit",
        ),
        Index(
            "ix_knowledge_acl_lookup",
            "tenant_id",
            "subject_type",
            "subject_id",
            "source_id",
        ),
        {"schema": KNOWLEDGE_SCHEMA},
    )

    acl_entry_id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), primary_key=True)
    tenant_id: Mapped[str] = mapped_column(String(128), nullable=False)
    source_id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), nullable=False)
    subject_type: Mapped[str] = mapped_column(String(16), nullable=False)
    subject_id: Mapped[str] = mapped_column(String(256), nullable=False)
    permission: Mapped[str] = mapped_column(String(16), nullable=False)
    granted_by_principal_id: Mapped[str] = mapped_column(String(256), nullable=False)
    audit_receipt_id: Mapped[str] = mapped_column(String(128), nullable=False)
    granted_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False, server_default=func.statement_timestamp()
    )
    revoked_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)


class KnowledgeChunkRecord(RuntimeBase):
    __tablename__ = "chunks"
    __table_args__ = (
        ForeignKeyConstraint(
            ["version_id", "tenant_id", "source_id"],
            [
                f"{KNOWLEDGE_SCHEMA}.source_versions.version_id",
                f"{KNOWLEDGE_SCHEMA}.source_versions.tenant_id",
                f"{KNOWLEDGE_SCHEMA}.source_versions.source_id",
            ],
            name="fk_knowledge_chunk_version_identity",
            ondelete="CASCADE",
        ),
        UniqueConstraint("chunk_id", "tenant_id", name="uq_knowledge_chunk_id_tenant"),
        UniqueConstraint(
            "tenant_id", "version_id", "chunk_ordinal", name="uq_knowledge_chunk_ordinal"
        ),
        UniqueConstraint(
            "tenant_id", "version_id", "chunk_digest", name="uq_knowledge_chunk_digest"
        ),
        CheckConstraint("chunk_ordinal >= 0", name="ck_knowledge_chunk_ordinal"),
        CheckConstraint("token_count > 0", name="ck_knowledge_chunk_token_count"),
        CheckConstraint(
            "chunk_digest ~ '^[0-9a-f]{64}$' AND length(text_content) > 0",
            name="ck_knowledge_chunk_content",
        ),
        Index("ix_knowledge_chunks_version", "tenant_id", "version_id", "chunk_ordinal"),
        {"schema": KNOWLEDGE_SCHEMA},
    )

    chunk_id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), primary_key=True)
    tenant_id: Mapped[str] = mapped_column(String(128), nullable=False)
    source_id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), nullable=False)
    version_id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), nullable=False)
    chunk_ordinal: Mapped[int] = mapped_column(BigInteger, nullable=False)
    chunk_digest: Mapped[str] = mapped_column(String(64), nullable=False)
    text_content: Mapped[str] = mapped_column(Text, nullable=False)
    token_count: Mapped[int] = mapped_column(BigInteger, nullable=False)
    metadata_payload: Mapped[dict[str, Any]] = mapped_column(JSONB, nullable=False)
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False, server_default=func.statement_timestamp()
    )


class KnowledgeManifestRecord(RuntimeBase):
    __tablename__ = "manifests"
    __table_args__ = (
        UniqueConstraint("manifest_id", "tenant_id", name="uq_knowledge_manifest_id_tenant"),
        UniqueConstraint("tenant_id", "manifest_digest", name="uq_knowledge_manifest_digest"),
        CheckConstraint(
            "manifest_digest ~ '^[0-9a-f]{64}$'",
            name="ck_knowledge_manifest_digest",
        ),
        CheckConstraint(
            "status IN ('building','ready','retired','quarantined')",
            name="ck_knowledge_manifest_status",
        ),
        CheckConstraint(
            "length(created_by_principal_id) > 0 AND length(audit_receipt_id) > 0",
            name="ck_knowledge_manifest_audit",
        ),
        Index("ix_knowledge_manifests_tenant_status", "tenant_id", "status", "created_at"),
        {"schema": KNOWLEDGE_SCHEMA},
    )

    manifest_id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), primary_key=True)
    tenant_id: Mapped[str] = mapped_column(String(128), nullable=False)
    manifest_digest: Mapped[str] = mapped_column(String(64), nullable=False)
    status: Mapped[str] = mapped_column(String(16), nullable=False)
    tokenizer_version: Mapped[str] = mapped_column(String(64), nullable=False)
    embedding_model_ref: Mapped[str] = mapped_column(String(191), nullable=False)
    created_by_principal_id: Mapped[str] = mapped_column(String(256), nullable=False)
    audit_receipt_id: Mapped[str] = mapped_column(String(128), nullable=False)
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False, server_default=func.statement_timestamp()
    )


class KnowledgeManifestEntryRecord(RuntimeBase):
    __tablename__ = "manifest_entries"
    __table_args__ = (
        ForeignKeyConstraint(
            ["manifest_id", "tenant_id"],
            [
                f"{KNOWLEDGE_SCHEMA}.manifests.manifest_id",
                f"{KNOWLEDGE_SCHEMA}.manifests.tenant_id",
            ],
            name="fk_knowledge_manifest_entry_manifest",
            ondelete="CASCADE",
        ),
        ForeignKeyConstraint(
            ["chunk_id", "tenant_id"],
            [
                f"{KNOWLEDGE_SCHEMA}.chunks.chunk_id",
                f"{KNOWLEDGE_SCHEMA}.chunks.tenant_id",
            ],
            name="fk_knowledge_manifest_entry_chunk",
            ondelete="RESTRICT",
        ),
        UniqueConstraint(
            "tenant_id", "manifest_id", "chunk_id", name="uq_knowledge_manifest_entry"
        ),
        CheckConstraint("entry_ordinal >= 0", name="ck_knowledge_manifest_entry_ordinal"),
        Index(
            "ix_knowledge_manifest_entries_order",
            "tenant_id",
            "manifest_id",
            "entry_ordinal",
        ),
        {"schema": KNOWLEDGE_SCHEMA},
    )

    manifest_entry_id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), primary_key=True)
    tenant_id: Mapped[str] = mapped_column(String(128), nullable=False)
    manifest_id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), nullable=False)
    chunk_id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), nullable=False)
    entry_ordinal: Mapped[int] = mapped_column(BigInteger, nullable=False)


class KnowledgeIngestionReceiptRecord(RuntimeBase):
    __tablename__ = "ingestion_receipts"
    __table_args__ = (
        ForeignKeyConstraint(
            ["version_id", "tenant_id", "source_id"],
            [
                f"{KNOWLEDGE_SCHEMA}.source_versions.version_id",
                f"{KNOWLEDGE_SCHEMA}.source_versions.tenant_id",
                f"{KNOWLEDGE_SCHEMA}.source_versions.source_id",
            ],
            name="fk_knowledge_receipt_version",
            ondelete="RESTRICT",
        ),
        UniqueConstraint(
            "tenant_id",
            "source_id",
            "version_id",
            "pipeline_digest",
            name="uq_knowledge_ingestion_receipt",
        ),
        CheckConstraint(
            "pipeline_digest ~ '^[0-9a-f]{64}$'",
            name="ck_knowledge_receipt_pipeline",
        ),
        CheckConstraint(
            "status IN ('succeeded','failed')",
            name="ck_knowledge_receipt_status",
        ),
        CheckConstraint(
            "chunk_count >= 0",
            name="ck_knowledge_receipt_chunk_count",
        ),
        CheckConstraint(
            "(status = 'failed' AND failure_code IS NOT NULL) OR "
            "(status = 'succeeded' AND failure_code IS NULL)",
            name="ck_knowledge_receipt_failure_shape",
        ),
        {"schema": KNOWLEDGE_SCHEMA},
    )

    ingestion_receipt_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), primary_key=True
    )
    tenant_id: Mapped[str] = mapped_column(String(128), nullable=False)
    source_id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), nullable=False)
    version_id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), nullable=False)
    pipeline_digest: Mapped[str] = mapped_column(String(64), nullable=False)
    status: Mapped[str] = mapped_column(String(16), nullable=False)
    chunk_count: Mapped[int] = mapped_column(BigInteger, nullable=False)
    failure_code: Mapped[str | None] = mapped_column(String(127), nullable=True)
    audit_receipt_id: Mapped[str] = mapped_column(String(128), nullable=False)
    completed_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False, server_default=func.statement_timestamp()
    )


class KnowledgeOutboxRecord(RuntimeBase):
    __tablename__ = "outbox_messages"
    __table_args__ = (
        UniqueConstraint("tenant_id", "idempotency_key", name="uq_knowledge_outbox_key"),
        CheckConstraint(
            "event_type ~ '^[a-z][a-z0-9_.-]{0,126}$'",
            name="ck_knowledge_outbox_event_type",
        ),
        CheckConstraint(
            "aggregate_type IN ('source','version','manifest','deletion')",
            name="ck_knowledge_outbox_aggregate",
        ),
        CheckConstraint(
            "payload_digest ~ '^[0-9a-f]{64}$' AND "
            "payload_ref ~ '^knowledge-event://sha256/[0-9a-f]{64}$'",
            name="ck_knowledge_outbox_payload",
        ),
        CheckConstraint(
            "status IN ('pending','claimed','delivered','dead_letter')",
            name="ck_knowledge_outbox_status",
        ),
        CheckConstraint(
            "attempt_count >= 0 AND max_attempts BETWEEN 1 AND 10",
            name="ck_knowledge_outbox_attempts",
        ),
        CheckConstraint(
            "(status = 'claimed' AND claim_token IS NOT NULL AND claimed_by IS NOT NULL "
            "AND claimed_until IS NOT NULL) OR "
            "(status <> 'claimed' AND claim_token IS NULL AND claimed_by IS NULL "
            "AND claimed_until IS NULL)",
            name="ck_knowledge_outbox_claim_shape",
        ),
        Index("ix_knowledge_outbox_claim", "status", "available_at", "created_at"),
        Index("ix_knowledge_outbox_tenant_event", "tenant_id", "event_type", "created_at"),
        {"schema": KNOWLEDGE_SCHEMA},
    )

    outbox_id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), primary_key=True)
    tenant_id: Mapped[str] = mapped_column(String(128), nullable=False)
    event_type: Mapped[str] = mapped_column(String(127), nullable=False)
    aggregate_type: Mapped[str] = mapped_column(String(16), nullable=False)
    aggregate_id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), nullable=False)
    idempotency_key: Mapped[str] = mapped_column(String(191), nullable=False)
    payload_ref: Mapped[str] = mapped_column(String(96), nullable=False)
    payload_digest: Mapped[str] = mapped_column(String(64), nullable=False)
    status: Mapped[str] = mapped_column(String(16), nullable=False)
    attempt_count: Mapped[int] = mapped_column(BigInteger, nullable=False, default=0)
    max_attempts: Mapped[int] = mapped_column(BigInteger, nullable=False)
    available_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)
    claim_token: Mapped[uuid.UUID | None] = mapped_column(UUID(as_uuid=True), nullable=True)
    claimed_by: Mapped[str | None] = mapped_column(String(128), nullable=True)
    claimed_until: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    last_error_code: Mapped[str | None] = mapped_column(String(127), nullable=True)
    audit_receipt_id: Mapped[str] = mapped_column(String(128), nullable=False)
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False, server_default=func.statement_timestamp()
    )
    delivered_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)


class KnowledgeDeletionRequestRecord(RuntimeBase):
    __tablename__ = "deletion_requests"
    __table_args__ = (
        ForeignKeyConstraint(
            ["source_id", "tenant_id"],
            [
                f"{KNOWLEDGE_SCHEMA}.sources.source_id",
                f"{KNOWLEDGE_SCHEMA}.sources.tenant_id",
            ],
            name="fk_knowledge_deletion_source_tenant",
            ondelete="RESTRICT",
        ),
        UniqueConstraint(
            "deletion_id",
            "tenant_id",
            "source_id",
            name="uq_knowledge_deletion_identity",
        ),
        UniqueConstraint(
            "tenant_id", "source_id", name="uq_knowledge_deletion_source"
        ),
        CheckConstraint(
            "request_digest ~ '^[0-9a-f]{64}$'",
            name="ck_knowledge_deletion_request_digest",
        ),
        CheckConstraint(
            "status IN ('requested','fanout_pending','verifying','completed','failed')",
            name="ck_knowledge_deletion_request_status",
        ),
        Index(
            "ix_knowledge_deletion_status",
            "tenant_id",
            "status",
            "requested_at",
        ),
        {"schema": KNOWLEDGE_SCHEMA},
    )

    deletion_id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), primary_key=True)
    tenant_id: Mapped[str] = mapped_column(String(128), nullable=False)
    source_id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), nullable=False)
    request_digest: Mapped[str] = mapped_column(String(64), nullable=False)
    status: Mapped[str] = mapped_column(String(24), nullable=False)
    requested_by_principal_id: Mapped[str] = mapped_column(String(256), nullable=False)
    audit_receipt_id: Mapped[str] = mapped_column(String(128), nullable=False)
    requested_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False, server_default=func.statement_timestamp()
    )
    completed_at: Mapped[datetime | None] = mapped_column(
        DateTime(timezone=True), nullable=True
    )


class KnowledgeDeletionTombstoneRecord(RuntimeBase):
    __tablename__ = "deletion_tombstones"
    __table_args__ = (
        ForeignKeyConstraint(
            ["deletion_id", "tenant_id", "source_id"],
            [
                f"{KNOWLEDGE_SCHEMA}.deletion_requests.deletion_id",
                f"{KNOWLEDGE_SCHEMA}.deletion_requests.tenant_id",
                f"{KNOWLEDGE_SCHEMA}.deletion_requests.source_id",
            ],
            name="fk_knowledge_tombstone_deletion_identity",
            ondelete="RESTRICT",
        ),
        UniqueConstraint(
            "tenant_id", "source_id", name="uq_knowledge_tombstone_source"
        ),
        CheckConstraint(
            "tombstone_digest ~ '^[0-9a-f]{64}$' AND deletion_generation >= 1",
            name="ck_knowledge_tombstone_identity",
        ),
        {"schema": KNOWLEDGE_SCHEMA},
    )

    tombstone_id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), primary_key=True)
    deletion_id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), nullable=False)
    tenant_id: Mapped[str] = mapped_column(String(128), nullable=False)
    source_id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), nullable=False)
    tombstone_digest: Mapped[str] = mapped_column(String(64), nullable=False)
    deletion_generation: Mapped[int] = mapped_column(BigInteger, nullable=False)
    audit_receipt_id: Mapped[str] = mapped_column(String(128), nullable=False)
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False, server_default=func.statement_timestamp()
    )


class KnowledgeDeletionSurfaceRecord(RuntimeBase):
    __tablename__ = "deletion_surface_receipts"
    __table_args__ = (
        ForeignKeyConstraint(
            ["deletion_id", "tenant_id", "source_id"],
            [
                f"{KNOWLEDGE_SCHEMA}.deletion_requests.deletion_id",
                f"{KNOWLEDGE_SCHEMA}.deletion_requests.tenant_id",
                f"{KNOWLEDGE_SCHEMA}.deletion_requests.source_id",
            ],
            name="fk_knowledge_deletion_surface_identity",
            ondelete="RESTRICT",
        ),
        UniqueConstraint(
            "tenant_id",
            "deletion_id",
            "surface_name",
            name="uq_knowledge_deletion_surface",
        ),
        CheckConstraint(
            "surface_name IN ('source','chunk','vector','cache','eval','backup')",
            name="ck_knowledge_deletion_surface_name",
        ),
        CheckConstraint(
            "status IN ('pending','purged','verified','failed')",
            name="ck_knowledge_deletion_surface_status",
        ),
        CheckConstraint(
            "attempt_count >= 0 AND (evidence_digest IS NULL OR "
            "evidence_digest ~ '^[0-9a-f]{64}$')",
            name="ck_knowledge_deletion_surface_evidence",
        ),
        Index(
            "ix_knowledge_deletion_surface_pending",
            "tenant_id",
            "status",
            "updated_at",
        ),
        {"schema": KNOWLEDGE_SCHEMA},
    )

    surface_receipt_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), primary_key=True
    )
    deletion_id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), nullable=False)
    tenant_id: Mapped[str] = mapped_column(String(128), nullable=False)
    source_id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), nullable=False)
    surface_name: Mapped[str] = mapped_column(String(16), nullable=False)
    status: Mapped[str] = mapped_column(String(16), nullable=False)
    attempt_count: Mapped[int] = mapped_column(BigInteger, nullable=False, default=0)
    evidence_digest: Mapped[str | None] = mapped_column(String(64), nullable=True)
    audit_receipt_id: Mapped[str] = mapped_column(String(128), nullable=False)
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False, server_default=func.statement_timestamp()
    )
