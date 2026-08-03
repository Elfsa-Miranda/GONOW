from __future__ import annotations

import hashlib
import os
import site
import sys
import time
import uuid
from pathlib import Path

import pytest
from alembic import command
from alembic.config import Config
from sqlalchemy import create_engine, func, inspect, select, text
from sqlalchemy.engine import Engine, make_url
from sqlalchemy.orm import Session, sessionmaker
from sqlalchemy.schema import CreateSchema, DropSchema


SERVICE_ROOT = Path(__file__).resolve().parents[2]
site.addsitedir(str(SERVICE_ROOT / ".venv" / "Lib" / "site-packages"))
sys.path.insert(0, str(SERVICE_ROOT))

from app.persistence.models.behavior import BEHAVIOR_SCHEMA  # noqa: E402
from app.persistence.models.knowledge import (  # noqa: E402
    KNOWLEDGE_SCHEMA,
    KnowledgeChunkRecord,
)
from app.persistence.models.runtime import RUNTIME_SCHEMA  # noqa: E402
from app.persistence.repositories.knowledge import KnowledgeWriteContext  # noqa: E402
from app.rag.chunker import ChunkerConfig, DeterministicChunker  # noqa: E402
from app.rag.indexes import (  # noqa: E402
    DICTIONARY_VERSION,
    EMBEDDING_DIMENSIONS,
    EmbeddingModelSpec,
    KnowledgeIndexRepository,
    normalize_embedding,
    segment_for_fts,
)
from app.rag.ingestion import (  # noqa: E402
    IngestionRequest,
    KnowledgeIngestionPipeline,
    REQUIRED_INGESTION_PERMISSIONS,
)
from app.rag.search import KnowledgeSearch  # noqa: E402


ALEMBIC_INI = SERVICE_ROOT / "alembic.ini"
TARGET_REVISION = "p11_004_pgvector_fts"
VERSION_SCHEMA = "p11_004_index_test"
DATABASE_URL = os.environ.get(
    "GONOW_P11_TEST_DATABASE_URL",
    "postgresql+pg8000://gonow_migrator_test@127.0.0.1:55432/gonow_p03_test",
)
ADMIN_DATABASE_URL = (
    "postgresql+pg8000://gonow_bootstrap_admin@127.0.0.1:55432/gonow_p03_test"
)
PRINCIPALS_SQL = (
    SERVICE_ROOT / "tests" / "security" / "fixtures" / "rls_principals.sql"
)
ROLES = (
    "gonow_agent_api",
    "gonow_agent_worker",
    "gonow_command_service",
    "gonow_release_operator",
    "gonow_observer",
)
MODEL_ID_NAMESPACE = uuid.UUID("00000000-0000-4000-8000-000000001024")
MODEL_REF = "embedding://offline-fixture/d1024-v1"
MODEL_CONFIG_DIGEST = hashlib.sha256(
    f"{MODEL_REF}|{EMBEDDING_DIMENSIONS}|cosine".encode("ascii")
).hexdigest()


def _assert_task_owned_database() -> None:
    parsed = make_url(DATABASE_URL)
    assert parsed.drivername == "postgresql+pg8000"
    assert parsed.host == "127.0.0.1"
    assert parsed.port == 55432
    assert parsed.username == "gonow_migrator_test"
    assert parsed.database == "gonow_p03_test"
    assert parsed.password is None


def _provision_principals(admin_engine: Engine) -> None:
    with admin_engine.begin() as connection:
        connection.exec_driver_sql(PRINCIPALS_SQL.read_text(encoding="utf-8"))


def _drop_principals(admin_engine: Engine) -> None:
    with admin_engine.begin() as connection:
        for role in ROLES:
            connection.exec_driver_sql(f"DROP OWNED BY {role}")
        for role in ROLES:
            connection.exec_driver_sql(f"DROP ROLE IF EXISTS {role}")


def _reset(engine: Engine, config: Config) -> None:
    with engine.begin() as connection:
        for schema in (KNOWLEDGE_SCHEMA, BEHAVIOR_SCHEMA, RUNTIME_SCHEMA, VERSION_SCHEMA):
            connection.execute(DropSchema(schema, cascade=True, if_exists=True))
        connection.execute(CreateSchema(VERSION_SCHEMA))
    command.upgrade(config, TARGET_REVISION)


@pytest.fixture(scope="module")
def index_database():
    _assert_task_owned_database()
    engine = create_engine(DATABASE_URL, pool_pre_ping=True)
    admin_engine = create_engine(ADMIN_DATABASE_URL, pool_pre_ping=True)
    previous_database_url = os.environ.get("GONOW_DATABASE_URL")
    previous_version_schema = os.environ.get("GONOW_ALEMBIC_VERSION_SCHEMA")
    os.environ["GONOW_DATABASE_URL"] = DATABASE_URL
    os.environ["GONOW_ALEMBIC_VERSION_SCHEMA"] = VERSION_SCHEMA
    config = Config(str(ALEMBIC_INI))
    with engine.begin() as connection:
        for schema in (KNOWLEDGE_SCHEMA, BEHAVIOR_SCHEMA, RUNTIME_SCHEMA, VERSION_SCHEMA):
            connection.execute(DropSchema(schema, cascade=True, if_exists=True))
        connection.execute(CreateSchema(VERSION_SCHEMA))
    _provision_principals(admin_engine)
    command.upgrade(config, TARGET_REVISION)
    factory = sessionmaker(engine, expire_on_commit=False)
    try:
        yield engine, config, factory
    finally:
        engine.dispose()
        with create_engine(DATABASE_URL).begin() as connection:
            for schema in (
                KNOWLEDGE_SCHEMA,
                BEHAVIOR_SCHEMA,
                RUNTIME_SCHEMA,
                VERSION_SCHEMA,
            ):
                connection.execute(DropSchema(schema, cascade=True, if_exists=True))
        _drop_principals(admin_engine)
        admin_engine.dispose()
        if previous_database_url is None:
            os.environ.pop("GONOW_DATABASE_URL", None)
        else:
            os.environ["GONOW_DATABASE_URL"] = previous_database_url
        if previous_version_schema is None:
            os.environ.pop("GONOW_ALEMBIC_VERSION_SCHEMA", None)
        else:
            os.environ["GONOW_ALEMBIC_VERSION_SCHEMA"] = previous_version_schema


def _set_tenant(session: Session, tenant_id: str) -> None:
    session.execute(select(func.set_config("app.tenant_id", tenant_id, True)))


def _embedding(text_value: str) -> tuple[float, ...]:
    seed = hashlib.sha256(text_value.encode("utf-8")).digest()
    return tuple(((seed[index % len(seed)] + 1) / 256.0) for index in range(1024))


def _model_id(tenant_id: str) -> uuid.UUID:
    return uuid.uuid5(MODEL_ID_NAMESPACE, tenant_id)


def _seed_index(factory: sessionmaker[Session], tenant_id: str):
    context = KnowledgeWriteContext(
        tenant_id=tenant_id,
        principal_id=f"principal-{tenant_id}",
        audit_receipt_id=f"audit-{tenant_id}",
        permissions=REQUIRED_INGESTION_PERMISSIONS,
    )
    request = IngestionRequest(
        context=context,
        source_key=f"guide:{tenant_id}",
        source_class="tenant_private_curated",
        owner_principal_id=f"owner-{tenant_id}",
        license_identifier="tenant-owned",
        purpose="itinerary_planning",
        version_number=1,
        payload=(
            "北京故宫历史建筑需要提前预约。\n"
            "上海博物馆收藏青铜器与书画。\n"
            "广州城市步行路线连接传统街区。\n"
            "实时开放时间必须通过工具再次确认。"
        ).encode("utf-8"),
        media_type="text/plain",
        embedding_model_ref=MODEL_REF,
        metadata_payload={"language": "zh-CN"},
    )
    with factory() as session, session.begin():
        _set_tenant(session, tenant_id)
        ingestion = KnowledgeIngestionPipeline(
            session,
            chunker=DeterministicChunker(
                ChunkerConfig(max_tokens=8, overlap_tokens=1, max_chunks=32)
            ),
        ).ingest(request)
        index_repository = KnowledgeIndexRepository(session)
        model_created = index_repository.register_model(
            tenant_id=tenant_id,
            spec=EmbeddingModelSpec(
                embedding_model_id=_model_id(tenant_id),
                model_ref=MODEL_REF,
                config_digest=MODEL_CONFIG_DIGEST,
            ),
            audit_receipt_id=f"audit-model-{tenant_id}",
        )
        chunks = tuple(
            session.scalars(
                select(KnowledgeChunkRecord)
                .where(KnowledgeChunkRecord.tenant_id == tenant_id)
                .order_by(KnowledgeChunkRecord.chunk_ordinal)
            )
        )
        writes = tuple(
            index_repository.index_chunk(
                tenant_id=tenant_id,
                chunk_id=chunk.chunk_id,
                embedding_model_id=_model_id(tenant_id),
                embedding=_embedding(chunk.text_content),
                text_content=chunk.text_content,
            )
            for chunk in chunks
        )
        index_repository.refresh_planner_statistics()
        corpus_digest = index_repository.corpus_digest(
            tenant_id=tenant_id,
            embedding_model_id=_model_id(tenant_id),
        )
        lexical = KnowledgeSearch(session).lexical_candidates(
            tenant_id=tenant_id,
            query_text="故宫",
            limit=10,
        )
        return ingestion, model_created, chunks, writes, corpus_digest, lexical


def _inflate_parameterized_plan_corpus(
    session: Session,
    *,
    tenant_id: str,
    source_id: uuid.UUID,
    version_id: uuid.UUID,
    row_count: int = 2_000,
) -> None:
    _, vector_literal, embedding_digest = normalize_embedding(
        _embedding("bounded planner fixture")
    )
    segmented_text = segment_for_fts("城市索引计划样本")
    segmented_digest = hashlib.sha256(segmented_text.encode("utf-8")).hexdigest()
    session.execute(
        text(
            """
            INSERT INTO agent_knowledge.chunks (
              chunk_id, tenant_id, source_id, version_id, chunk_ordinal,
              chunk_digest, text_content, token_count, metadata_payload
            )
            SELECT md5(:tenant_id || '|chunk|' || item::text)::uuid,
                   :tenant_id, :source_id, :version_id, 10000 + item,
                   md5(:tenant_id || '|digest-a|' || item::text) ||
                     md5(:tenant_id || '|digest-b|' || item::text),
                   'bounded planner fixture', 3,
                   jsonb_build_object('fixture_ordinal', item)
            FROM generate_series(1, :row_count) AS item
            """
        ),
        {
            "row_count": row_count,
            "source_id": source_id,
            "tenant_id": tenant_id,
            "version_id": version_id,
        },
    )
    session.execute(
        text(
            """
            INSERT INTO agent_knowledge.chunk_embeddings_v1_d1024 (
              chunk_id, tenant_id, embedding_model_id, embedding, embedding_digest
            )
            SELECT chunk_id, tenant_id, :embedding_model_id,
                   CAST(:embedding AS vector), :embedding_digest
            FROM agent_knowledge.chunks
            WHERE tenant_id = :tenant_id AND chunk_ordinal >= 10001
            """
        ),
        {
            "embedding": vector_literal,
            "embedding_digest": embedding_digest,
            "embedding_model_id": _model_id(tenant_id),
            "tenant_id": tenant_id,
        },
    )
    session.execute(
        text(
            """
            INSERT INTO agent_knowledge.chunk_lexical (
              chunk_id, tenant_id, dictionary_version,
              segmented_text, segmented_digest
            )
            SELECT chunk_id, tenant_id, :dictionary_version,
                   :segmented_text, :segmented_digest
            FROM agent_knowledge.chunks
            WHERE tenant_id = :tenant_id AND chunk_ordinal >= 10001
            """
        ),
        {
            "dictionary_version": DICTIONARY_VERSION,
            "segmented_digest": segmented_digest,
            "segmented_text": segmented_text,
            "tenant_id": tenant_id,
        },
    )
    KnowledgeIndexRepository(session).refresh_planner_statistics()


def test_sql_parameterized_plans_use_hnsw_and_fts_indexes(index_database) -> None:
    _, _, factory = index_database
    tenant_id = "tenant-index-plans"
    _, _, chunks, _, _, lexical = _seed_index(factory, tenant_id)
    assert lexical
    target = next(chunk for chunk in chunks if "故宫" in chunk.text_content)
    with factory() as session, session.begin():
        _set_tenant(session, tenant_id)
        search = KnowledgeSearch(session)
        vector = search.vector_candidates(
            tenant_id=tenant_id,
            embedding_model_id=_model_id(tenant_id),
            query_embedding=_embedding(target.text_content),
            limit=10,
        )
        assert vector[0].chunk_digest == target.chunk_digest
        _inflate_parameterized_plan_corpus(
            session,
            tenant_id=tenant_id,
            source_id=target.source_id,
            version_id=target.version_id,
        )
        vector_plan = search.explain_vector_plan(
            tenant_id=tenant_id,
            embedding_model_id=_model_id(tenant_id),
            query_embedding=_embedding(target.text_content),
            limit=10,
        )
        lexical_plan = search.explain_lexical_plan(
            tenant_id=tenant_id,
            query_text="故宫",
            limit=10,
        )
        assert "ix_knowledge_embeddings_hnsw_cosine" in vector_plan
        assert "ix_knowledge_lexical_gin" in lexical_plan, lexical_plan


def test_deterministic_corpus_index_rebuild_and_idempotent_replay(
    index_database,
) -> None:
    engine, config, factory = index_database
    tenant_id = "tenant-index-deterministic"
    first = _seed_index(factory, tenant_id)
    ingestion, model_created, chunks, writes, first_digest, lexical = first
    assert model_created
    assert all(write.embedding_created and write.lexical_created for write in writes)
    assert lexical

    with factory() as session, session.begin():
        _set_tenant(session, tenant_id)
        repository = KnowledgeIndexRepository(session)
        assert not repository.register_model(
            tenant_id=tenant_id,
            spec=EmbeddingModelSpec(
                embedding_model_id=_model_id(tenant_id),
                model_ref=MODEL_REF,
                config_digest=MODEL_CONFIG_DIGEST,
            ),
            audit_receipt_id=f"audit-model-{tenant_id}",
        )
        for chunk in chunks:
            replay = repository.index_chunk(
                tenant_id=tenant_id,
                chunk_id=chunk.chunk_id,
                embedding_model_id=_model_id(tenant_id),
                embedding=_embedding(chunk.text_content),
                text_content=chunk.text_content,
            )
            assert not replay.embedding_created
            assert not replay.lexical_created
        assert repository.corpus_digest(
            tenant_id=tenant_id, embedding_model_id=_model_id(tenant_id)
        ) == first_digest
    assert ingestion.chunk_ids

    _reset(engine, config)
    rebuilt = _seed_index(factory, tenant_id)
    assert rebuilt[4] == first_digest
    assert [hit.chunk_digest for hit in rebuilt[5]] == [
        hit.chunk_digest for hit in lexical
    ]


def test_restore_rebuild_preserves_extension_rls_and_bounded_bench(
    index_database,
) -> None:
    engine, _, factory = index_database
    tenant_id = "tenant-index-restore"
    _, _, chunks, _, _, _ = _seed_index(factory, tenant_id)
    inspector = inspect(engine)
    for table_name in (
        "embedding_models",
        "chunk_embeddings_v1_d1024",
        "chunk_lexical",
    ):
        assert table_name in inspector.get_table_names(schema=KNOWLEDGE_SCHEMA)
    with engine.connect() as connection:
        extension_version = connection.scalar(
            text("SELECT extversion FROM pg_extension WHERE extname = 'vector'")
        )
        assert extension_version is not None
        assert extension_version.startswith("0.8.")
        rls_rows = connection.execute(
            text(
                """
                SELECT relname, relrowsecurity, relforcerowsecurity
                FROM pg_class
                WHERE relnamespace = 'agent_knowledge'::regnamespace
                  AND relname IN (
                    'embedding_models',
                    'chunk_embeddings_v1_d1024',
                    'chunk_lexical'
                  )
                ORDER BY relname
                """
            )
        ).all()
        assert len(rls_rows) == 3
        assert all(row.relrowsecurity and row.relforcerowsecurity for row in rls_rows)

    target = chunks[0]
    started = time.perf_counter()
    with factory() as session, session.begin():
        _set_tenant(session, tenant_id)
        search = KnowledgeSearch(session)
        for _ in range(20):
            assert search.vector_candidates(
                tenant_id=tenant_id,
                embedding_model_id=_model_id(tenant_id),
                query_embedding=_embedding(target.text_content),
                limit=5,
            )
            assert search.lexical_candidates(
                tenant_id=tenant_id,
                query_text="北京故宫",
                dictionary_version=DICTIONARY_VERSION,
                limit=5,
            )
    assert time.perf_counter() - started < 5.0
