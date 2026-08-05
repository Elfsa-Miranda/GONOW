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
from sqlalchemy import MetaData, Table, create_engine, func, inspect, select, update
from sqlalchemy.engine import Engine, make_url
from sqlalchemy.exc import DatabaseError
from sqlalchemy.orm import Session, sessionmaker
from sqlalchemy.schema import CreateSchema, DropSchema


SERVICE_ROOT = Path(__file__).resolve().parents[2]
site.addsitedir(str(SERVICE_ROOT / ".venv" / "Lib" / "site-packages"))
sys.path.insert(0, str(SERVICE_ROOT))

from app.persistence.models.runtime import (  # noqa: E402
    EventRecord,
    IdempotencyRecord,
    RUNTIME_SCHEMA,
    RunRecord,
    RunState,
)
from app.persistence.repositories.events import EventsRepository  # noqa: E402
from app.persistence.repositories.runs import (  # noqa: E402
    IdempotencyConflict,
    RunStateConflict,
    RunsRepository,
)


ALEMBIC_INI = SERVICE_ROOT / "alembic.ini"
BASELINE_REVISION = "p03_001_runtime_baseline"
TARGET_REVISION = "p03_002_run_event_idempotency"
VERSION_SCHEMA = "p03_002_runtime_test"
DATABASE_URL = os.environ.get(
    "GONOW_P03_TEST_DATABASE_URL",
    "postgresql+pg8000://gonow_migrator_test@127.0.0.1:55432/gonow_p03_test",
)
RUNTIME_REPORT_ENV = "GONOW_P03_RUNTIME_REPORT"
EXPECTED_RUNTIME_REPORT = (
    SERVICE_ROOT.parent
    / "docs"
    / "execution"
    / "evidence"
    / "phase-03"
    / "P03-002"
    / "runtime-persistence-report.json"
)
TENANT = "tenant-runtime-a"
PRINCIPAL = "principal-runtime-a"
MANIFEST_DIGEST = "b" * 64
REQUEST_HASH = "a" * 64


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


def _reset(engine: Engine, config: Config) -> None:
    with engine.begin() as connection:
        connection.execute(DropSchema(RUNTIME_SCHEMA, cascade=True, if_exists=True))
        connection.execute(DropSchema(VERSION_SCHEMA, cascade=True, if_exists=True))
        connection.execute(CreateSchema(VERSION_SCHEMA))
    command.upgrade(config, TARGET_REVISION)


@pytest.fixture()
def runtime_database(monkeypatch: pytest.MonkeyPatch):
    _assert_task_owned_database()
    engine = create_engine(DATABASE_URL, pool_pre_ping=True)
    config = _config(monkeypatch)
    _reset(engine, config)
    try:
        yield engine, config
    finally:
        try:
            command.downgrade(config, "base")
        finally:
            with engine.begin() as connection:
                connection.execute(DropSchema(RUNTIME_SCHEMA, cascade=True, if_exists=True))
                connection.execute(DropSchema(VERSION_SCHEMA, cascade=True, if_exists=True))
            engine.dispose()


def _factory(engine: Engine) -> sessionmaker[Session]:
    return sessionmaker(engine, expire_on_commit=False)


def _thread(factory: sessionmaker[Session]) -> uuid.UUID:
    with factory.begin() as session:
        return RunsRepository(session).create_thread(
            tenant_id=TENANT,
            owner_principal_id=PRINCIPAL,
        ).thread_id


def _run(
    factory: sessionmaker[Session],
    thread_id: uuid.UUID,
    *,
    key: str,
    request_hash: str = REQUEST_HASH,
):
    with factory.begin() as session:
        return RunsRepository(session).create_or_replay_run(
            tenant_id=TENANT,
            principal_id=PRINCIPAL,
            thread_id=thread_id,
            request_scope="itinerary.generate",
            idempotency_key=key,
            request_hash=request_hash,
            manifest_digest=MANIFEST_DIGEST,
            manifest={"behavior_release": "phase-03-fixture"},
        )


def _write_report(value: dict[str, object]) -> None:
    requested = os.environ.get(RUNTIME_REPORT_ENV, "").strip()
    if not requested:
        return
    target = Path(requested).resolve()
    assert target == EXPECTED_RUNTIME_REPORT.resolve()
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(
        json.dumps(value, sort_keys=True, separators=(",", ":")),
        encoding="utf-8",
    )


def test_runtime_migration_rebuilds_and_enforces_seq_terminal_invariants(
    runtime_database,
) -> None:
    engine, config = runtime_database
    factory = _factory(engine)
    with engine.connect() as connection:
        tables = sorted(inspect(connection).get_table_names(schema=RUNTIME_SCHEMA))
        version_table = Table(
            "alembic_version",
            MetaData(),
            schema=VERSION_SCHEMA,
            autoload_with=connection,
        )
        revision = connection.execute(select(version_table.c.version_num)).scalar_one()
    assert tables == ["events", "idempotency_records", "runs", "threads"]
    assert revision == TARGET_REVISION

    thread_id = _thread(factory)
    created_run_id = uuid.uuid4()
    with pytest.raises(DatabaseError, match="run.created_not_committable"):
        with factory.begin() as session:
            session.add(
                RunRecord(
                    run_id=created_run_id,
                    thread_id=thread_id,
                    tenant_id=TENANT,
                    principal_id=PRINCIPAL,
                    state=RunState.CREATED.value,
                    manifest_digest=MANIFEST_DIGEST,
                    manifest={},
                    next_event_seq=1,
                    version=0,
                )
            )

    result = _run(factory, thread_id, key="rebuild-invariants")
    with factory.begin() as session:
        first = EventsRepository(session).append(
            tenant_id=TENANT,
            run_id=result.run_id,
            event_type="run.queued",
            payload={"state": "queued"},
            audit_receipt_id="audit-runtime-1",
        )
        second = EventsRepository(session).append(
            tenant_id=TENANT,
            run_id=result.run_id,
            event_type="run.observed",
            payload={"state": "queued"},
            audit_receipt_id="audit-runtime-2",
        )
    assert (first.seq, second.seq) == (1, 2)

    with factory.begin() as session:
        running = RunsRepository(session).transition_state(
            tenant_id=TENANT,
            run_id=result.run_id,
            expected_state=RunState.QUEUED,
            expected_version=1,
            target_state=RunState.RUNNING,
        )
    with factory.begin() as session:
        succeeded = RunsRepository(session).transition_state(
            tenant_id=TENANT,
            run_id=result.run_id,
            expected_state=RunState.RUNNING,
            expected_version=running.version,
            target_state=RunState.SUCCEEDED,
        )
    assert succeeded.state == RunState.SUCCEEDED.value
    with pytest.raises(DatabaseError, match="run.state_conflict"):
        with factory.begin() as session:
            session.execute(
                update(RunRecord)
                .where(RunRecord.run_id == result.run_id)
                .values(state=RunState.RUNNING.value)
            )

    command.downgrade(config, BASELINE_REVISION)
    with engine.connect() as connection:
        schema_after_downgrade = inspect(connection).has_schema(RUNTIME_SCHEMA)
    command.upgrade(config, TARGET_REVISION)
    with engine.connect() as connection:
        rebuilt_tables = sorted(inspect(connection).get_table_names(schema=RUNTIME_SCHEMA))
    assert schema_after_downgrade is False
    assert rebuilt_tables == tables
    _write_report(
        {
            "schema_version": "1.0",
            "task_id": "TASK-P03-002",
            "revision": revision,
            "empty_rebuild": True,
            "tables": tables,
            "rebuilt_tables": rebuilt_tables,
            "created_commit_rejected": True,
            "event_sequences": [first.seq, second.seq],
            "terminal_reversal_rejected": True,
            "downgrade_runtime_schema_present": schema_after_downgrade,
            "production": False,
        }
    )


def test_idempotency_replay_conflict_and_concurrent_single_winner(runtime_database) -> None:
    engine, _ = runtime_database
    factory = _factory(engine)
    thread_id = _thread(factory)

    def create() -> object:
        return _run(factory, thread_id, key="same-key")

    with ThreadPoolExecutor(max_workers=2) as executor:
        results = list(executor.map(lambda _: create(), range(2)))
    assert {item.run_id for item in results}.__len__() == 1
    assert sorted(item.replayed for item in results) == [False, True]
    with factory.begin() as session:
        assert session.scalar(select(func.count()).select_from(RunRecord)) == 1
        assert session.scalar(select(func.count()).select_from(IdempotencyRecord)) == 1
    with pytest.raises(IdempotencyConflict, match="idempotency.conflict"):
        _run(factory, thread_id, key="same-key", request_hash="c" * 64)


def test_run_state_repository_uses_version_cas(runtime_database) -> None:
    engine, _ = runtime_database
    factory = _factory(engine)
    thread_id = _thread(factory)
    result = _run(factory, thread_id, key="state-cas")
    with factory.begin() as session:
        changed = RunsRepository(session).transition_state(
            tenant_id=TENANT,
            run_id=result.run_id,
            expected_state=RunState.QUEUED,
            expected_version=1,
            target_state=RunState.RUNNING,
        )
    assert changed.version == 2
    with pytest.raises(RunStateConflict, match="run.state_conflict"):
        with factory.begin() as session:
            RunsRepository(session).transition_state(
                tenant_id=TENANT,
                run_id=result.run_id,
                expected_state=RunState.QUEUED,
                expected_version=1,
                target_state=RunState.RUNNING,
            )


def test_event_sequence_is_serialized_and_replayed_in_database_order(runtime_database) -> None:
    engine, _ = runtime_database
    factory = _factory(engine)
    thread_id = _thread(factory)
    result = _run(factory, thread_id, key="event-concurrency")

    def append(index: int) -> int:
        with factory.begin() as session:
            return EventsRepository(session).append(
                tenant_id=TENANT,
                run_id=result.run_id,
                event_type="run.progress",
                payload={"index": index},
                audit_receipt_id=f"audit-concurrency-{index}",
            ).seq

    with ThreadPoolExecutor(max_workers=4) as executor:
        assigned = list(executor.map(append, range(4)))
    assert sorted(assigned) == [1, 2, 3, 4]
    with factory.begin() as session:
        replay = EventsRepository(session).replay_after(
            tenant_id=TENANT,
            run_id=result.run_id,
            last_event_id=1,
        )
    assert [event.seq for event in replay] == [2, 3, 4]
    assert [event.seq for event in replay] == sorted(event.seq for event in replay)
    with factory.begin() as session:
        persisted = session.scalars(
            select(EventRecord).where(EventRecord.run_id == result.run_id)
        ).all()
    assert len(persisted) == 4
