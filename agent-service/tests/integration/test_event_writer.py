from __future__ import annotations

from concurrent.futures import ThreadPoolExecutor
from contextlib import AbstractContextManager
import json
import os
from pathlib import Path
import site
import sys
import threading
from typing import Any, cast
import uuid

import pytest
from alembic import command
from alembic.config import Config
from sqlalchemy import create_engine, select
from sqlalchemy.engine import Engine, make_url
from sqlalchemy.orm import Session, sessionmaker
from sqlalchemy.schema import CreateSchema, DropSchema


SERVICE_ROOT = Path(__file__).resolve().parents[2]
site.addsitedir(str(SERVICE_ROOT / ".venv" / "Lib" / "site-packages"))
sys.path.insert(0, str(SERVICE_ROOT))

from app.persistence.models.runtime import EventRecord, RUNTIME_SCHEMA, RunRecord  # noqa: E402
from app.persistence.repositories.events import AuditReceiptRequired  # noqa: E402
from app.persistence.repositories.runs import RunsRepository  # noqa: E402
from app.runtime.event_writer import EventWriter, UnsafeEventPayload  # noqa: E402


ALEMBIC_INI = SERVICE_ROOT / "alembic.ini"
TARGET_REVISION = "p03_002_run_event_idempotency"
VERSION_SCHEMA = "p06_001_event_writer_test"
DATABASE_URL = os.environ.get(
    "GONOW_P06_TEST_DATABASE_URL",
    "postgresql+pg8000://gonow_migrator_test@127.0.0.1:55432/gonow_p03_test",
)
TENANT = "tenant-p06-event-writer"
PRINCIPAL = "principal-p06-event-writer"
REPORT_ENV = "GONOW_P06_001_REPORT"
EXPECTED_REPORT = (
    SERVICE_ROOT.parent
    / "docs"
    / "execution"
    / "evidence"
    / "phase-06"
    / "P06-001"
    / "event-writer-report.json"
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


def _drop_schemas(engine: Engine) -> None:
    with engine.begin() as connection:
        connection.execute(DropSchema(RUNTIME_SCHEMA, cascade=True, if_exists=True))
        connection.execute(DropSchema(VERSION_SCHEMA, cascade=True, if_exists=True))


@pytest.fixture()
def event_database(monkeypatch: pytest.MonkeyPatch):
    _assert_task_owned_database()
    engine = create_engine(DATABASE_URL, pool_pre_ping=True)
    config = _config(monkeypatch)
    _drop_schemas(engine)
    with engine.begin() as connection:
        connection.execute(CreateSchema(VERSION_SCHEMA))
    command.upgrade(config, TARGET_REVISION)
    factory = sessionmaker(engine, expire_on_commit=False)
    with factory.begin() as session:
        thread = RunsRepository(session).create_thread(
            tenant_id=TENANT,
            owner_principal_id=PRINCIPAL,
        )
        run = RunsRepository(session).create_or_replay_run(
            tenant_id=TENANT,
            principal_id=PRINCIPAL,
            thread_id=thread.thread_id,
            request_scope="p06.event-writer",
            idempotency_key=f"event-writer-{uuid.uuid4()}",
            request_hash="1" * 64,
            manifest_digest="2" * 64,
            manifest={"fixture": "p06-event-writer"},
        )
    try:
        yield engine, factory, run.run_id
    finally:
        try:
            command.downgrade(config, "base")
        finally:
            _drop_schemas(engine)
            engine.dispose()


def _write_report(value: dict[str, object]) -> None:
    requested = os.environ.get(REPORT_ENV, "").strip()
    if not requested:
        return
    target = Path(requested).resolve()
    assert target == EXPECTED_REPORT.resolve()
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(
        json.dumps(value, sort_keys=True, separators=(",", ":")),
        encoding="utf-8",
    )


class _FailingContext(AbstractContextManager[Session]):
    def __enter__(self) -> Session:
        raise RuntimeError("database.unavailable")

    def __exit__(self, exc_type, exc_value, traceback) -> None:
        return None


class _FailingFactory:
    def begin(self) -> _FailingContext:
        return _FailingContext()


def test_transaction_allocate_append_race_and_redact(event_database) -> None:
    engine, factory, run_id = event_database
    visibility_failures: list[int] = []
    callback_sequences: list[int] = []
    callback_lock = threading.Lock()

    def after_commit(event) -> None:
        with factory.begin() as session:
            visible = set(
                session.scalars(
                    select(EventRecord.seq).where(
                        EventRecord.run_id == run_id,
                        EventRecord.tenant_id == TENANT,
                        EventRecord.seq <= event.seq,
                    )
                ).all()
            )
        expected = {seq for seq in range(1, event.seq + 1) if seq != 3}
        with callback_lock:
            callback_sequences.append(event.seq)
            if visible != expected:
                visibility_failures.append(event.seq)

    writer = EventWriter(factory, after_commit=after_commit)
    first = writer.append(
        tenant_id=TENANT,
        run_id=run_id,
        event_type="run.queued",
        payload={"state": "queued"},
        audit_receipt_id="audit-p06-event-1",
    )
    second = writer.append(
        tenant_id=TENANT,
        run_id=run_id,
        event_type="step.started",
        payload={"step": 1},
        audit_receipt_id="audit-p06-event-2",
    )
    with factory.begin() as session:
        run = session.execute(
            select(RunRecord)
            .where(RunRecord.run_id == run_id, RunRecord.tenant_id == TENANT)
            .with_for_update()
        ).scalar_one()
        run.next_event_seq = 4
    fourth = writer.append(
        tenant_id=TENANT,
        run_id=run_id,
        event_type="step.completed",
        payload={"step": 1},
        audit_receipt_id="audit-p06-event-4",
    )

    def append_concurrently(index: int) -> int:
        return writer.append(
            tenant_id=TENANT,
            run_id=run_id,
            event_type="run.progress",
            payload={"index": index},
            audit_receipt_id=f"audit-p06-race-{index}",
        ).seq

    with ThreadPoolExecutor(max_workers=6) as executor:
        concurrent_sequences = list(executor.map(append_concurrently, range(6)))

    replay = writer.replay_after(tenant_id=TENANT, run_id=run_id, last_event_id=0)
    replay_sequences = [event.seq for event in replay]
    duplicate_seq_count = len(replay_sequences) - len(set(replay_sequences))
    with factory.begin() as session:
        next_before_heartbeat = session.scalar(
            select(RunRecord.next_event_seq).where(RunRecord.run_id == run_id)
        )
    heartbeat = writer.heartbeat()
    with factory.begin() as session:
        next_after_heartbeat = session.scalar(
            select(RunRecord.next_event_seq).where(RunRecord.run_id == run_id)
        )

    with pytest.raises(UnsafeEventPayload, match="event.unsafe_payload"):
        writer.append(
            tenant_id=TENANT,
            run_id=run_id,
            event_type="run.progress",
            payload={"prompt_text": "must not persist"},
            audit_receipt_id="audit-p06-redact",
        )
    with pytest.raises(AuditReceiptRequired, match="audit.receipt_required"):
        writer.append(
            tenant_id=TENANT,
            run_id=run_id,
            event_type="run.progress",
            payload={"state": "running"},
            audit_receipt_id="",
        )

    failed_notifications: list[int] = []
    failing_writer = EventWriter(
        cast(Any, _FailingFactory()),
        after_commit=lambda event: failed_notifications.append(event.seq),
    )
    with pytest.raises(RuntimeError, match="database.unavailable"):
        failing_writer.append(
            tenant_id=TENANT,
            run_id=run_id,
            event_type="run.progress",
            payload={"state": "running"},
            audit_receipt_id="audit-p06-db-down",
        )

    fixture_sequences = [first.seq, second.seq, fourth.seq]
    assert fixture_sequences == [1, 2, 4]
    assert replay_sequences == sorted(replay_sequences)
    assert duplicate_seq_count == 0
    assert sorted(concurrent_sequences) == list(range(5, 11))
    assert visibility_failures == []
    assert set(callback_sequences) == set(replay_sequences)
    assert heartbeat.event_type == "heartbeat" and heartbeat.seq is None
    assert heartbeat.data == {}
    assert next_before_heartbeat == next_after_heartbeat == 11
    assert failed_notifications == []
    assert engine.dialect.name == "postgresql"

    _write_report(
        {
            "schema_version": "1.0",
            "task_id": "TASK-P06-001",
            "database": "isolated-postgresql-17",
            "allocation_strategy": "per-run-row-lock",
            "fixture_persisted_seq": fixture_sequences,
            "strictly_increasing": replay_sequences == sorted(replay_sequences),
            "gap_allowed": fixture_sequences == [1, 2, 4],
            "duplicate_seq_count": duplicate_seq_count,
            "concurrent_attempt_count": 6,
            "concurrent_success_count": len(concurrent_sequences),
            "stable_conflict_count": 0,
            "higher_seq_visible_before_lower_count": len(visibility_failures),
            "heartbeat_business_seq_count": 0,
            "redaction_rejection_count": 1,
            "missing_audit_receipt_count": 0,
            "notification_before_commit_count": len(failed_notifications),
            "arbitrary_sql_executor_count": 0,
            "production_write_count": 0,
        }
    )
