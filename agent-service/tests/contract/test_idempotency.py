from __future__ import annotations

import json
import os
import site
import sys
import uuid
from concurrent.futures import ThreadPoolExecutor
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
from app.persistence.models.runtime import (  # noqa: E402
    IdempotencyRecord,
    RUNTIME_SCHEMA,
    RunRecord,
)
from app.persistence.repositories.runs import (  # noqa: E402
    IdempotencyConflict,
    RunsRepository,
)


ALEMBIC_INI = SERVICE_ROOT / "alembic.ini"
TARGET_REVISION = "p03_007_runtime_rls"
VERSION_SCHEMA = "p03_008_idempotency_test"
DATABASE_URL = os.environ.get(
    "GONOW_P03_TEST_DATABASE_URL",
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
TENANT = "tenant-p03-008-idempotency"
PRINCIPAL = "principal-p03-008-idempotency"
MANIFEST_DIGEST = "2" * 64
REQUEST_HASH = "1" * 64
REPORT_ENV = "GONOW_P03_008_EVIDENCE_DIR"
EXPECTED_EVIDENCE_DIRECTORY = (
    SERVICE_ROOT.parent
    / "docs"
    / "execution"
    / "evidence"
    / "phase-03"
    / "P03-008"
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


def _drop_schemas(engine: Engine) -> None:
    with engine.begin() as connection:
        connection.execute(DropSchema(BEHAVIOR_SCHEMA, cascade=True, if_exists=True))
        connection.execute(DropSchema(RUNTIME_SCHEMA, cascade=True, if_exists=True))
        connection.execute(DropSchema(VERSION_SCHEMA, cascade=True, if_exists=True))


@pytest.fixture(scope="module")
def idempotency_database():
    _assert_task_owned_database()
    patch = pytest.MonkeyPatch()
    patch.setenv("GONOW_DATABASE_URL", DATABASE_URL)
    patch.setenv("GONOW_ALEMBIC_VERSION_SCHEMA", VERSION_SCHEMA)
    engine = create_engine(
        DATABASE_URL,
        pool_pre_ping=True,
        pool_size=10,
        max_overflow=10,
        pool_timeout=30,
    )
    admin_engine = create_engine(ADMIN_DATABASE_URL, pool_pre_ping=True)
    config = Config(str(ALEMBIC_INI))
    _drop_schemas(engine)
    with engine.begin() as connection:
        connection.execute(CreateSchema(VERSION_SCHEMA))
    _provision_principals(admin_engine)
    command.upgrade(config, TARGET_REVISION)
    factory = sessionmaker(engine, expire_on_commit=False)
    try:
        yield factory
    finally:
        engine.dispose()
        cleanup_engine = create_engine(DATABASE_URL)
        try:
            _drop_schemas(cleanup_engine)
        finally:
            cleanup_engine.dispose()
        _drop_principals(admin_engine)
        admin_engine.dispose()
        patch.undo()


def _set_tenant(session: Session) -> None:
    session.execute(select(func.set_config("app.tenant_id", TENANT, True)))


def _create_thread(factory: sessionmaker[Session]) -> uuid.UUID:
    with factory.begin() as session:
        _set_tenant(session)
        return RunsRepository(session).create_thread(
            tenant_id=TENANT,
            owner_principal_id=PRINCIPAL,
        ).thread_id


def _create_or_replay(
    factory: sessionmaker[Session],
    thread_id: uuid.UUID,
    *,
    key: str,
    request_hash: str,
):
    with factory.begin() as session:
        _set_tenant(session)
        return RunsRepository(session).create_or_replay_run(
            tenant_id=TENANT,
            principal_id=PRINCIPAL,
            thread_id=thread_id,
            request_scope="itinerary.generate",
            idempotency_key=key,
            request_hash=request_hash,
            manifest_digest=MANIFEST_DIGEST,
            manifest={"behavior_release": "phase-03-concurrency-fixture"},
        )


def _write_report(name: str, value: dict[str, object]) -> None:
    requested = os.environ.get(REPORT_ENV, "").strip()
    if not requested:
        return
    directory = Path(requested).resolve()
    assert directory == EXPECTED_EVIDENCE_DIRECTORY.resolve()
    directory.mkdir(parents=True, exist_ok=True)
    (directory / name).write_text(
        json.dumps(value, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )


def test_ct_001_fifty_same_key_same_body_create_exactly_one_run(
    idempotency_database,
) -> None:
    factory = idempotency_database
    thread_id = _create_thread(factory)

    def submit(_: int):
        return _create_or_replay(
            factory,
            thread_id,
            key="ct-001-fifty-callers",
            request_hash=REQUEST_HASH,
        )

    with ThreadPoolExecutor(max_workers=50) as executor:
        results = list(executor.map(submit, range(50)))

    run_ids = {result.run_id for result in results}
    original_count = sum(not result.replayed for result in results)
    replay_count = sum(result.replayed for result in results)
    with factory.begin() as session:
        _set_tenant(session)
        run_count = session.scalar(select(func.count()).select_from(RunRecord))
        idempotency_count = session.scalar(
            select(func.count()).select_from(IdempotencyRecord)
        )
    assert len(run_ids) == 1
    assert original_count == 1
    assert replay_count == 49
    assert run_count == 1
    assert idempotency_count == 1
    _write_report(
        "ct-001.json",
        {
            "schema_version": "1.0",
            "task_id": "TASK-P03-008",
            "contract_test": "CT-001",
            "concurrent_callers": 50,
            "unique_run_count": len(run_ids),
            "original_winner_count": original_count,
            "replay_count": replay_count,
            "persisted_run_count": run_count,
            "persisted_idempotency_count": idempotency_count,
            "exactly_one_legal_winner": True,
            "production": False,
        },
    )


def test_ct_002_same_key_different_body_conflicts_without_second_run(
    idempotency_database,
) -> None:
    factory = idempotency_database
    thread_id = _create_thread(factory)
    _create_or_replay(
        factory,
        thread_id,
        key="ct-002-different-body",
        request_hash=REQUEST_HASH,
    )
    with pytest.raises(IdempotencyConflict, match="idempotency.conflict"):
        _create_or_replay(
            factory,
            thread_id,
            key="ct-002-different-body",
            request_hash="3" * 64,
        )
    with factory.begin() as session:
        _set_tenant(session)
        run_count = session.scalar(
            select(func.count())
            .select_from(RunRecord)
            .where(RunRecord.thread_id == thread_id)
        )
        idempotency_count = session.scalar(
            select(func.count())
            .select_from(IdempotencyRecord)
            .where(IdempotencyRecord.idempotency_key == "ct-002-different-body")
        )
    assert run_count == 1
    assert idempotency_count == 1
    _write_report(
        "ct-002.json",
        {
            "schema_version": "1.0",
            "task_id": "TASK-P03-008",
            "contract_test": "CT-002",
            "conflict_code": IdempotencyConflict.code,
            "persisted_run_count": run_count,
            "persisted_idempotency_count": idempotency_count,
            "different_body_rejected": True,
            "production": False,
        },
    )
