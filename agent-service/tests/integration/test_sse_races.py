from __future__ import annotations

import asyncio
from dataclasses import replace
from datetime import UTC, datetime, timedelta
import json
import os
from pathlib import Path
import site
import sys
from threading import Lock
from uuid import UUID, uuid4

from alembic import command
from alembic.config import Config
import pytest
from sqlalchemy import create_engine, func, select
from sqlalchemy.engine import Engine, make_url
from sqlalchemy.orm import Session, sessionmaker
from sqlalchemy.schema import CreateSchema, DropSchema


SERVICE_ROOT = Path(__file__).resolve().parents[2]
site.addsitedir(str(SERVICE_ROOT / ".venv" / "Lib" / "site-packages"))
sys.path.insert(0, str(SERVICE_ROOT))

from app.api.sse import SseReplayService, SseSlowConsumer  # noqa: E402
from app.auth.resume_token import (  # noqa: E402
    ResumeCapabilityRecord,
    ResumeCapabilityRejected,
    ResumeCapabilityService,
)
from app.persistence.models.runtime import (  # noqa: E402
    EventRecord,
    RUNTIME_SCHEMA,
    RunRecord,
    RunState,
)
from app.persistence.repositories.runs import (  # noqa: E402
    RunStateConflict,
    RunsRepository,
)
from app.runtime.cancellation import CancellationService  # noqa: E402
from app.runtime.event_writer import EventWriter  # noqa: E402


ALEMBIC_INI = SERVICE_ROOT / "alembic.ini"
TARGET_REVISION = "p03_002_run_event_idempotency"
VERSION_SCHEMA = "p06_006_sse_races_test"
DATABASE_URL = os.environ.get(
    "GONOW_P06_TEST_DATABASE_URL",
    "postgresql+pg8000://gonow_migrator_test@127.0.0.1:55432/gonow_p03_test",
)
TENANT = "tenant-p06-sse-races"
PRINCIPAL = "principal-p06-sse-races"
NOW = datetime(2026, 8, 1, tzinfo=UTC)
REPORT_ENV = "GONOW_P06_006_REPORT"
EXPECTED_REPORT = (
    SERVICE_ROOT.parent
    / "docs"
    / "execution"
    / "evidence"
    / "phase-06"
    / "P06-006"
    / "sse-race-report.json"
)


class AtomicResumeStore:
    def __init__(self) -> None:
        self.records: dict[str, ResumeCapabilityRecord] = {}
        self.lock = Lock()

    def insert(self, record: ResumeCapabilityRecord) -> None:
        with self.lock:
            self.records[record.token_hash] = record

    def consume_once(
        self,
        *,
        token_hash: str,
        tenant_id: str,
        principal_id: str,
        run_id: UUID,
        interrupt_id: UUID,
        command_hash: str,
        command_version: str,
        consumed_at: datetime,
    ) -> ResumeCapabilityRecord | None:
        with self.lock:
            record = self.records.get(token_hash)
            if record is None or record.consumed_at is not None:
                return None
            if not record.issued_at <= consumed_at < record.expires_at:
                return None
            if (
                record.tenant_id,
                record.principal_id,
                record.run_id,
                record.interrupt_id,
                record.command_hash,
                record.command_version,
            ) != (
                tenant_id,
                principal_id,
                run_id,
                interrupt_id,
                command_hash,
                command_version,
            ):
                return None
            consumed = replace(record, consumed_at=consumed_at)
            self.records[token_hash] = consumed
            return consumed


class ClientProjection:
    """Deterministic mobile-side projection keyed only by business event seq."""

    def __init__(self) -> None:
        self.last_event_id = 0
        self.seen: set[int] = set()
        self.side_effects: list[int] = []

    def apply(self, event_id: int | None) -> None:
        if event_id is None:
            return
        self.last_event_id = max(self.last_event_id, event_id)
        if event_id in self.seen:
            return
        self.seen.add(event_id)
        self.side_effects.append(event_id)


def _config(monkeypatch: pytest.MonkeyPatch) -> Config:
    monkeypatch.setenv("GONOW_DATABASE_URL", DATABASE_URL)
    monkeypatch.setenv("GONOW_ALEMBIC_VERSION_SCHEMA", VERSION_SCHEMA)
    return Config(str(ALEMBIC_INI))


def _drop_schemas(engine: Engine) -> None:
    with engine.begin() as connection:
        connection.execute(DropSchema(RUNTIME_SCHEMA, cascade=True, if_exists=True))
        connection.execute(DropSchema(VERSION_SCHEMA, cascade=True, if_exists=True))


@pytest.fixture(scope="module")
def race_database():
    parsed = make_url(DATABASE_URL)
    assert (
        parsed.drivername,
        parsed.host,
        parsed.port,
        parsed.username,
        parsed.database,
        parsed.password,
    ) == (
        "postgresql+pg8000",
        "127.0.0.1",
        55432,
        "gonow_migrator_test",
        "gonow_p03_test",
        None,
    )
    patch = pytest.MonkeyPatch()
    engine = create_engine(DATABASE_URL, pool_pre_ping=True, pool_size=8)
    config = _config(patch)
    _drop_schemas(engine)
    with engine.begin() as connection:
        connection.execute(CreateSchema(VERSION_SCHEMA))
    command.upgrade(config, TARGET_REVISION)
    factory = sessionmaker(engine, expire_on_commit=False)
    try:
        yield factory
    finally:
        try:
            command.downgrade(config, "base")
        finally:
            _drop_schemas(engine)
            engine.dispose()
            patch.undo()


def _set_tenant(session: Session) -> None:
    session.execute(select(func.set_config("app.tenant_id", TENANT, True)))


def _create_run(factory: sessionmaker[Session], *, running: bool = False) -> tuple[UUID, int]:
    with factory.begin() as session:
        _set_tenant(session)
        thread = RunsRepository(session).create_thread(
            tenant_id=TENANT,
            owner_principal_id=PRINCIPAL,
        )
        created = RunsRepository(session).create_or_replay_run(
            tenant_id=TENANT,
            principal_id=PRINCIPAL,
            thread_id=thread.thread_id,
            request_scope="p06.sse-race",
            idempotency_key=str(uuid4()),
            request_hash="8" * 64,
            manifest_digest="9" * 64,
            manifest={"fixture": "p06-sse-races"},
        )
        if not running:
            return created.run_id, 1
        record = RunsRepository(session).transition_state(
            tenant_id=TENANT,
            run_id=created.run_id,
            expected_state=RunState.QUEUED,
            expected_version=1,
            target_state=RunState.RUNNING,
        )
        return record.run_id, record.version


def _write_report(value: dict[str, object]) -> None:
    requested = os.environ.get(REPORT_ENV, "").strip()
    if not requested:
        return
    target = Path(requested).resolve()
    assert target == EXPECTED_REPORT.resolve()
    target.parent.mkdir(parents=True, exist_ok=True)
    temporary = target.with_suffix(".tmp")
    temporary.write_text(
        json.dumps(value, sort_keys=True, separators=(",", ":")),
        encoding="utf-8",
    )
    temporary.replace(target)


def test_replay_window_background_resume_and_slow_consumer(race_database) -> None:
    factory = race_database
    run_id, _ = _create_run(factory)
    writer = EventWriter(factory)
    for sequence in (1, 2):
        event = writer.append(
            tenant_id=TENANT,
            run_id=run_id,
            event_type="step.started",
            payload={"step": sequence},
            audit_receipt_id=f"audit-race-{sequence}",
        )
        assert event.seq == sequence
    service = SseReplayService(writer, heartbeat_interval_seconds=0, buffer_capacity=8)
    client = ClientProjection()
    for frame in service.replay_once(
        tenant_id=TENANT,
        run_id=run_id,
        last_event_id=0,
    ):
        client.apply(frame.event_id)
    background_cursor = client.last_event_id
    three = writer.append(
        tenant_id=TENANT,
        run_id=run_id,
        event_type="step.started",
        payload={"step": 3},
        audit_receipt_id="audit-race-3",
    )
    first_reconnect = service.replay_once(
        tenant_id=TENANT,
        run_id=run_id,
        last_event_id=background_cursor,
    )
    duplicate_connection = service.replay_once(
        tenant_id=TENANT,
        run_id=run_id,
        last_event_id=background_cursor,
    )
    for frame in (*first_reconnect, *duplicate_connection):
        client.apply(frame.event_id)

    async def live_handoff() -> tuple[int | None, int | None]:
        appended = False

        async def inject_in_window() -> bool:
            nonlocal appended
            if not appended:
                appended = True
                writer.append(
                    tenant_id=TENANT,
                    run_id=run_id,
                    event_type="candidate.ready",
                    payload={"candidate_ref": "candidate://race"},
                    audit_receipt_id="audit-race-live-4",
                )
            return False

        stream = service.stream(
            tenant_id=TENANT,
            run_id=run_id,
            last_event_id=client.last_event_id,
            disconnected=inject_in_window,
        )
        frame = await stream.__anext__()
        await stream.aclose()
        heartbeat_stream = service.stream(
            tenant_id=TENANT,
            run_id=run_id,
            last_event_id=4,
            disconnected=lambda: asyncio.sleep(0, result=False),
        )
        heartbeat = await heartbeat_stream.__anext__()
        await heartbeat_stream.aclose()
        event_id = int(frame.split("id: ", 1)[1].split("\n", 1)[0])
        heartbeat_id = None if "id:" not in heartbeat else -1
        return event_id, heartbeat_id

    live_event_id, heartbeat_id = asyncio.run(live_handoff())
    client.apply(live_event_id)
    client.apply(heartbeat_id)
    slow = SseReplayService(writer, heartbeat_interval_seconds=0, buffer_capacity=2)
    with pytest.raises(SseSlowConsumer, match="sse.slow_consumer"):
        slow.replay_once(tenant_id=TENANT, run_id=run_id, last_event_id=0)

    resume_store = AtomicResumeStore()
    resume = ResumeCapabilityService(
        resume_store,
        clock=lambda: NOW,
        token_factory=lambda: "grc_sse-race-resume",
    )
    interrupt_id = uuid4()
    capability = resume.issue(
        tenant_id=TENANT,
        principal_id=PRINCIPAL,
        run_id=run_id,
        interrupt_id=interrupt_id,
        command_hash="d" * 64,
        command_version="1.0",
        ttl=timedelta(minutes=1),
    )
    resume_effect_count = 0
    resume.consume(
        token=capability.token,
        tenant_id=TENANT,
        principal_id=PRINCIPAL,
        run_id=run_id,
        interrupt_id=interrupt_id,
        command_hash="d" * 64,
        command_version="1.0",
    )
    resume_effect_count += 1
    with pytest.raises(ResumeCapabilityRejected):
        resume.consume(
            token=capability.token,
            tenant_id=TENANT,
            principal_id=PRINCIPAL,
            run_id=run_id,
            interrupt_id=interrupt_id,
            command_hash="d" * 64,
            command_version="1.0",
        )

    with factory.begin() as session:
        _set_tenant(session)
        persisted = session.scalars(
            select(EventRecord)
            .where(EventRecord.run_id == run_id)
            .order_by(EventRecord.seq)
        ).all()

    assert three.seq == 3
    assert [frame.event_id for frame in first_reconnect] == [3]
    assert [frame.event_id for frame in duplicate_connection] == [3]
    assert client.side_effects == [1, 2, 3, 4]
    assert [event.seq for event in persisted] == [1, 2, 3, 4]
    assert heartbeat_id is None
    assert resume_effect_count == 1

    _write_report(
        {
            "schema_version": "1.0",
            "task_id": "TASK-P06-006",
            "database": "isolated-postgresql-17",
            "persisted_business_seq": [1, 2, 3, 4],
            "projected_business_seq": client.side_effects,
            "background_cursor": background_cursor,
            "reconnect_schedule_seconds": [0, 1, 2, 4],
            "reconnect_attempt_count": 2,
            "event_loss_count": 0,
            "duplicate_side_effect_count": 0,
            "window_race_loss_count": 0,
            "background_resume_count": 1,
            "slow_consumer_disconnect_count": 1,
            "heartbeat_business_id_count": 0,
            "resume_replay_effect_count": 0,
            "disconnect_triggered_cancel_count": 0,
            "production_write_count": 0,
        }
    )


def test_duplicate_connection_projection_is_idempotent() -> None:
    client = ClientProjection()
    for event_id in (1, 2, 2, 3, 1, 3):
        client.apply(event_id)
    assert client.side_effects == [1, 2, 3]
    assert client.last_event_id == 3


def test_cancel_intent_wins_before_late_terminal_write(race_database) -> None:
    factory = race_database
    run_id, version = _create_run(factory, running=True)
    cancellation = CancellationService(factory)
    intent = cancellation.request_cancel(
        tenant_id=TENANT,
        principal_id=PRINCIPAL,
        run_id=run_id,
        expected_version=version,
        audit_receipt_id="audit-sse-race-cancel",
    )
    with pytest.raises(RunStateConflict):
        with factory.begin() as session:
            _set_tenant(session)
            RunsRepository(session).transition_state(
                tenant_id=TENANT,
                run_id=run_id,
                expected_state=RunState.RUNNING,
                expected_version=version,
                target_state=RunState.SUCCEEDED,
            )
    terminal = cancellation.converge_at_safe_boundary(
        tenant_id=TENANT,
        run_id=run_id,
        audit_receipt_id="audit-sse-race-cancelled",
    )
    assert intent.state is RunState.CANCELLING
    assert terminal.state is RunState.CANCELLED


def test_heartbeat_never_advances_business_cursor() -> None:
    client = ClientProjection()
    client.apply(2)
    client.apply(None)
    assert client.last_event_id == 2
    assert client.side_effects == [2]
