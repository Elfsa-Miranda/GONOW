from __future__ import annotations

import asyncio
import json
import os
from pathlib import Path
import site
import sys
import uuid

import pytest
from alembic import command
from alembic.config import Config
from sqlalchemy import create_engine, func, select
from sqlalchemy.engine import Engine, make_url
from sqlalchemy.orm import sessionmaker
from sqlalchemy.schema import CreateSchema, DropSchema


SERVICE_ROOT = Path(__file__).resolve().parents[2]
site.addsitedir(str(SERVICE_ROOT / ".venv" / "Lib" / "site-packages"))
sys.path.insert(0, str(SERVICE_ROOT))

from app.api.routes.events import create_events_router  # noqa: E402
from app.api.sse import (  # noqa: E402
    LastEventIdInvalid,
    SseReplayService,
    SseSlowConsumer,
    heartbeat_frame,
    parse_last_event_id,
)
from app.auth.context import RequestContext  # noqa: E402
from app.persistence.models.runtime import EventRecord, RUNTIME_SCHEMA, RunRecord  # noqa: E402
from app.persistence.repositories.runs import RunsRepository  # noqa: E402
from app.runtime.event_writer import EventWriter  # noqa: E402


ALEMBIC_INI = SERVICE_ROOT / "alembic.ini"
TARGET_REVISION = "p03_002_run_event_idempotency"
VERSION_SCHEMA = "p06_002_sse_replay_test"
DATABASE_URL = os.environ.get(
    "GONOW_P06_TEST_DATABASE_URL",
    "postgresql+pg8000://gonow_migrator_test@127.0.0.1:55432/gonow_p03_test",
)
TENANT = "tenant-p06-sse"
PRINCIPAL = "principal-p06-sse"
REPORT_ENV = "GONOW_P06_002_REPORT"
EXPECTED_REPORT = (
    SERVICE_ROOT.parent
    / "docs"
    / "execution"
    / "evidence"
    / "phase-06"
    / "P06-002"
    / "sse-replay-report.json"
)


def _config(monkeypatch: pytest.MonkeyPatch) -> Config:
    monkeypatch.setenv("GONOW_DATABASE_URL", DATABASE_URL)
    monkeypatch.setenv("GONOW_ALEMBIC_VERSION_SCHEMA", VERSION_SCHEMA)
    return Config(str(ALEMBIC_INI))


def _drop_schemas(engine: Engine) -> None:
    with engine.begin() as connection:
        connection.execute(DropSchema(RUNTIME_SCHEMA, cascade=True, if_exists=True))
        connection.execute(DropSchema(VERSION_SCHEMA, cascade=True, if_exists=True))


@pytest.fixture()
def sse_database(monkeypatch: pytest.MonkeyPatch):
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
            request_scope="p06.sse",
            idempotency_key=f"sse-{uuid.uuid4()}",
            request_hash="3" * 64,
            manifest_digest="4" * 64,
            manifest={"fixture": "p06-sse"},
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


def test_replay_live_handoff_heartbeat_and_backpressure(sse_database) -> None:
    _, factory, run_id = sse_database
    writer = EventWriter(factory)
    one = writer.append(
        tenant_id=TENANT,
        run_id=run_id,
        event_type="run.queued",
        payload={"state": "queued"},
        audit_receipt_id="audit-sse-1",
    )
    two = writer.append(
        tenant_id=TENANT,
        run_id=run_id,
        event_type="step.started",
        payload={"step": 1},
        audit_receipt_id="audit-sse-2",
    )
    with factory.begin() as session:
        run = session.execute(
            select(RunRecord)
            .where(RunRecord.run_id == run_id, RunRecord.tenant_id == TENANT)
            .with_for_update()
        ).scalar_one()
        run.next_event_seq = 4
    four = writer.append(
        tenant_id=TENANT,
        run_id=run_id,
        event_type="step.completed",
        payload={"step": 1},
        audit_receipt_id="audit-sse-4",
    )
    service = SseReplayService(writer, heartbeat_interval_seconds=0, buffer_capacity=8)
    replay = service.replay_once(
        tenant_id=TENANT,
        run_id=run_id,
        last_event_id=parse_last_event_id("2"),
    )
    duplicate_replay = service.replay_once(
        tenant_id=TENANT,
        run_id=run_id,
        last_event_id=parse_last_event_id("2"),
    )
    with factory.begin() as session:
        count_after_reconnect = session.scalar(
            select(func.count()).select_from(EventRecord)
        )

    backpressure = SseReplayService(
        writer, heartbeat_interval_seconds=0, buffer_capacity=2
    )
    with pytest.raises(SseSlowConsumer, match="sse.slow_consumer"):
        backpressure.replay_once(tenant_id=TENANT, run_id=run_id, last_event_id=0)
    with pytest.raises(LastEventIdInvalid, match="sse.last_event_id_invalid"):
        parse_last_event_id("2-from-another-run")

    async def exercise_live_handoff() -> tuple[str, str]:
        appended = False

        async def append_between_replay_and_poll() -> bool:
            nonlocal appended
            if not appended:
                appended = True
                writer.append(
                    tenant_id=TENANT,
                    run_id=run_id,
                    event_type="candidate.ready",
                    payload={"candidate_ref": "candidate://fixture"},
                    audit_receipt_id="audit-sse-live-5",
                )
            return False

        live_stream = service.stream(
            tenant_id=TENANT,
            run_id=run_id,
            last_event_id=4,
            disconnected=append_between_replay_and_poll,
        )
        live_frame = await live_stream.__anext__()
        await live_stream.aclose()

        async def connected_once() -> bool:
            return False

        heartbeat_stream = service.stream(
            tenant_id=TENANT,
            run_id=run_id,
            last_event_id=5,
            disconnected=connected_once,
        )
        transient = await heartbeat_stream.__anext__()
        await heartbeat_stream.aclose()
        return live_frame, transient

    live_frame, transient_heartbeat = asyncio.run(exercise_live_handoff())
    context = RequestContext(
        principal_id=PRINCIPAL,
        tenant_id=TENANT,
        permissions=("run.events.read",),
        locale="en",
        timezone="UTC",
        trace_id="trace-p06-sse",
    )
    router = create_events_router(writer, lambda request: context)
    route_paths = {route.path for route in router.routes}
    with factory.begin() as session:
        missing_audit_receipt_count = session.scalar(
            select(func.count())
            .select_from(EventRecord)
            .where(EventRecord.audit_receipt_id == "")
        )

    assert [one.seq, two.seq, four.seq] == [1, 2, 4]
    assert [frame.event_id for frame in replay] == [4]
    assert [frame.encode() for frame in duplicate_replay] == [
        frame.encode() for frame in replay
    ]
    assert count_after_reconnect == 3
    assert "event: candidate_ready\nid: 5\n" in live_frame
    assert transient_heartbeat == heartbeat_frame().encode()
    assert "id:" not in transient_heartbeat
    assert "/v1/runs/{run_id}/events" in route_paths
    assert missing_audit_receipt_count == 0

    _write_report(
        {
            "schema_version": "1.0",
            "task_id": "TASK-P06-002",
            "database": "isolated-postgresql-17",
            "fixture_persisted_seq": [one.seq, two.seq, four.seq],
            "last_event_id": 2,
            "replayed_seq": [frame.event_id for frame in replay],
            "gap_not_loss": True,
            "disconnect_side_effect_repeat_count": 0,
            "live_handoff_seq": 5,
            "heartbeat_business_id_count": 0,
            "slow_consumer_disconnect_count": 1,
            "buffer_capacity": 2,
            "missing_audit_receipt_count": missing_audit_receipt_count,
            "model_call_count": 0,
            "production_write_count": 0,
        }
    )
