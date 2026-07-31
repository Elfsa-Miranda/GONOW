"""Immutable Behavior release records and mutable deployment pointers."""

from __future__ import annotations

import uuid
from datetime import datetime

from sqlalchemy import (
    BigInteger,
    CheckConstraint,
    DateTime,
    ForeignKey,
    ForeignKeyConstraint,
    Index,
    String,
    UniqueConstraint,
    func,
)
from sqlalchemy.dialects.postgresql import UUID
from sqlalchemy.orm import Mapped, mapped_column

from app.persistence.models.runtime import RuntimeBase


BEHAVIOR_SCHEMA = "agent_behavior"


class BehaviorRevisionRecord(RuntimeBase):
    __tablename__ = "revisions"
    __table_args__ = (
        UniqueConstraint("behavior_key", "revision_number", name="uq_behavior_revision_number"),
        UniqueConstraint("behavior_key", "content_digest", name="uq_behavior_revision_digest"),
        CheckConstraint(
            "behavior_key ~ '^[a-z][a-z0-9_.-]{0,126}$'",
            name="ck_behavior_revision_key",
        ),
        CheckConstraint("revision_number >= 1", name="ck_behavior_revision_number"),
        CheckConstraint(
            "content_digest ~ '^[0-9a-f]{64}$'",
            name="ck_behavior_revision_digest",
        ),
        CheckConstraint(
            "graph_ref ~ '^graph://sha256/[0-9a-f]{64}$' AND "
            "prompt_ref ~ '^prompt://sha256/[0-9a-f]{64}$' AND "
            "state_schema_ref ~ '^schema://sha256/[0-9a-f]{64}$'",
            name="ck_behavior_revision_refs",
        ),
        CheckConstraint(
            "length(created_by_principal_id) > 0 AND length(audit_receipt_id) > 0",
            name="ck_behavior_revision_audit",
        ),
        Index("ix_behavior_revisions_key_created", "behavior_key", "created_at"),
        {"schema": BEHAVIOR_SCHEMA},
    )

    revision_id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), primary_key=True)
    behavior_key: Mapped[str] = mapped_column(String(127), nullable=False)
    revision_number: Mapped[int] = mapped_column(BigInteger, nullable=False)
    content_digest: Mapped[str] = mapped_column(String(64), nullable=False)
    graph_ref: Mapped[str] = mapped_column(String(96), nullable=False)
    prompt_ref: Mapped[str] = mapped_column(String(97), nullable=False)
    state_schema_ref: Mapped[str] = mapped_column(String(97), nullable=False)
    created_by_principal_id: Mapped[str] = mapped_column(String(256), nullable=False)
    audit_receipt_id: Mapped[str] = mapped_column(String(128), nullable=False)
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False, server_default=func.statement_timestamp()
    )


class BehaviorCertificationRecord(RuntimeBase):
    __tablename__ = "certifications"
    __table_args__ = (
        UniqueConstraint(
            "revision_id",
            "dataset_digest",
            "result",
            name="uq_behavior_certification_result",
        ),
        CheckConstraint(
            "result IN ('qualified','rejected')",
            name="ck_behavior_certification_result",
        ),
        CheckConstraint(
            "dataset_digest ~ '^[0-9a-f]{64}$'",
            name="ck_behavior_certification_dataset",
        ),
        CheckConstraint(
            "length(certifier_principal_id) > 0 AND length(audit_receipt_id) > 0",
            name="ck_behavior_certification_audit",
        ),
        {"schema": BEHAVIOR_SCHEMA},
    )

    certification_id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), primary_key=True)
    revision_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True),
        ForeignKey(f"{BEHAVIOR_SCHEMA}.revisions.revision_id", ondelete="RESTRICT"),
        nullable=False,
    )
    dataset_digest: Mapped[str] = mapped_column(String(64), nullable=False)
    result: Mapped[str] = mapped_column(String(16), nullable=False)
    certifier_principal_id: Mapped[str] = mapped_column(String(256), nullable=False)
    audit_receipt_id: Mapped[str] = mapped_column(String(128), nullable=False)
    certified_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False, server_default=func.statement_timestamp()
    )


class BehaviorReleaseRecord(RuntimeBase):
    __tablename__ = "releases"
    __table_args__ = (
        UniqueConstraint("behavior_key", "release_version", name="uq_behavior_release_version"),
        UniqueConstraint("behavior_key", "package_digest", name="uq_behavior_release_digest"),
        UniqueConstraint("release_id", "behavior_key", name="uq_behavior_release_id_key"),
        CheckConstraint(
            "release_version ~ '^[0-9]+\\.[0-9]+\\.[0-9]+$'",
            name="ck_behavior_release_version",
        ),
        CheckConstraint(
            "package_digest ~ '^[0-9a-f]{64}$'",
            name="ck_behavior_release_digest",
        ),
        CheckConstraint(
            "lifecycle_state IN ('draft','offline_qualified','replay_qualified','shadow_observed',"
            "'canary_approved','active','deprecated','retired','quarantined')",
            name="ck_behavior_release_lifecycle",
        ),
        CheckConstraint(
            "length(created_by_principal_id) > 0 AND length(audit_receipt_id) > 0",
            name="ck_behavior_release_audit",
        ),
        Index("ix_behavior_releases_key_created", "behavior_key", "created_at"),
        {"schema": BEHAVIOR_SCHEMA},
    )

    release_id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), primary_key=True)
    behavior_key: Mapped[str] = mapped_column(String(127), nullable=False)
    revision_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True),
        ForeignKey(f"{BEHAVIOR_SCHEMA}.revisions.revision_id", ondelete="RESTRICT"),
        nullable=False,
    )
    certification_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True),
        ForeignKey(
            f"{BEHAVIOR_SCHEMA}.certifications.certification_id",
            ondelete="RESTRICT",
        ),
        nullable=False,
    )
    release_version: Mapped[str] = mapped_column(String(32), nullable=False)
    package_digest: Mapped[str] = mapped_column(String(64), nullable=False)
    lifecycle_state: Mapped[str] = mapped_column(String(32), nullable=False)
    created_by_principal_id: Mapped[str] = mapped_column(String(256), nullable=False)
    audit_receipt_id: Mapped[str] = mapped_column(String(128), nullable=False)
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False, server_default=func.statement_timestamp()
    )


class BehaviorDeploymentRecord(RuntimeBase):
    __tablename__ = "deployments"
    __table_args__ = (
        ForeignKeyConstraint(
            ["release_id", "behavior_key"],
            [
                f"{BEHAVIOR_SCHEMA}.releases.release_id",
                f"{BEHAVIOR_SCHEMA}.releases.behavior_key",
            ],
            name="fk_behavior_deployment_release_key",
            ondelete="RESTRICT",
        ),
        UniqueConstraint(
            "behavior_key",
            "environment",
            name="uq_behavior_deployment_key_environment",
        ),
        UniqueConstraint(
            "deployment_id",
            "behavior_key",
            name="uq_behavior_deployment_id_key",
        ),
        CheckConstraint("generation >= 1", name="ck_behavior_deployment_generation"),
        CheckConstraint(
            "environment ~ '^[a-z][a-z0-9-]{0,62}$'",
            name="ck_behavior_deployment_environment",
        ),
        CheckConstraint(
            "length(updated_by_principal_id) > 0 AND length(audit_receipt_id) > 0",
            name="ck_behavior_deployment_audit",
        ),
        {"schema": BEHAVIOR_SCHEMA},
    )

    deployment_id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), primary_key=True)
    behavior_key: Mapped[str] = mapped_column(String(127), nullable=False)
    environment: Mapped[str] = mapped_column(String(63), nullable=False)
    release_id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), nullable=False)
    generation: Mapped[int] = mapped_column(BigInteger, nullable=False)
    updated_by_principal_id: Mapped[str] = mapped_column(String(256), nullable=False)
    audit_receipt_id: Mapped[str] = mapped_column(String(128), nullable=False)
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False, server_default=func.statement_timestamp()
    )


class BehaviorDeploymentHistoryRecord(RuntimeBase):
    __tablename__ = "deployment_history"
    __table_args__ = (
        ForeignKeyConstraint(
            ["deployment_id", "behavior_key"],
            [
                f"{BEHAVIOR_SCHEMA}.deployments.deployment_id",
                f"{BEHAVIOR_SCHEMA}.deployments.behavior_key",
            ],
            name="fk_behavior_history_deployment_key",
            ondelete="CASCADE",
            deferrable=True,
            initially="DEFERRED",
        ),
        ForeignKeyConstraint(
            ["new_release_id", "behavior_key"],
            [
                f"{BEHAVIOR_SCHEMA}.releases.release_id",
                f"{BEHAVIOR_SCHEMA}.releases.behavior_key",
            ],
            name="fk_behavior_history_new_release_key",
            ondelete="RESTRICT",
        ),
        ForeignKeyConstraint(
            ["previous_release_id", "behavior_key"],
            [
                f"{BEHAVIOR_SCHEMA}.releases.release_id",
                f"{BEHAVIOR_SCHEMA}.releases.behavior_key",
            ],
            name="fk_behavior_history_previous_release_key",
            ondelete="RESTRICT",
        ),
        UniqueConstraint(
            "deployment_id",
            "generation",
            name="uq_behavior_history_generation",
        ),
        CheckConstraint("generation >= 1", name="ck_behavior_history_generation"),
        CheckConstraint(
            "length(actor_principal_id) > 0 AND length(audit_receipt_id) > 0",
            name="ck_behavior_history_audit",
        ),
        {"schema": BEHAVIOR_SCHEMA},
    )

    history_id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), primary_key=True)
    deployment_id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), nullable=False)
    behavior_key: Mapped[str] = mapped_column(String(127), nullable=False)
    generation: Mapped[int] = mapped_column(BigInteger, nullable=False)
    previous_release_id: Mapped[uuid.UUID | None] = mapped_column(
        UUID(as_uuid=True), nullable=True
    )
    new_release_id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), nullable=False)
    actor_principal_id: Mapped[str] = mapped_column(String(256), nullable=False)
    audit_receipt_id: Mapped[str] = mapped_column(String(128), nullable=False)
    changed_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False, server_default=func.statement_timestamp()
    )
