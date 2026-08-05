from __future__ import annotations

import os
import site
import sys
from pathlib import Path

import pytest
from alembic import command
from alembic.config import Config
from sqlalchemy import create_engine, func, select
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
    KnowledgeIngestionReceiptRecord,
    KnowledgeOutboxRecord,
    KnowledgeSourceRecord,
    KnowledgeSourceVersionRecord,
)
from app.persistence.models.runtime import RUNTIME_SCHEMA  # noqa: E402
from app.persistence.repositories.knowledge import (  # noqa: E402
    KnowledgeAuthorizationDenied,
    KnowledgeRepository,
    KnowledgeWriteContext,
)
from app.rag.chunker import ChunkerConfig, DeterministicChunker  # noqa: E402
from app.rag.embedding_jobs import EmbeddingJobPlanner  # noqa: E402
from app.rag.ingestion import (  # noqa: E402
    IngestionRequest,
    KnowledgeIngestionPipeline,
    REQUIRED_INGESTION_PERMISSIONS,
)
from app.rag.parser import DeterministicTextParser  # noqa: E402


ALEMBIC_INI = SERVICE_ROOT / "alembic.ini"
TARGET_REVISION = "p11_002_knowledge_rls_outbox"
VERSION_SCHEMA = "p11_003_ingestion_test"
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


@pytest.fixture(scope="module")
def ingestion_database():
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
        yield factory
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


def _context(tenant_id: str, *, permissions=REQUIRED_INGESTION_PERMISSIONS):
    return KnowledgeWriteContext(
        tenant_id=tenant_id,
        principal_id=f"principal-{tenant_id}",
        audit_receipt_id=f"audit-{tenant_id}",
        permissions=frozenset(permissions),
    )


def _request(tenant_id: str, *, payload: bytes | None = None) -> IngestionRequest:
    return IngestionRequest(
        context=_context(tenant_id),
        source_key=f"guide:{tenant_id}",
        source_class="tenant_private_curated",
        owner_principal_id=f"owner-{tenant_id}",
        license_identifier="tenant-owned",
        purpose="itinerary_planning",
        version_number=1,
        payload=payload
        or (
            "北京故宫适合上午参观。\n"
            "预约信息应来自已批准的一方知识。\n"
            "实时开放时间必须调用工具确认。"
        ).encode("utf-8"),
        media_type="text/plain",
        embedding_model_ref="embedding://offline-fixture/v1",
        metadata_payload={"language": "zh-CN"},
    )


def _tenant_count(session: Session, model: type, tenant_id: str) -> int:
    return int(
        session.scalar(
            select(func.count())
            .select_from(model)
            .where(model.tenant_id == tenant_id)
        )
        or 0
    )


class _CountingParser(DeterministicTextParser):
    def __init__(self) -> None:
        super().__init__()
        self.calls = 0

    def parse(self, *, payload: bytes, media_type: str):
        self.calls += 1
        return super().parse(payload=payload, media_type=media_type)


class _FailAfterSourceRepository(KnowledgeRepository):
    def create_source(self, **kwargs):
        super().create_source(**kwargs)
        raise RuntimeError("ingestion.retryable_fixture_failure")


def test_authorize_permission_is_checked_before_parse_and_writes(
    ingestion_database,
) -> None:
    tenant_id = "tenant-ingestion-authorize"
    parser = _CountingParser()
    request = _request(tenant_id)
    request = IngestionRequest(
        context=_context(tenant_id, permissions=frozenset()),
        source_key=request.source_key,
        source_class=request.source_class,
        owner_principal_id=request.owner_principal_id,
        license_identifier=request.license_identifier,
        purpose=request.purpose,
        version_number=request.version_number,
        payload=request.payload,
        media_type=request.media_type,
        embedding_model_ref=request.embedding_model_ref,
        metadata_payload=request.metadata_payload,
    )
    with ingestion_database() as session, session.begin():
        _set_tenant(session, tenant_id)
        with pytest.raises(KnowledgeAuthorizationDenied):
            KnowledgeIngestionPipeline(session, parser=parser).ingest(request)
        assert parser.calls == 0
        assert _tenant_count(session, KnowledgeSourceRecord, tenant_id) == 0


def test_idempotent_duplicate_source_version_has_one_durable_effect(
    ingestion_database,
) -> None:
    tenant_id = "tenant-ingestion-idempotent"
    request = _request(tenant_id)
    with ingestion_database() as session, session.begin():
        _set_tenant(session, tenant_id)
        first = KnowledgeIngestionPipeline(session).ingest(request)
        assert not first.replayed
    with ingestion_database() as session, session.begin():
        _set_tenant(session, tenant_id)
        replay = KnowledgeIngestionPipeline(session).ingest(request)
        assert replay.replayed
        assert replay.source_id == first.source_id
        assert replay.version_id == first.version_id
        assert replay.chunk_ids == first.chunk_ids
        assert replay.ingestion_receipt_id == first.ingestion_receipt_id
        assert replay.outbox_id == first.outbox_id
        assert _tenant_count(session, KnowledgeSourceRecord, tenant_id) == 1
        assert _tenant_count(session, KnowledgeSourceVersionRecord, tenant_id) == 1
        assert _tenant_count(session, KnowledgeChunkRecord, tenant_id) == len(
            first.chunk_ids
        )
        assert _tenant_count(session, KnowledgeIngestionReceiptRecord, tenant_id) == 1
        assert _tenant_count(session, KnowledgeOutboxRecord, tenant_id) == 1


def test_retry_resume_after_mid_transaction_failure_has_no_partial_success(
    ingestion_database,
) -> None:
    tenant_id = "tenant-ingestion-retry"
    request = _request(tenant_id)
    with pytest.raises(RuntimeError, match="retryable_fixture_failure"):
        with ingestion_database() as session, session.begin():
            _set_tenant(session, tenant_id)
            KnowledgeIngestionPipeline(
                session, repository_factory=_FailAfterSourceRepository
            ).ingest(request)

    with ingestion_database() as session, session.begin():
        _set_tenant(session, tenant_id)
        assert _tenant_count(session, KnowledgeSourceRecord, tenant_id) == 0
        resumed = KnowledgeIngestionPipeline(session).ingest(request)
        assert not resumed.replayed
        assert resumed.receipt_created
        assert resumed.outbox_created


def test_embedding_retry_is_bounded_and_receipt_is_replayable(
    ingestion_database,
) -> None:
    tenant_id = "tenant-ingestion-bounded-retry"
    planner = EmbeddingJobPlanner(batch_size=2, max_attempts=3)
    chunker = DeterministicChunker(
        ChunkerConfig(max_tokens=8, overlap_tokens=2, max_chunks=32)
    )
    with ingestion_database() as session, session.begin():
        _set_tenant(session, tenant_id)
        result = KnowledgeIngestionPipeline(
            session,
            chunker=chunker,
            embedding_planner=planner,
        ).ingest(_request(tenant_id))
        receipt = session.get(
            KnowledgeIngestionReceiptRecord, result.ingestion_receipt_id
        )
        outbox = session.get(KnowledgeOutboxRecord, result.outbox_id)
        assert receipt is not None
        assert receipt.status == "succeeded"
        assert receipt.chunk_count == len(result.chunk_ids)
        assert result.embedding_plan.max_attempts == 3
        assert len(result.embedding_plan.batches) >= 2
        assert outbox is not None
        assert outbox.max_attempts == 3
        assert outbox.payload_digest == result.embedding_plan.plan_digest


def test_parse_chunk_embed_plan_is_deterministic_across_line_endings() -> None:
    parser = DeterministicTextParser()
    left = parser.parse(payload="Cafe\u0301\r\n故宫  指南  ".encode(), media_type="text/plain")
    right = parser.parse(payload="Café\n故宫  指南".encode(), media_type="text/plain")
    assert left.content_digest == right.content_digest
    chunker = DeterministicChunker(ChunkerConfig(max_tokens=8, overlap_tokens=2))
    left_chunks = chunker.chunk(left)
    right_chunks = chunker.chunk(right)
    assert left_chunks == right_chunks
    planner = EmbeddingJobPlanner(batch_size=2, max_attempts=2)
    arguments = {
        "tenant_id": "tenant-deterministic",
        "source_key": "guide:deterministic",
        "version_number": 1,
        "model_ref": "embedding://offline-fixture/v1",
    }
    assert planner.plan(chunks=left_chunks, **arguments) == planner.plan(
        chunks=right_chunks, **arguments
    )
