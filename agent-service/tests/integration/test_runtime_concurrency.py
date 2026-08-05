from __future__ import annotations

import json
import os
import site
import sys
import threading
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
    EventRecord,
    RUNTIME_SCHEMA,
    RunRecord,
    RunState,
)
from app.persistence.repositories.events import (  # noqa: E402
    EventsRepository,
    RunTerminal,
)
from app.persistence.repositories.runs import (  # noqa: E402
    RunStateConflict,
    RunsRepository,
)


ALEMBIC_INI = SERVICE_ROOT / "alembic.ini"
TARGET_REVISION = "p03_007_runtime_rls"
VERSION_SCHEMA = "p03_008_concurrency_test"
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
TENANT = "tenant-p03-008-concurrency"
PRINCIPAL = "principal-p03-008-concurrency"
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
def concurrency_database():
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


def _create_run(factory: sessionmaker[Session], key: str) -> uuid.UUID:
    with factory.begin() as session:
        _set_tenant(session)
        thread = RunsRepository(session).create_thread(
            tenant_id=TENANT,
            owner_principal_id=PRINCIPAL,
        )
        run = RunsRepository(session).create_or_replay_run(
            tenant_id=TENANT,
            principal_id=PRINCIPAL,
            thread_id=thread.thread_id,
            request_scope="runtime.concurrency",
            idempotency_key=key,
            request_hash="4" * 64,
            manifest_digest="5" * 64,
            manifest={"behavior_release": "phase-03-concurrency-fixture"},
        )
        return run.run_id


def _transition_to_running(
    factory: sessionmaker[Session], run_id: uuid.UUID
) -> RunRecord:
    with factory.begin() as session:
        _set_tenant(session)
        return RunsRepository(session).transition_state(
            tenant_id=TENANT,
            run_id=run_id,
            expected_state=RunState.QUEUED,
            expected_version=1,
            target_state=RunState.RUNNING,
        )


def _write_report(value: dict[str, object]) -> None:
    requested = os.environ.get(REPORT_ENV, "").strip()
    if not requested:
        return
    directory = Path(requested).resolve()
    assert directory == EXPECTED_EVIDENCE_DIRECTORY.resolve()
    directory.mkdir(parents=True, exist_ok=True)
    (directory / "runtime-concurrency-report.json").write_text(
        json.dumps(value, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )


def test_terminal_cas_and_event_sequence_races_have_database_winners(
    concurrency_database,
) -> None:
    factory = concurrency_database
    terminal_run_id = _create_run(factory, "terminal-race")
    running = _transition_to_running(factory, terminal_run_id)
    barrier = threading.Barrier(2)

    def finish(target_state: RunState) -> tuple[str, str]:
        barrier.wait()
        try:
            with factory.begin() as session:
                _set_tenant(session)
                result = RunsRepository(session).transition_state(
                    tenant_id=TENANT,
                    run_id=terminal_run_id,
                    expected_state=RunState.RUNNING,
                    expected_version=running.version,
                    target_state=target_state,
                )
            return "won", result.state
        except RunStateConflict as error:
            return "conflict", str(error)

    with ThreadPoolExecutor(max_workers=2) as executor:
        terminal_results = list(
            executor.map(finish, (RunState.SUCCEEDED, RunState.FAILED))
        )
    assert sorted(result[0] for result in terminal_results) == ["conflict", "won"]
    with factory.begin() as session:
        _set_tenant(session)
        terminal_record = session.scalar(
            select(RunRecord).where(RunRecord.run_id == terminal_run_id)
        )
    assert terminal_record is not None
    assert RunState(terminal_record.state) in {RunState.SUCCEEDED, RunState.FAILED}
    assert terminal_record.version == 3

    event_run_id = _create_run(factory, "event-race")

    def append(index: int) -> int:
        with factory.begin() as session:
            _set_tenant(session)
            event = EventsRepository(session).append(
                tenant_id=TENANT,
                run_id=event_run_id,
                event_type="run.progress",
                payload={"index": index},
                audit_receipt_id=f"audit-p03-008-event-{index}",
            )
            return event.seq

    with ThreadPoolExecutor(max_workers=50) as executor:
        assigned_sequences = list(executor.map(append, range(50)))
    assert sorted(assigned_sequences) == list(range(1, 51))
    assert len(set(assigned_sequences)) == 50
    with factory.begin() as session:
        _set_tenant(session)
        events = session.scalars(
            select(EventRecord)
            .where(EventRecord.run_id == event_run_id)
            .order_by(EventRecord.seq)
        ).all()
    assert [event.seq for event in events] == list(range(1, 51))

    event_running = _transition_to_running(factory, event_run_id)
    with factory.begin() as session:
        _set_tenant(session)
        EventsRepository(session)
        terminal_event_run = RunsRepository(session).transition_state(
            tenant_id=TENANT,
            run_id=event_run_id,
            expected_state=RunState.RUNNING,
            expected_version=event_running.version,
            target_state=RunState.SUCCEEDED,
        )
    assert terminal_event_run.version == 3
    with pytest.raises(RunTerminal, match="run.terminal"):
        with factory.begin() as session:
            _set_tenant(session)
            EventsRepository(session).append(
                tenant_id=TENANT,
                run_id=event_run_id,
                event_type="run.illegal-after-terminal",
                payload={},
                audit_receipt_id="audit-p03-008-terminal-rejection",
            )
    with factory.begin() as session:
        _set_tenant(session)
        persisted_event_count = session.scalar(
            select(func.count())
            .select_from(EventRecord)
            .where(EventRecord.run_id == event_run_id)
        )
        next_event_seq = session.scalar(
            select(RunRecord.next_event_seq).where(RunRecord.run_id == event_run_id)
        )
    assert persisted_event_count == 50
    assert next_event_seq == 51
    _write_report(
        {
            "schema_version": "1.0",
            "task_id": "TASK-P03-008",
            "revision": TARGET_REVISION,
            "terminal_race_callers": 2,
            "terminal_winner_count": sum(
                result[0] == "won" for result in terminal_results
            ),
            "terminal_conflict_count": sum(
                result[0] == "conflict" for result in terminal_results
            ),
            "terminal_version": terminal_record.version,
            "event_race_callers": 50,
            "event_sequence_min": min(assigned_sequences),
            "event_sequence_max": max(assigned_sequences),
            "event_sequence_unique_count": len(set(assigned_sequences)),
            "event_sequence_gap_count": 0,
            "persisted_event_count": persisted_event_count,
            "next_event_seq": next_event_seq,
            "post_terminal_event_rejection_count": 1,
            "exactly_one_legal_winner": True,
            "production": False,
        }
    )
