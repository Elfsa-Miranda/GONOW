"""Add immutable Behavior releases and deployment generation CAS metadata.

Revision ID: p03_004_behavior_releases
Revises: p03_003_jobs_leases_checkpoints
Create Date: 2026-08-01 06:10:00+08:00
"""

from collections.abc import Sequence

from alembic import op
import sqlalchemy as sa
from sqlalchemy.dialects import postgresql


revision: str = "p03_004_behavior_releases"
down_revision: str | Sequence[str] | None = "p03_003_jobs_leases_checkpoints"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None

BEHAVIOR_SCHEMA = "agent_behavior"


def upgrade() -> None:
    op.execute(sa.schema.CreateSchema(BEHAVIOR_SCHEMA))
    op.create_table(
        "revisions",
        sa.Column("revision_id", postgresql.UUID(as_uuid=True), nullable=False),
        sa.Column("behavior_key", sa.String(length=127), nullable=False),
        sa.Column("revision_number", sa.BigInteger(), nullable=False),
        sa.Column("content_digest", sa.String(length=64), nullable=False),
        sa.Column("graph_ref", sa.String(length=96), nullable=False),
        sa.Column("prompt_ref", sa.String(length=97), nullable=False),
        sa.Column("state_schema_ref", sa.String(length=97), nullable=False),
        sa.Column("created_by_principal_id", sa.String(length=256), nullable=False),
        sa.Column("audit_receipt_id", sa.String(length=128), nullable=False),
        sa.Column(
            "created_at",
            sa.DateTime(timezone=True),
            server_default=sa.text("statement_timestamp()"),
            nullable=False,
        ),
        sa.CheckConstraint(
            "behavior_key ~ '^[a-z][a-z0-9_.-]{0,126}$'",
            name="ck_behavior_revision_key",
        ),
        sa.CheckConstraint("revision_number >= 1", name="ck_behavior_revision_number"),
        sa.CheckConstraint(
            "content_digest ~ '^[0-9a-f]{64}$'",
            name="ck_behavior_revision_digest",
        ),
        sa.CheckConstraint(
            "graph_ref ~ '^graph://sha256/[0-9a-f]{64}$' AND "
            "prompt_ref ~ '^prompt://sha256/[0-9a-f]{64}$' AND "
            "state_schema_ref ~ '^schema://sha256/[0-9a-f]{64}$'",
            name="ck_behavior_revision_refs",
        ),
        sa.CheckConstraint(
            "length(created_by_principal_id) > 0 AND length(audit_receipt_id) > 0",
            name="ck_behavior_revision_audit",
        ),
        sa.PrimaryKeyConstraint("revision_id", name="pk_behavior_revisions"),
        sa.UniqueConstraint(
            "behavior_key",
            "revision_number",
            name="uq_behavior_revision_number",
        ),
        sa.UniqueConstraint(
            "behavior_key",
            "content_digest",
            name="uq_behavior_revision_digest",
        ),
        schema=BEHAVIOR_SCHEMA,
    )
    op.create_index(
        "ix_behavior_revisions_key_created",
        "revisions",
        ["behavior_key", "created_at"],
        schema=BEHAVIOR_SCHEMA,
    )

    op.create_table(
        "certifications",
        sa.Column("certification_id", postgresql.UUID(as_uuid=True), nullable=False),
        sa.Column("revision_id", postgresql.UUID(as_uuid=True), nullable=False),
        sa.Column("dataset_digest", sa.String(length=64), nullable=False),
        sa.Column("result", sa.String(length=16), nullable=False),
        sa.Column("certifier_principal_id", sa.String(length=256), nullable=False),
        sa.Column("audit_receipt_id", sa.String(length=128), nullable=False),
        sa.Column(
            "certified_at",
            sa.DateTime(timezone=True),
            server_default=sa.text("statement_timestamp()"),
            nullable=False,
        ),
        sa.CheckConstraint(
            "result IN ('qualified','rejected')",
            name="ck_behavior_certification_result",
        ),
        sa.CheckConstraint(
            "dataset_digest ~ '^[0-9a-f]{64}$'",
            name="ck_behavior_certification_dataset",
        ),
        sa.CheckConstraint(
            "length(certifier_principal_id) > 0 AND length(audit_receipt_id) > 0",
            name="ck_behavior_certification_audit",
        ),
        sa.ForeignKeyConstraint(
            ["revision_id"],
            [f"{BEHAVIOR_SCHEMA}.revisions.revision_id"],
            name="fk_behavior_certification_revision",
            ondelete="RESTRICT",
        ),
        sa.PrimaryKeyConstraint("certification_id", name="pk_behavior_certifications"),
        sa.UniqueConstraint(
            "revision_id",
            "dataset_digest",
            "result",
            name="uq_behavior_certification_result",
        ),
        schema=BEHAVIOR_SCHEMA,
    )

    op.create_table(
        "releases",
        sa.Column("release_id", postgresql.UUID(as_uuid=True), nullable=False),
        sa.Column("behavior_key", sa.String(length=127), nullable=False),
        sa.Column("revision_id", postgresql.UUID(as_uuid=True), nullable=False),
        sa.Column("certification_id", postgresql.UUID(as_uuid=True), nullable=False),
        sa.Column("release_version", sa.String(length=32), nullable=False),
        sa.Column("package_digest", sa.String(length=64), nullable=False),
        sa.Column("lifecycle_state", sa.String(length=32), nullable=False),
        sa.Column("created_by_principal_id", sa.String(length=256), nullable=False),
        sa.Column("audit_receipt_id", sa.String(length=128), nullable=False),
        sa.Column(
            "created_at",
            sa.DateTime(timezone=True),
            server_default=sa.text("statement_timestamp()"),
            nullable=False,
        ),
        sa.CheckConstraint(
            "release_version ~ '^[0-9]+\\.[0-9]+\\.[0-9]+$'",
            name="ck_behavior_release_version",
        ),
        sa.CheckConstraint(
            "package_digest ~ '^[0-9a-f]{64}$'",
            name="ck_behavior_release_digest",
        ),
        sa.CheckConstraint(
            "lifecycle_state IN ('draft','offline_qualified','replay_qualified','shadow_observed',"
            "'canary_approved','active','deprecated','retired','quarantined')",
            name="ck_behavior_release_lifecycle",
        ),
        sa.CheckConstraint(
            "length(created_by_principal_id) > 0 AND length(audit_receipt_id) > 0",
            name="ck_behavior_release_audit",
        ),
        sa.ForeignKeyConstraint(
            ["revision_id"],
            [f"{BEHAVIOR_SCHEMA}.revisions.revision_id"],
            name="fk_behavior_release_revision",
            ondelete="RESTRICT",
        ),
        sa.ForeignKeyConstraint(
            ["certification_id"],
            [f"{BEHAVIOR_SCHEMA}.certifications.certification_id"],
            name="fk_behavior_release_certification",
            ondelete="RESTRICT",
        ),
        sa.PrimaryKeyConstraint("release_id", name="pk_behavior_releases"),
        sa.UniqueConstraint(
            "behavior_key",
            "release_version",
            name="uq_behavior_release_version",
        ),
        sa.UniqueConstraint(
            "behavior_key",
            "package_digest",
            name="uq_behavior_release_digest",
        ),
        sa.UniqueConstraint(
            "release_id",
            "behavior_key",
            name="uq_behavior_release_id_key",
        ),
        schema=BEHAVIOR_SCHEMA,
    )
    op.create_index(
        "ix_behavior_releases_key_created",
        "releases",
        ["behavior_key", "created_at"],
        schema=BEHAVIOR_SCHEMA,
    )

    op.create_table(
        "deployments",
        sa.Column("deployment_id", postgresql.UUID(as_uuid=True), nullable=False),
        sa.Column("behavior_key", sa.String(length=127), nullable=False),
        sa.Column("environment", sa.String(length=63), nullable=False),
        sa.Column("release_id", postgresql.UUID(as_uuid=True), nullable=False),
        sa.Column("generation", sa.BigInteger(), nullable=False),
        sa.Column("updated_by_principal_id", sa.String(length=256), nullable=False),
        sa.Column("audit_receipt_id", sa.String(length=128), nullable=False),
        sa.Column(
            "updated_at",
            sa.DateTime(timezone=True),
            server_default=sa.text("statement_timestamp()"),
            nullable=False,
        ),
        sa.CheckConstraint("generation >= 1", name="ck_behavior_deployment_generation"),
        sa.CheckConstraint(
            "environment ~ '^[a-z][a-z0-9-]{0,62}$'",
            name="ck_behavior_deployment_environment",
        ),
        sa.CheckConstraint(
            "length(updated_by_principal_id) > 0 AND length(audit_receipt_id) > 0",
            name="ck_behavior_deployment_audit",
        ),
        sa.ForeignKeyConstraint(
            ["release_id", "behavior_key"],
            [
                f"{BEHAVIOR_SCHEMA}.releases.release_id",
                f"{BEHAVIOR_SCHEMA}.releases.behavior_key",
            ],
            name="fk_behavior_deployment_release_key",
            ondelete="RESTRICT",
        ),
        sa.PrimaryKeyConstraint("deployment_id", name="pk_behavior_deployments"),
        sa.UniqueConstraint(
            "behavior_key",
            "environment",
            name="uq_behavior_deployment_key_environment",
        ),
        sa.UniqueConstraint(
            "deployment_id",
            "behavior_key",
            name="uq_behavior_deployment_id_key",
        ),
        schema=BEHAVIOR_SCHEMA,
    )

    op.create_table(
        "deployment_history",
        sa.Column("history_id", postgresql.UUID(as_uuid=True), nullable=False),
        sa.Column("deployment_id", postgresql.UUID(as_uuid=True), nullable=False),
        sa.Column("behavior_key", sa.String(length=127), nullable=False),
        sa.Column("generation", sa.BigInteger(), nullable=False),
        sa.Column("previous_release_id", postgresql.UUID(as_uuid=True), nullable=True),
        sa.Column("new_release_id", postgresql.UUID(as_uuid=True), nullable=False),
        sa.Column("actor_principal_id", sa.String(length=256), nullable=False),
        sa.Column("audit_receipt_id", sa.String(length=128), nullable=False),
        sa.Column(
            "changed_at",
            sa.DateTime(timezone=True),
            server_default=sa.text("statement_timestamp()"),
            nullable=False,
        ),
        sa.CheckConstraint("generation >= 1", name="ck_behavior_history_generation"),
        sa.CheckConstraint(
            "length(actor_principal_id) > 0 AND length(audit_receipt_id) > 0",
            name="ck_behavior_history_audit",
        ),
        sa.ForeignKeyConstraint(
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
        sa.ForeignKeyConstraint(
            ["new_release_id", "behavior_key"],
            [
                f"{BEHAVIOR_SCHEMA}.releases.release_id",
                f"{BEHAVIOR_SCHEMA}.releases.behavior_key",
            ],
            name="fk_behavior_history_new_release_key",
            ondelete="RESTRICT",
        ),
        sa.ForeignKeyConstraint(
            ["previous_release_id", "behavior_key"],
            [
                f"{BEHAVIOR_SCHEMA}.releases.release_id",
                f"{BEHAVIOR_SCHEMA}.releases.behavior_key",
            ],
            name="fk_behavior_history_previous_release_key",
            ondelete="RESTRICT",
        ),
        sa.PrimaryKeyConstraint("history_id", name="pk_behavior_deployment_history"),
        sa.UniqueConstraint(
            "deployment_id",
            "generation",
            name="uq_behavior_history_generation",
        ),
        schema=BEHAVIOR_SCHEMA,
    )

    op.execute(
        sa.text(
            """
            CREATE FUNCTION agent_behavior.reject_immutable_change()
            RETURNS trigger
            LANGUAGE plpgsql
            SET search_path = pg_catalog, pg_temp
            AS $$
            BEGIN
              RAISE EXCEPTION 'behavior.immutable' USING ERRCODE = '23514';
            END;
            $$
            """
        )
    )
    for table_name in ("revisions", "certifications", "releases", "deployment_history"):
        op.execute(
            sa.text(
                f"CREATE TRIGGER {table_name}_immutable_guard "
                f"BEFORE UPDATE OR DELETE ON agent_behavior.{table_name} "
                "FOR EACH ROW EXECUTE FUNCTION agent_behavior.reject_immutable_change()"
            )
        )
    op.execute(
        sa.text(
            """
            CREATE FUNCTION agent_behavior.enforce_qualified_release()
            RETURNS trigger
            LANGUAGE plpgsql
            SET search_path = pg_catalog, pg_temp
            AS $$
            BEGIN
              IF NOT EXISTS (
                SELECT 1
                FROM agent_behavior.certifications AS certification
                JOIN agent_behavior.revisions AS revision
                  ON revision.revision_id = certification.revision_id
                WHERE certification.certification_id = NEW.certification_id
                  AND certification.revision_id = NEW.revision_id
                  AND certification.result = 'qualified'
                  AND revision.behavior_key = NEW.behavior_key
              ) THEN
                RAISE EXCEPTION 'behavior.not_qualified' USING ERRCODE = '23514';
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
            CREATE TRIGGER releases_qualification_guard
            BEFORE INSERT ON agent_behavior.releases
            FOR EACH ROW EXECUTE FUNCTION agent_behavior.enforce_qualified_release()
            """
        )
    )
    op.execute(
        sa.text(
            """
            CREATE FUNCTION agent_behavior.assert_deployment_history()
            RETURNS trigger
            LANGUAGE plpgsql
            SET search_path = pg_catalog, pg_temp
            AS $$
            BEGIN
              IF NOT EXISTS (
                SELECT 1
                FROM agent_behavior.deployment_history AS history
                WHERE history.deployment_id = NEW.deployment_id
                  AND history.behavior_key = NEW.behavior_key
                  AND history.generation = NEW.generation
                  AND history.new_release_id = NEW.release_id
                  AND history.audit_receipt_id = NEW.audit_receipt_id
                  AND history.actor_principal_id = NEW.updated_by_principal_id
              ) THEN
                RAISE EXCEPTION 'audit.receipt_required' USING ERRCODE = '23514';
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
            CREATE CONSTRAINT TRIGGER deployments_history_guard
            AFTER INSERT OR UPDATE ON agent_behavior.deployments
            DEFERRABLE INITIALLY DEFERRED
            FOR EACH ROW EXECUTE FUNCTION agent_behavior.assert_deployment_history()
            """
        )
    )


def downgrade() -> None:
    op.execute(sa.text("DROP TRIGGER deployments_history_guard ON agent_behavior.deployments"))
    op.execute(sa.text("DROP TRIGGER releases_qualification_guard ON agent_behavior.releases"))
    for table_name in ("deployment_history", "releases", "certifications", "revisions"):
        op.execute(
            sa.text(
                f"DROP TRIGGER {table_name}_immutable_guard ON agent_behavior.{table_name}"
            )
        )
    op.execute(sa.text("DROP FUNCTION agent_behavior.assert_deployment_history()"))
    op.execute(sa.text("DROP FUNCTION agent_behavior.enforce_qualified_release()"))
    op.execute(sa.text("DROP FUNCTION agent_behavior.reject_immutable_change()"))
    op.drop_table("deployment_history", schema=BEHAVIOR_SCHEMA)
    op.drop_table("deployments", schema=BEHAVIOR_SCHEMA)
    op.drop_index(
        "ix_behavior_releases_key_created",
        table_name="releases",
        schema=BEHAVIOR_SCHEMA,
    )
    op.drop_table("releases", schema=BEHAVIOR_SCHEMA)
    op.drop_table("certifications", schema=BEHAVIOR_SCHEMA)
    op.drop_index(
        "ix_behavior_revisions_key_created",
        table_name="revisions",
        schema=BEHAVIOR_SCHEMA,
    )
    op.drop_table("revisions", schema=BEHAVIOR_SCHEMA)
    op.execute(sa.schema.DropSchema(BEHAVIOR_SCHEMA))
