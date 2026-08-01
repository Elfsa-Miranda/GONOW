from __future__ import annotations

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
from sqlalchemy.orm import sessionmaker
from sqlalchemy.schema import CreateSchema, DropSchema


SERVICE_ROOT = Path(__file__).resolve().parents[3]
site.addsitedir(str(SERVICE_ROOT / ".venv" / "Lib" / "site-packages"))
sys.path.insert(0, str(SERVICE_ROOT))

from app.persistence.models.runtime import EventRecord, RUNTIME_SCHEMA, RunRecord  # noqa: E402
from app.persistence.repositories.events import AuditReceiptRequired  # noqa: E402
from app.persistence.repositories.runs import RunsRepository  # noqa: E402
from app.runtime.event_writer import EventWriter, UnsafeEventPayload  # noqa: E402


ALEMBIC_INI = SERVICE_ROOT / "alembic.ini"
TARGET_REVISION = "p03_002_run_event_idempotency"
VERSION_SCHEMA = "p03_002_event_writer_test"
DATABASE_URL = os.environ.get(
    "GONOW_P03_TEST_DATABASE_URL",
    "postgresql+pg8000://gonow_migrator_test@127.0.0.1:55432/gonow_p03_test",
)
TENANT = "tenant-event-writer"
PRINCIPAL = "principal-event-writer"


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
def event_runtime(monkeypatch: pytest.MonkeyPatch):
    _assert_task_owned_database()
    engine = create_engine(DATABASE_URL, pool_pre_ping=True)
    config = _config(monkeypatch)
    _reset(engine, config)
    factory = sessionmaker(engine, expire_on_commit=False)
    with factory.begin() as session:
        thread = RunsRepository(session).create_thread(
            tenant_id=TENANT,
            owner_principal_id=PRINCIPAL,
        )
    with factory.begin() as session:
        run = RunsRepository(session).create_or_replay_run(
            tenant_id=TENANT,
            principal_id=PRINCIPAL,
            thread_id=thread.thread_id,
            request_scope="harness.event-writer",
            idempotency_key=str(uuid.uuid4()),
            request_hash="1" * 64,
            manifest_digest="2" * 64,
            manifest={"fixture": "event-writer"},
        )
    try:
        yield factory, run.run_id
    finally:
        try:
            command.downgrade(config, "base")
        finally:
            with engine.begin() as connection:
                connection.execute(
                    DropSchema(RUNTIME_SCHEMA, cascade=True, if_exists=True)
                )
                connection.execute(
                    DropSchema(VERSION_SCHEMA, cascade=True, if_exists=True)
                )
            engine.dispose()


def test_25_event_writer_s_persists_before_replay(event_runtime) -> None:
    factory, run_id = event_runtime
    writer = EventWriter(factory)
    written = writer.append(
        tenant_id=TENANT,
        run_id=run_id,
        event_type="run.queued",
        payload={"state": "queued"},
        audit_receipt_id="audit-harness-success",
    )
    replay = writer.replay_after(
        tenant_id=TENANT,
        run_id=run_id,
        last_event_id=0,
    )
    assert [(event.seq, event.event_id) for event in replay] == [(1, written.event_id)]


def test_25_event_writer_i_concurrent_writers_are_database_serialized(
    event_runtime,
) -> None:
    factory, run_id = event_runtime
    writer = EventWriter(factory)

    def append(index: int) -> int:
        return writer.append(
            tenant_id=TENANT,
            run_id=run_id,
            event_type="run.progress",
            payload={"index": index},
            audit_receipt_id=f"audit-harness-{index}",
        ).seq

    with ThreadPoolExecutor(max_workers=4) as executor:
        assigned = list(executor.map(append, range(4)))
    assert sorted(assigned) == [1, 2, 3, 4]
    with factory.begin() as session:
        persisted = session.scalars(
            select(EventRecord)
            .where(EventRecord.run_id == run_id)
            .order_by(EventRecord.seq)
        ).all()
    assert [event.seq for event in persisted] == [1, 2, 3, 4]


def test_25_event_writer_d_missing_audit_receipt_fails_closed(event_runtime) -> None:
    factory, run_id = event_runtime
    writer = EventWriter(factory)
    with pytest.raises(AuditReceiptRequired, match="audit.receipt_required"):
        writer.append(
            tenant_id=TENANT,
            run_id=run_id,
            event_type="run.progress",
            payload={},
            audit_receipt_id="",
        )
    with factory.begin() as session:
        assert session.scalar(select(func.count()).select_from(EventRecord)) == 0
        assert (
            session.scalar(
                select(RunRecord.next_event_seq).where(RunRecord.run_id == run_id)
            )
            == 1
        )


def test_25_event_writer_d_failed_write_rolls_back_sequence_reservation(
    event_runtime,
) -> None:
    factory, run_id = event_runtime
    notifications: list[int] = []
    writer = EventWriter(
        factory, after_commit=lambda event: notifications.append(event.seq)
    )
    heartbeat = writer.heartbeat()
    with pytest.raises(UnsafeEventPayload, match="event.unsafe_payload"):
        writer.append(
            tenant_id=TENANT,
            run_id=run_id,
            event_type="run.progress",
            payload={"prompt_text": "must not persist"},
            audit_receipt_id="audit-harness-failed",
        )
    assert heartbeat.seq is None and heartbeat.data == {}
    assert notifications == []
    recovered = writer.append(
        tenant_id=TENANT,
        run_id=run_id,
        event_type="run.progress",
        payload={"recovered": True},
        audit_receipt_id="audit-harness-recovered",
    )
    assert recovered.seq == 1
    assert notifications == [1]
    with factory.begin() as session:
        assert session.scalar(select(func.count()).select_from(EventRecord)) == 1
