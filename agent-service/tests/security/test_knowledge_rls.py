from __future__ import annotations

import hashlib
import os
import site
import sys
import uuid
from pathlib import Path

import pytest
from alembic import command
from alembic.config import Config
from sqlalchemy import create_engine, func, inspect, select, text
from sqlalchemy.engine import Engine, make_url
from sqlalchemy.exc import DatabaseError, ProgrammingError
from sqlalchemy.orm import Session, sessionmaker
from sqlalchemy.schema import CreateSchema, DropSchema


SERVICE_ROOT = Path(__file__).resolve().parents[2]
site.addsitedir(str(SERVICE_ROOT / ".venv" / "Lib" / "site-packages"))
sys.path.insert(0, str(SERVICE_ROOT))

from app.persistence.models.behavior import BEHAVIOR_SCHEMA  # noqa: E402
from app.persistence.models.knowledge import (  # noqa: E402
    KNOWLEDGE_SCHEMA,
    KnowledgeAclEntryRecord,
    KnowledgeChunkRecord,
    KnowledgeIngestionReceiptRecord,
    KnowledgeManifestRecord,
    KnowledgeOutboxRecord,
    KnowledgeSourceRecord,
    KnowledgeSourceVersionRecord,
)
from app.persistence.models.runtime import RUNTIME_SCHEMA  # noqa: E402
from app.persistence.repositories.knowledge import (  # noqa: E402
    KnowledgeRepository,
    KnowledgeWriteContext,
)


ALEMBIC_INI = SERVICE_ROOT / "alembic.ini"
TARGET_REVISION = "p11_002_knowledge_rls_outbox"
VERSION_SCHEMA = "p11_002_rls_test"
DATABASE_URL = os.environ.get(
    "GONOW_P11_TEST_DATABASE_URL",
    "postgresql+pg8000://gonow_migrator_test@127.0.0.1:55432/gonow_p03_test",
)
ADMIN_DATABASE_URL = (
    "postgresql+pg8000://gonow_bootstrap_admin@127.0.0.1:55432/gonow_p03_test"
)
PRINCIPALS_SQL = Path(__file__).with_name("fixtures") / "rls_principals.sql"
ROLES = (
    "gonow_agent_api",
    "gonow_agent_worker",
    "gonow_command_service",
    "gonow_release_operator",
    "gonow_observer",
)
TENANTS = ("tenant-alpha", "tenant-beta")
RLS_TABLES = (
    "sources",
    "source_versions",
    "acl_entries",
    "chunks",
    "manifests",
    "manifest_entries",
    "ingestion_receipts",
    "outbox_messages",
)
ALL_PERMISSIONS = frozenset(
    {
        "knowledge.source.create",
        "knowledge.version.create",
        "knowledge.acl.manage",
        "knowledge.chunk.create",
        "knowledge.manifest.create",
        "knowledge.ingestion.complete",
        "knowledge.outbox.enqueue",
    }
)


def _assert_task_owned_database() -> None:
    parsed = make_url(DATABASE_URL)
    assert parsed.drivername == "postgresql+pg8000"
    assert parsed.host == "127.0.0.1"
    assert parsed.port == 55432
    assert parsed.username == "gonow_migrator_test"
    assert parsed.database == "gonow_p03_test"
    assert parsed.password is None


def _config(monkeypatch: pytest.MonkeyPatch) -> Config:
    monkeypatch.setenv("GONOW_DATABASE_URL", DATABASE_URL)
    monkeypatch.setenv("GONOW_ALEMBIC_VERSION_SCHEMA", VERSION_SCHEMA)
    return Config(str(ALEMBIC_INI))


def _provision_principals(admin_engine: Engine) -> None:
    with admin_engine.begin() as connection:
        connection.exec_driver_sql(PRINCIPALS_SQL.read_text(encoding="utf-8"))


def _drop_principals(admin_engine: Engine) -> None:
    with admin_engine.begin() as connection:
        for role in ROLES:
            connection.exec_driver_sql(f"DROP OWNED BY {role}")
        for role in ROLES:
            connection.exec_driver_sql(f"DROP ROLE IF EXISTS {role}")


def _reset(engine: Engine, admin_engine: Engine, config: Config) -> None:
    with engine.begin() as connection:
        for schema in (KNOWLEDGE_SCHEMA, BEHAVIOR_SCHEMA, RUNTIME_SCHEMA, VERSION_SCHEMA):
            connection.execute(DropSchema(schema, cascade=True, if_exists=True))
        connection.execute(CreateSchema(VERSION_SCHEMA))
    _provision_principals(admin_engine)
    command.upgrade(config, TARGET_REVISION)


@pytest.fixture()
def knowledge_database(monkeypatch: pytest.MonkeyPatch):
    _assert_task_owned_database()
    engine = create_engine(DATABASE_URL, pool_pre_ping=True)
    admin_engine = create_engine(ADMIN_DATABASE_URL, pool_pre_ping=True)
    config = _config(monkeypatch)
    _reset(engine, admin_engine, config)
    owner_factory = sessionmaker(engine, expire_on_commit=False)
    admin_factory = sessionmaker(admin_engine, expire_on_commit=False)
    try:
        yield engine, admin_engine, config, owner_factory, admin_factory
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


def _set_tenant(session: Session, tenant_id: str) -> None:
    session.execute(select(func.set_config("app.tenant_id", tenant_id, True)))


def _assume_role(session: Session, role: str, tenant_id: str | None) -> None:
    assert role in ROLES
    session.execute(text(f"SET LOCAL ROLE {role}"))
    if tenant_id is not None:
        _set_tenant(session, tenant_id)


def _digest(value: str) -> str:
    return hashlib.sha256(value.encode("utf-8")).hexdigest()


def _seed_tenant(session: Session, tenant_id: str) -> dict[str, str]:
    _set_tenant(session, tenant_id)
    context = KnowledgeWriteContext(
        tenant_id=tenant_id,
        principal_id=f"principal-{tenant_id}",
        audit_receipt_id=f"audit-{tenant_id}",
        permissions=ALL_PERMISSIONS,
    )
    repository = KnowledgeRepository(session)
    source = repository.create_source(
        context=context,
        source_key=f"docs:{tenant_id}",
        source_class="tenant_private_curated",
        owner_principal_id=f"owner-{tenant_id}",
        license_identifier="tenant-owned",
        purpose="itinerary_planning",
    ).record
    version = repository.create_source_version(
        context=context,
        source_id=source.source_id,
        version_number=1,
        content_digest=_digest(f"document-{tenant_id}"),
        parser_digest=_digest("parser-v1"),
        metadata_payload={"language": "zh-CN", "tenant_marker": tenant_id},
    ).record
    repository.grant_read(
        context=context,
        source_id=source.source_id,
        subject_type="principal",
        subject_id=context.principal_id,
    )
    chunk = repository.add_chunk(
        context=context,
        source_id=source.source_id,
        version_id=version.version_id,
        chunk_ordinal=0,
        chunk_digest=_digest(f"chunk-{tenant_id}"),
        text_content=f"curated knowledge for {tenant_id}",
        token_count=4,
        metadata_payload={"heading": "overview"},
    ).record
    manifest = repository.create_manifest(
        context=context,
        manifest_digest=_digest(f"manifest-{tenant_id}"),
        tokenizer_version="deterministic-zh-v1",
        embedding_model_ref="embedding://offline-fixture/v1",
    ).record
    repository.add_manifest_entry(
        context=context,
        manifest_id=manifest.manifest_id,
        chunk_id=chunk.chunk_id,
        entry_ordinal=0,
    )
    repository.record_ingestion_receipt(
        context=context,
        source_id=source.source_id,
        version_id=version.version_id,
        pipeline_digest=_digest("pipeline-v1"),
        status="succeeded",
        chunk_count=1,
        failure_code=None,
    )
    repository.enqueue_outbox(
        context=context,
        event_type="knowledge.version.staged",
        aggregate_type="version",
        aggregate_id=version.version_id,
        idempotency_key=f"version-staged:{version.version_id}",
        payload_digest=_digest(f"event-{tenant_id}"),
    )
    return {
        "source_key": source.source_key,
        "content_digest": version.content_digest,
        "chunk_digest": chunk.chunk_digest,
        "manifest_digest": manifest.manifest_digest,
    }


def _seed_all(factory: sessionmaker[Session]) -> dict[str, dict[str, str]]:
    result: dict[str, dict[str, str]] = {}
    for tenant_id in TENANTS:
        with factory() as session, session.begin():
            result[tenant_id] = _seed_tenant(session, tenant_id)
    return result


def test_tenant_rls_positive_negative_read_matrix(knowledge_database) -> None:
    _, _, _, owner_factory, admin_factory = knowledge_database
    _seed_all(owner_factory)
    leakage_count = 0
    for role in ("gonow_agent_api", "gonow_agent_worker"):
        for tenant_id in TENANTS:
            with admin_factory() as session, session.begin():
                _assume_role(session, role, tenant_id)
                sources = session.scalars(select(KnowledgeSourceRecord)).all()
                chunks = session.scalars(select(KnowledgeChunkRecord)).all()
                receipts = session.scalars(select(KnowledgeIngestionReceiptRecord)).all()
                leakage_count += sum(row.tenant_id != tenant_id for row in sources)
                leakage_count += sum(row.tenant_id != tenant_id for row in chunks)
                leakage_count += sum(row.tenant_id != tenant_id for row in receipts)
                assert len(sources) == len(chunks) == len(receipts) == 1
    assert leakage_count == 0


def test_unset_context_and_parameterized_repository_deny_cross_tenant_write(
    knowledge_database,
) -> None:
    _, _, _, owner_factory, admin_factory = knowledge_database
    seeded = _seed_all(owner_factory)
    with admin_factory() as session, session.begin():
        _assume_role(session, "gonow_agent_api", None)
        assert session.scalar(select(func.count()).select_from(KnowledgeSourceRecord)) == 0
    with admin_factory() as session, session.begin():
        _assume_role(session, "gonow_agent_api", TENANTS[0])
        assert session.scalar(
            select(func.count())
            .select_from(KnowledgeSourceVersionRecord)
            .where(
                KnowledgeSourceVersionRecord.content_digest
                == seeded[TENANTS[1]]["content_digest"]
            )
        ) == 0
    with admin_factory() as session:
        with pytest.raises(DatabaseError):
            with session.begin():
                _assume_role(session, "gonow_agent_worker", TENANTS[0])
                session.add(
                    KnowledgeSourceRecord(
                        source_id=uuid.uuid4(),
                        tenant_id=TENANTS[1],
                        source_key="docs:cross-tenant",
                        source_class="tenant_private_curated",
                        owner_principal_id="cross-tenant-owner",
                        license_identifier="tenant-owned",
                        purpose="itinerary_planning",
                        status="active",
                        audit_receipt_id="audit-cross-tenant",
                    )
                )
                session.flush()
    repository_text = (
        SERVICE_ROOT / "app" / "persistence" / "repositories" / "knowledge.py"
    ).read_text(encoding="utf-8")
    assert "text(" not in repository_text
    assert "exec_driver_sql" not in repository_text


def test_roles_public_grants_and_force_rls_are_least_privilege(
    knowledge_database,
) -> None:
    _, _, _, _, admin_factory = knowledge_database
    with admin_factory() as session, session.begin():
        bypass_count = session.scalar(
            text(
                "SELECT count(*) FROM pg_roles WHERE rolname = ANY(:roles) "
                "AND (rolsuper OR rolbypassrls)"
            ),
            {"roles": list(ROLES)},
        )
        force_count = session.scalar(
            text(
                "SELECT count(*) FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace "
                "WHERE n.nspname=:schema AND c.relname=ANY(:tables) "
                "AND c.relrowsecurity AND c.relforcerowsecurity"
            ),
            {"schema": KNOWLEDGE_SCHEMA, "tables": list(RLS_TABLES)},
        )
        policy_count = session.scalar(
            text("SELECT count(*) FROM pg_policies WHERE schemaname=:schema"),
            {"schema": KNOWLEDGE_SCHEMA},
        )
        public_grants = session.scalar(
            text(
                "SELECT count(*) FROM information_schema.role_table_grants "
                "WHERE table_schema=:schema AND grantee='PUBLIC'"
            ),
            {"schema": KNOWLEDGE_SCHEMA},
        )
        observer_schema_usage = session.scalar(
            text("SELECT has_schema_privilege('gonow_observer', :schema, 'USAGE')"),
            {"schema": KNOWLEDGE_SCHEMA},
        )
        assert bypass_count == 0
        assert force_count == len(RLS_TABLES)
        assert policy_count == len(RLS_TABLES)
        assert public_grants == 0
        assert observer_schema_usage is False
    with admin_factory() as session:
        with pytest.raises(ProgrammingError):
            with session.begin():
                _assume_role(session, "gonow_observer", TENANTS[0])
                session.scalar(select(func.count()).select_from(KnowledgeManifestRecord))


def test_schema_rebuild_and_logical_restore_preserve_knowledge_identity(
    knowledge_database,
) -> None:
    engine, admin_engine, config, owner_factory, admin_factory = knowledge_database
    before = _seed_all(owner_factory)
    with admin_factory() as session, session.begin():
        revision = session.scalar(
            text(f"SELECT version_num FROM {VERSION_SCHEMA}.alembic_version")
        )
        assert revision == TARGET_REVISION
    _reset(engine, admin_engine, config)
    after = _seed_all(owner_factory)
    assert after == before
    inspector = inspect(engine)
    assert set(RLS_TABLES).issubset(set(inspector.get_table_names(schema=KNOWLEDGE_SCHEMA)))
    with owner_factory() as session, session.begin():
        _set_tenant(session, TENANTS[0])
        assert session.scalar(select(func.count()).select_from(KnowledgeAclEntryRecord)) == 1
        assert session.scalar(select(func.count()).select_from(KnowledgeOutboxRecord)) == 1
    with pytest.raises(RuntimeError, match="forward-fix only"):
        command.downgrade(config, "p10_001_runtime_composition")
