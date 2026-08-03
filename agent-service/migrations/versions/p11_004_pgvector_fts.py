"""Add versioned pgvector and application-segmented FTS indexes.

Revision ID: p11_004_pgvector_fts
Revises: p11_002_knowledge_rls_outbox
"""

from __future__ import annotations

from alembic import op
import sqlalchemy as sa
from sqlalchemy.dialects import postgresql
from sqlalchemy.types import UserDefinedType


revision = "p11_004_pgvector_fts"
down_revision = "p11_002_knowledge_rls_outbox"
branch_labels = None
depends_on = None


KNOWLEDGE_SCHEMA = "agent_knowledge"
INDEX_TABLES = (
    "embedding_models",
    "chunk_embeddings_v1_d1024",
    "chunk_lexical",
)


class Vector1024(UserDefinedType):
    cache_ok = True

    def get_col_spec(self, **_kwargs: object) -> str:
        return "vector(1024)"


def _execute(statement: str) -> None:
    op.execute(sa.text(statement))


def upgrade() -> None:
    _execute("CREATE EXTENSION IF NOT EXISTS vector WITH SCHEMA public")
    _execute("CREATE EXTENSION IF NOT EXISTS btree_gin WITH SCHEMA public")
    _execute(
        """
        DO $gonow$
        DECLARE installed_version text;
        BEGIN
          SELECT extversion INTO installed_version
          FROM pg_extension WHERE extname = 'vector';
          IF installed_version IS NULL OR installed_version !~ '^0\\.8\\.[0-9]+$' THEN
            RAISE EXCEPTION 'pgvector 0.8.x is required';
          END IF;
        END
        $gonow$
        """
    )

    op.create_table(
        "embedding_models",
        sa.Column(
            "embedding_model_id", postgresql.UUID(as_uuid=True), nullable=False
        ),
        sa.Column("tenant_id", sa.String(length=128), nullable=False),
        sa.Column("model_ref", sa.String(length=255), nullable=False),
        sa.Column("dimensions", sa.Integer(), nullable=False),
        sa.Column("distance_metric", sa.String(length=16), nullable=False),
        sa.Column("config_digest", sa.String(length=64), nullable=False),
        sa.Column("status", sa.String(length=16), nullable=False),
        sa.Column("audit_receipt_id", sa.String(length=128), nullable=False),
        sa.Column(
            "created_at",
            sa.DateTime(timezone=True),
            server_default=sa.text("statement_timestamp()"),
            nullable=False,
        ),
        sa.PrimaryKeyConstraint(
            "embedding_model_id", name="pk_knowledge_embedding_models"
        ),
        sa.UniqueConstraint(
            "embedding_model_id",
            "tenant_id",
            name="uq_knowledge_embedding_model_tenant",
        ),
        sa.UniqueConstraint(
            "tenant_id",
            "model_ref",
            "config_digest",
            name="uq_knowledge_embedding_model_config",
        ),
        sa.CheckConstraint(
            "model_ref ~ '^embedding://[a-z0-9][a-z0-9._/-]{0,190}$'",
            name="ck_knowledge_embedding_model_ref",
        ),
        sa.CheckConstraint(
            "dimensions = 1024 AND distance_metric = 'cosine'",
            name="ck_knowledge_embedding_model_family",
        ),
        sa.CheckConstraint(
            "config_digest ~ '^[0-9a-f]{64}$'",
            name="ck_knowledge_embedding_model_digest",
        ),
        sa.CheckConstraint(
            "status IN ('active','canary','retired')",
            name="ck_knowledge_embedding_model_status",
        ),
        schema=KNOWLEDGE_SCHEMA,
    )
    op.create_index(
        "ix_knowledge_embedding_models_active",
        "embedding_models",
        ["tenant_id", "status", "model_ref"],
        unique=False,
        schema=KNOWLEDGE_SCHEMA,
    )

    op.create_table(
        "chunk_embeddings_v1_d1024",
        sa.Column("chunk_id", postgresql.UUID(as_uuid=True), nullable=False),
        sa.Column("tenant_id", sa.String(length=128), nullable=False),
        sa.Column(
            "embedding_model_id", postgresql.UUID(as_uuid=True), nullable=False
        ),
        sa.Column("embedding", Vector1024(), nullable=False),
        sa.Column("embedding_digest", sa.String(length=64), nullable=False),
        sa.Column(
            "created_at",
            sa.DateTime(timezone=True),
            server_default=sa.text("statement_timestamp()"),
            nullable=False,
        ),
        sa.ForeignKeyConstraint(
            ["chunk_id", "tenant_id"],
            [
                f"{KNOWLEDGE_SCHEMA}.chunks.chunk_id",
                f"{KNOWLEDGE_SCHEMA}.chunks.tenant_id",
            ],
            name="fk_knowledge_embedding_chunk_tenant",
            ondelete="CASCADE",
        ),
        sa.ForeignKeyConstraint(
            ["embedding_model_id", "tenant_id"],
            [
                f"{KNOWLEDGE_SCHEMA}.embedding_models.embedding_model_id",
                f"{KNOWLEDGE_SCHEMA}.embedding_models.tenant_id",
            ],
            name="fk_knowledge_embedding_model_tenant",
            ondelete="RESTRICT",
        ),
        sa.PrimaryKeyConstraint(
            "chunk_id",
            "embedding_model_id",
            name="pk_knowledge_chunk_embeddings_d1024",
        ),
        sa.CheckConstraint(
            "embedding_digest ~ '^[0-9a-f]{64}$'",
            name="ck_knowledge_embedding_digest",
        ),
        sa.CheckConstraint(
            "vector_norm(embedding) > 0",
            name="ck_knowledge_embedding_nonzero",
        ),
        schema=KNOWLEDGE_SCHEMA,
    )
    _execute(
        f"""
        CREATE INDEX ix_knowledge_embeddings_hnsw_cosine
        ON {KNOWLEDGE_SCHEMA}.chunk_embeddings_v1_d1024
        USING hnsw (embedding vector_cosine_ops)
        WITH (m = 16, ef_construction = 128)
        """
    )
    op.create_index(
        "ix_knowledge_embeddings_tenant_model",
        "chunk_embeddings_v1_d1024",
        ["tenant_id", "embedding_model_id", "chunk_id"],
        unique=False,
        schema=KNOWLEDGE_SCHEMA,
    )

    op.create_table(
        "chunk_lexical",
        sa.Column("chunk_id", postgresql.UUID(as_uuid=True), nullable=False),
        sa.Column("tenant_id", sa.String(length=128), nullable=False),
        sa.Column("dictionary_version", sa.String(length=64), nullable=False),
        sa.Column("segmented_text", sa.Text(), nullable=False),
        sa.Column(
            "search_vector",
            postgresql.TSVECTOR(),
            sa.Computed(
                "to_tsvector('simple'::regconfig, segmented_text)",
                persisted=True,
            ),
            nullable=False,
        ),
        sa.Column("segmented_digest", sa.String(length=64), nullable=False),
        sa.Column(
            "created_at",
            sa.DateTime(timezone=True),
            server_default=sa.text("statement_timestamp()"),
            nullable=False,
        ),
        sa.ForeignKeyConstraint(
            ["chunk_id", "tenant_id"],
            [
                f"{KNOWLEDGE_SCHEMA}.chunks.chunk_id",
                f"{KNOWLEDGE_SCHEMA}.chunks.tenant_id",
            ],
            name="fk_knowledge_lexical_chunk_tenant",
            ondelete="CASCADE",
        ),
        sa.PrimaryKeyConstraint(
            "chunk_id",
            "dictionary_version",
            name="pk_knowledge_chunk_lexical",
        ),
        sa.CheckConstraint(
            "dictionary_version ~ '^[a-z][a-z0-9._-]{0,63}$'",
            name="ck_knowledge_lexical_dictionary",
        ),
        sa.CheckConstraint(
            "length(segmented_text) > 0 AND segmented_digest ~ '^[0-9a-f]{64}$'",
            name="ck_knowledge_lexical_content",
        ),
        schema=KNOWLEDGE_SCHEMA,
    )
    _execute(
        f"""
        CREATE INDEX ix_knowledge_lexical_gin
        ON {KNOWLEDGE_SCHEMA}.chunk_lexical
        USING gin (tenant_id, dictionary_version, search_vector)
        """
    )
    op.create_index(
        "ix_knowledge_lexical_tenant_dictionary",
        "chunk_lexical",
        ["tenant_id", "dictionary_version", "chunk_id"],
        unique=False,
        schema=KNOWLEDGE_SCHEMA,
    )

    for table_name in INDEX_TABLES:
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
            f"REVOKE ALL ON {KNOWLEDGE_SCHEMA}.{table_name} FROM PUBLIC"
        )

    _execute(
        f"GRANT SELECT ON {KNOWLEDGE_SCHEMA}.embedding_models, "
        f"{KNOWLEDGE_SCHEMA}.chunk_embeddings_v1_d1024, "
        f"{KNOWLEDGE_SCHEMA}.chunk_lexical TO gonow_agent_api, gonow_agent_worker"
    )
    _execute(
        f"GRANT INSERT, UPDATE ON {KNOWLEDGE_SCHEMA}.embedding_models, "
        f"{KNOWLEDGE_SCHEMA}.chunk_embeddings_v1_d1024, "
        f"{KNOWLEDGE_SCHEMA}.chunk_lexical TO gonow_agent_worker"
    )
    _execute(
        f"GRANT SELECT, INSERT, UPDATE ON {KNOWLEDGE_SCHEMA}.embedding_models "
        "TO gonow_release_operator"
    )


def downgrade() -> None:
    raise RuntimeError(
        "P11-004 is forward-fix only; switch to the prior manifest before contracting indexes"
    )
