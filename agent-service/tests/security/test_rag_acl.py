from __future__ import annotations

import hashlib
import os
import site
import sys
import uuid
from dataclasses import dataclass
from pathlib import Path

import pytest
from alembic import command
from alembic.config import Config
from sqlalchemy import create_engine, func, select, text
from sqlalchemy.engine import Engine, make_url
from sqlalchemy.orm import Session, sessionmaker
from sqlalchemy.schema import CreateSchema, DropSchema


SERVICE_ROOT = Path(__file__).resolve().parents[2]
site.addsitedir(str(SERVICE_ROOT / ".venv" / "Lib" / "site-packages"))
sys.path.insert(0, str(SERVICE_ROOT))

from app.persistence.models.behavior import BEHAVIOR_SCHEMA  # noqa: E402
from app.persistence.models.knowledge import (  # noqa: E402
    KNOWLEDGE_SCHEMA,
    KnowledgeAclEntryRecord,
)
from app.persistence.models.runtime import RUNTIME_SCHEMA  # noqa: E402
from app.persistence.repositories.knowledge import (  # noqa: E402
    KnowledgeRepository,
    KnowledgeWriteContext,
)
from app.rag.filters import (  # noqa: E402
    AclFilteredKnowledgeSearch,
    RagAccessDenied,
    RetrievalContext,
)
from app.rag.indexes import (  # noqa: E402
    EMBEDDING_DIMENSIONS,
    EmbeddingModelSpec,
    KnowledgeIndexRepository,
)
from app.rag.materialize import KnowledgeMaterializer  # noqa: E402


ALEMBIC_INI = SERVICE_ROOT / "alembic.ini"
TARGET_REVISION = "p11_004_pgvector_fts"
VERSION_SCHEMA = "p11_005_acl_test"
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
MODEL_NAMESPACE = uuid.UUID("00000000-0000-4000-8000-000000001105")
MODEL_REF = "embedding://offline-fixture/acl-d1024-v1"
MODEL_CONFIG_DIGEST = hashlib.sha256(
    f"{MODEL_REF}|{EMBEDDING_DIMENSIONS}|cosine".encode("ascii")
).hexdigest()
WRITE_PERMISSIONS = frozenset(
    {
        "knowledge.acl.manage",
        "knowledge.chunk.create",
        "knowledge.source.create",
        "knowledge.version.create",
    }
)


@dataclass(frozen=True, slots=True)
class SeededSource:
    tenant_id: str
    source_id: uuid.UUID
    version_id: uuid.UUID
    chunk_id: uuid.UUID
    text_content: str
    embedding_model_id: uuid.UUID


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
def acl_database():
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


def _embedding(text_value: str) -> tuple[float, ...]:
    seed = hashlib.sha256(text_value.encode("utf-8")).digest()
    return tuple(
        ((seed[index % len(seed)] + 1) / 256.0)
        for index in range(EMBEDDING_DIMENSIONS)
    )


def _seed_source(
    factory: sessionmaker[Session],
    *,
    tenant_id: str,
    label: str,
    text_content: str,
    source_class: str = "tenant_private_curated",
    license_identifier: str = "tenant-owned",
    acl_subject: tuple[str, str] | None = ("principal", "principal-reader"),
) -> SeededSource:
    model_id = uuid.uuid5(MODEL_NAMESPACE, tenant_id)
    context = KnowledgeWriteContext(
        tenant_id=tenant_id,
        principal_id="principal-owner",
        audit_receipt_id=f"audit-{label}",
        permissions=WRITE_PERMISSIONS,
    )
    content_digest = hashlib.sha256(text_content.encode("utf-8")).hexdigest()
    parser_digest = hashlib.sha256(b"acl-parser-v1").hexdigest()
    with factory() as session, session.begin():
        _set_tenant(session, tenant_id)
        repository = KnowledgeRepository(session)
        source = repository.create_source(
            context=context,
            source_key=f"acl:{label}",
            source_class=source_class,
            owner_principal_id="principal-owner",
            license_identifier=license_identifier,
            purpose="travel_knowledge_retrieval",
        ).record
        version = repository.create_source_version(
            context=context,
            source_id=source.source_id,
            version_number=1,
            content_digest=content_digest,
            parser_digest=parser_digest,
            metadata_payload={"fixture": label},
        ).record
        chunk = repository.add_chunk(
            context=context,
            source_id=source.source_id,
            version_id=version.version_id,
            chunk_ordinal=0,
            chunk_digest=content_digest,
            text_content=text_content,
            token_count=max(1, len(text_content)),
            metadata_payload={"fixture": label},
        ).record
        if acl_subject is not None:
            repository.grant_read(
                context=context,
                source_id=source.source_id,
                subject_type=acl_subject[0],
                subject_id=acl_subject[1],
            )
        session.execute(
            text(
                """
                UPDATE agent_knowledge.source_versions
                SET status = 'indexed'
                WHERE tenant_id = :tenant_id AND version_id = :version_id
                """
            ),
            {"tenant_id": tenant_id, "version_id": version.version_id},
        )
        indexes = KnowledgeIndexRepository(session)
        indexes.register_model(
            tenant_id=tenant_id,
            spec=EmbeddingModelSpec(
                embedding_model_id=model_id,
                model_ref=MODEL_REF,
                config_digest=MODEL_CONFIG_DIGEST,
            ),
            audit_receipt_id=f"audit-model-{label}",
        )
        indexes.index_chunk(
            tenant_id=tenant_id,
            chunk_id=chunk.chunk_id,
            embedding_model_id=model_id,
            embedding=_embedding(text_content),
            text_content=text_content,
        )
        return SeededSource(
            tenant_id=tenant_id,
            source_id=source.source_id,
            version_id=version.version_id,
            chunk_id=chunk.chunk_id,
            text_content=text_content,
            embedding_model_id=model_id,
        )


def test_acl_attack_principal_is_denied_by_sql_hard_filter(acl_database) -> None:
    factory = acl_database
    seeded = _seed_source(
        factory,
        tenant_id="tenant-acl-attack",
        label="attack-principal",
        text_content="故宫权限边界只对明确授权主体开放",
    )
    with factory() as session, session.begin():
        _set_tenant(session, seeded.tenant_id)
        search = AclFilteredKnowledgeSearch(session)
        denied = RetrievalContext(
            tenant_id=seeded.tenant_id,
            principal_id="principal-attacker",
        )
        assert not search.vector_candidates(
            context=denied,
            embedding_model_id=seeded.embedding_model_id,
            query_embedding=_embedding(seeded.text_content),
        )
        assert not search.lexical_candidates(context=denied, query_text="故宫权限")


def test_tenant_rls_mismatch_denies_cross_tenant_candidate(acl_database) -> None:
    factory = acl_database
    seeded = _seed_source(
        factory,
        tenant_id="tenant-rls-owner",
        label="rls-owner",
        text_content="跨租户检索攻击必须由显式过滤和RLS共同拒绝",
    )
    other_context = RetrievalContext(
        tenant_id="tenant-rls-other",
        principal_id="principal-reader",
    )
    with factory() as session, session.begin():
        _set_tenant(session, other_context.tenant_id)
        search = AclFilteredKnowledgeSearch(session)
        assert not search.vector_candidates(
            context=other_context,
            embedding_model_id=seeded.embedding_model_id,
            query_embedding=_embedding(seeded.text_content),
        )
        assert not KnowledgeMaterializer(session).materialize(
            context=other_context,
            candidate_chunk_ids=(seeded.chunk_id,),
        )
        mismatched = RetrievalContext(
            tenant_id=seeded.tenant_id,
            principal_id="principal-reader",
        )
        with pytest.raises(RagAccessDenied, match="retrieval_access_denied"):
            search.lexical_candidates(context=mismatched, query_text="跨租户")


def test_acl_revocation_is_immediate_at_materialization_recheck(acl_database) -> None:
    factory = acl_database
    seeded = _seed_source(
        factory,
        tenant_id="tenant-acl-revocation",
        label="revocation",
        text_content="撤销以后旧候选不得被物化",
    )
    context = RetrievalContext(
        tenant_id=seeded.tenant_id,
        principal_id="principal-reader",
    )
    with factory() as session, session.begin():
        _set_tenant(session, seeded.tenant_id)
        hits = AclFilteredKnowledgeSearch(session).lexical_candidates(
            context=context,
            query_text="撤销以后",
        )
        assert [hit.chunk_id for hit in hits] == [seeded.chunk_id]

    with factory() as session, session.begin():
        _set_tenant(session, seeded.tenant_id)
        session.execute(
            text(
                """
                UPDATE agent_knowledge.acl_entries
                SET revoked_at = statement_timestamp()
                WHERE tenant_id = :tenant_id AND source_id = :source_id
                  AND subject_type = 'principal' AND subject_id = :principal_id
                """
            ),
            {
                "principal_id": context.principal_id,
                "source_id": seeded.source_id,
                "tenant_id": seeded.tenant_id,
            },
        )

    with factory() as session, session.begin():
        _set_tenant(session, seeded.tenant_id)
        assert not KnowledgeMaterializer(session).materialize(
            context=context,
            candidate_chunk_ids=tuple(hit.chunk_id for hit in hits),
        )
        assert not AclFilteredKnowledgeSearch(session).lexical_candidates(
            context=context,
            query_text="撤销以后",
        )


def test_group_acl_authorizes_only_matching_group(acl_database) -> None:
    factory = acl_database
    seeded = _seed_source(
        factory,
        tenant_id="tenant-acl-group",
        label="group",
        text_content="团队行程知识只允许匹配组读取",
        acl_subject=("group", "trip-editors"),
    )
    with factory() as session, session.begin():
        _set_tenant(session, seeded.tenant_id)
        search = AclFilteredKnowledgeSearch(session)
        allowed = RetrievalContext(
            tenant_id=seeded.tenant_id,
            principal_id="principal-group-member",
            group_ids=("trip-editors",),
        )
        denied = RetrievalContext(
            tenant_id=seeded.tenant_id,
            principal_id="principal-group-outsider",
            group_ids=("other-group",),
        )
        assert [
            hit.chunk_id
            for hit in search.lexical_candidates(context=allowed, query_text="团队行程")
        ] == [seeded.chunk_id]
        assert not search.lexical_candidates(context=denied, query_text="团队行程")


def test_public_policy_denies_bad_license_and_anonymous_attack(acl_database) -> None:
    factory = acl_database
    tenant_id = "tenant-public-policy"
    valid = _seed_source(
        factory,
        tenant_id=tenant_id,
        label="public-valid",
        text_content="公共许可知识可供已认证租户检索",
        source_class="public_licensed_reference",
        license_identifier="cc-by-4.0",
        acl_subject=None,
    )
    invalid = _seed_source(
        factory,
        tenant_id=tenant_id,
        label="public-invalid",
        text_content="未知许可内容必须拒绝",
        source_class="public_licensed_reference",
        license_identifier="unknown-license",
        acl_subject=None,
    )
    context = RetrievalContext(tenant_id=tenant_id, principal_id="principal-reader")
    with factory() as session, session.begin():
        _set_tenant(session, tenant_id)
        search = AclFilteredKnowledgeSearch(session)
        assert [
            hit.chunk_id
            for hit in search.lexical_candidates(context=context, query_text="公共许可")
        ] == [valid.chunk_id]
        assert not search.lexical_candidates(context=context, query_text="未知许可")
        assert not KnowledgeMaterializer(session).materialize(
            context=context,
            candidate_chunk_ids=(invalid.chunk_id,),
        )
        with pytest.raises(RagAccessDenied, match="retrieval_access_denied"):
            RetrievalContext(tenant_id=tenant_id, principal_id="")


def test_acl_rows_remain_rls_protected(acl_database) -> None:
    factory = acl_database
    seeded = _seed_source(
        factory,
        tenant_id="tenant-acl-row-owner",
        label="acl-row-owner",
        text_content="ACL行本身也必须保持租户隔离",
    )
    with factory() as session, session.begin():
        _set_tenant(session, "tenant-acl-row-other")
        leaked = session.execute(
            select(KnowledgeAclEntryRecord).where(
                KnowledgeAclEntryRecord.source_id == seeded.source_id
            )
        ).scalars()
        assert not tuple(leaked)
