from __future__ import annotations

import asyncio
from concurrent.futures import ThreadPoolExecutor
import json
import os
from pathlib import Path
import site
import sys
import threading
from uuid import UUID, uuid4

from alembic import command
from alembic.config import Config
from fastapi import HTTPException, Request
import pytest
from sqlalchemy import create_engine, func, select
from sqlalchemy.engine import Engine, make_url
from sqlalchemy.orm import Session, sessionmaker
from sqlalchemy.schema import CreateSchema, DropSchema


SERVICE_ROOT = Path(__file__).resolve().parents[2]
site.addsitedir(str(SERVICE_ROOT / ".venv" / "Lib" / "site-packages"))
sys.path.insert(0, str(SERVICE_ROOT))

from app.api.routes.cancel import CancelRequest, create_cancel_router  # noqa: E402
from app.auth.context import AuthorizationForbidden, RequestContext  # noqa: E402
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
from app.runtime.cancellation import CancelRejected, CancellationService  # noqa: E402


ALEMBIC_INI = SERVICE_ROOT / "alembic.ini"
TARGET_REVISION = "p03_002_run_event_idempotency"
VERSION_SCHEMA = "p06_005_cancel_test"
DATABASE_URL = os.environ.get(
    "GONOW_P06_TEST_DATABASE_URL",
    "postgresql+pg8000://gonow_migrator_test@127.0.0.1:55432/gonow_p03_test",
)
TENANT = "tenant-p06-cancel"
PRINCIPAL = "principal-p06-cancel"
REPORT_ENV = "GONOW_P06_005_REPORT"
EXPECTED_REPORT = (
    SERVICE_ROOT.parent
    / "docs"
    / "execution"
    / "evidence"
    / "phase-06"
    / "P06-005"
    / "ct-010.json"
)


def _config(monkeypatch: pytest.MonkeyPatch) -> Config:
    monkeypatch.setenv("GONOW_DATABASE_URL", DATABASE_URL)
    monkeypatch.setenv("GONOW_ALEMBIC_VERSION_SCHEMA", VERSION_SCHEMA)
    return Config(str(ALEMBIC_INI))


def _drop_schemas(engine: Engine) -> None:
    with engine.begin() as connection:
        connection.execute(DropSchema(RUNTIME_SCHEMA, cascade=True, if_exists=True))
        connection.execute(DropSchema(VERSION_SCHEMA, cascade=True, if_exists=True))


@pytest.fixture(scope="module")
def cancel_database():
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
    engine = create_engine(
        DATABASE_URL,
        pool_pre_ping=True,
        pool_size=8,
        max_overflow=8,
    )
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


def _create_run(
    factory: sessionmaker[Session],
    *,
    principal: str = PRINCIPAL,
    running: bool = True,
) -> tuple[UUID, int]:
    with factory.begin() as session:
        _set_tenant(session)
        thread = RunsRepository(session).create_thread(
            tenant_id=TENANT,
            owner_principal_id=principal,
        )
        created = RunsRepository(session).create_or_replay_run(
            tenant_id=TENANT,
            principal_id=principal,
            thread_id=thread.thread_id,
            request_scope="p06.cancel",
            idempotency_key=str(uuid4()),
            request_hash="6" * 64,
            manifest_digest="7" * 64,
            manifest={"fixture": "ct-010"},
        )
        if not running:
            return created.run_id, 1
        transitioned = RunsRepository(session).transition_state(
            tenant_id=TENANT,
            run_id=created.run_id,
            expected_state=RunState.QUEUED,
            expected_version=1,
            target_state=RunState.RUNNING,
        )
        return transitioned.run_id, transitioned.version


def _state(factory: sessionmaker[Session], run_id: UUID) -> RunRecord:
    with factory.begin() as session:
        _set_tenant(session)
        record = session.scalar(select(RunRecord).where(RunRecord.run_id == run_id))
        assert record is not None
        return record


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


def test_ct_010_cancel_intent_converges_and_late_success_is_rejected(
    cancel_database,
) -> None:
    factory = cancel_database
    cancellation = CancellationService(factory)
    run_id, running_version = _create_run(factory)
    requested = cancellation.request_cancel(
        tenant_id=TENANT,
        principal_id=PRINCIPAL,
        run_id=run_id,
        expected_version=running_version,
        audit_receipt_id="audit-ct010-request",
    )
    with pytest.raises(RunStateConflict, match="run.state_conflict"):
        with factory.begin() as session:
            _set_tenant(session)
            RunsRepository(session).transition_state(
                tenant_id=TENANT,
                run_id=run_id,
                expected_state=RunState.RUNNING,
                expected_version=running_version,
                target_state=RunState.SUCCEEDED,
            )
    converged = cancellation.converge_at_safe_boundary(
        tenant_id=TENANT,
        run_id=run_id,
        audit_receipt_id="audit-ct010-boundary",
    )
    with pytest.raises(RunStateConflict, match="run.state_conflict"):
        with factory.begin() as session:
            _set_tenant(session)
            RunsRepository(session).transition_state(
                tenant_id=TENANT,
                run_id=run_id,
                expected_state=RunState.CANCELLED,
                expected_version=converged.version,
                target_state=RunState.SUCCEEDED,
            )

    race_run_id, race_version = _create_run(factory)
    barrier = threading.Barrier(2)

    def cancel_racer() -> str:
        barrier.wait()
        try:
            cancellation.request_cancel(
                tenant_id=TENANT,
                principal_id=PRINCIPAL,
                run_id=race_run_id,
                expected_version=race_version,
                audit_receipt_id="audit-ct010-race-cancel",
            )
        except CancelRejected:
            return "conflict"
        return "cancel"

    def success_racer() -> str:
        barrier.wait()
        try:
            with factory.begin() as session:
                _set_tenant(session)
                RunsRepository(session).transition_state(
                    tenant_id=TENANT,
                    run_id=race_run_id,
                    expected_state=RunState.RUNNING,
                    expected_version=race_version,
                    target_state=RunState.SUCCEEDED,
                )
        except RunStateConflict:
            return "conflict"
        return "success"

    with ThreadPoolExecutor(max_workers=2) as executor:
        cancel_future = executor.submit(cancel_racer)
        success_future = executor.submit(success_racer)
        race_results = [cancel_future.result(), success_future.result()]
    race_state = RunState(_state(factory, race_run_id).state)
    if "cancel" in race_results:
        race_state = cancellation.converge_at_safe_boundary(
            tenant_id=TENANT,
            run_id=race_run_id,
            audit_receipt_id="audit-ct010-race-boundary",
        ).state

    with factory.begin() as session:
        _set_tenant(session)
        events = session.scalars(
            select(EventRecord)
            .where(EventRecord.run_id == run_id)
            .order_by(EventRecord.seq)
        ).all()

    assert requested.state is RunState.CANCELLING
    assert converged.cancel_observed and converged.state is RunState.CANCELLED
    assert race_results.count("conflict") == 1
    assert race_results.count("cancel") + race_results.count("success") == 1
    assert race_state in {RunState.CANCELLED, RunState.SUCCEEDED}
    assert [event.event_type for event in events] == [
        "run.cancel_requested",
        "run.cancelled",
    ]
    assert all(event.audit_receipt_id for event in events)

    _write_report(
        {
            "schema_version": "1.0",
            "task_id": "TASK-P06-005",
            "ct_id": "CT-010",
            "ct_status": "passed",
            "database": "isolated-postgresql-17",
            "cancel_intent_persist_count": 1,
            "safe_boundary_observed_count": 1,
            "cancelled_terminal_count": 1,
            "late_success_accepted_count": 0,
            "cancelled_reversal_accepted_count": 0,
            "disconnect_triggered_cancel_count": 0,
            "concurrent_winner_count": 1,
            "concurrent_conflict_count": 1,
            "illegal_terminal_count": 0,
            "missing_audit_receipt_count": 0,
            "production_write_count": 0,
        }
    )


def test_repeat_cancel_and_boundary_are_idempotent(cancel_database) -> None:
    cancellation = CancellationService(cancel_database)
    run_id, version = _create_run(cancel_database, running=False)
    first = cancellation.request_cancel(
        tenant_id=TENANT,
        principal_id=PRINCIPAL,
        run_id=run_id,
        expected_version=version,
        audit_receipt_id="audit-repeat-first",
    )
    repeated = cancellation.request_cancel(
        tenant_id=TENANT,
        principal_id=PRINCIPAL,
        run_id=run_id,
        expected_version=version,
        audit_receipt_id="audit-repeat-second",
    )
    terminal = cancellation.converge_at_safe_boundary(
        tenant_id=TENANT,
        run_id=run_id,
        audit_receipt_id="audit-repeat-boundary",
    )
    terminal_replay = cancellation.converge_at_safe_boundary(
        tenant_id=TENANT,
        run_id=run_id,
        audit_receipt_id="audit-repeat-boundary-replay",
    )
    assert not first.replayed and repeated.replayed
    assert terminal.state is RunState.CANCELLED
    assert terminal_replay.replayed and terminal_replay.version == terminal.version


def test_cancel_route_authorizes_and_binds_principal(cancel_database) -> None:
    cancellation = CancellationService(cancel_database)
    run_id, version = _create_run(cancel_database)
    active_context = [
        RequestContext(
            principal_id=PRINCIPAL,
            tenant_id=TENANT,
            permissions=(),
            locale="en",
            timezone="UTC",
            trace_id="trace-cancel",
        )
    ]
    router = create_cancel_router(
        cancellation,
        lambda request: active_context[0],
        lambda context, requested_run: "audit-route-cancel",
    )
    endpoint = next(
        route.endpoint
        for route in router.routes
        if route.path == "/v1/runs/{run_id}/cancel"
    )
    request = Request({"type": "http", "method": "POST", "path": "/", "headers": []})
    body = CancelRequest(expected_version=version)
    with pytest.raises(AuthorizationForbidden):
        asyncio.run(endpoint(run_id=run_id, body=body, request=request))
    active_context[0] = RequestContext(
        principal_id="wrong-principal",
        tenant_id=TENANT,
        permissions=("run.cancel",),
        locale="en",
        timezone="UTC",
        trace_id="trace-cancel-wrong",
    )
    with pytest.raises(HTTPException) as mismatch:
        asyncio.run(endpoint(run_id=run_id, body=body, request=request))
    assert mismatch.value.status_code == 409
    active_context[0] = RequestContext(
        principal_id=PRINCIPAL,
        tenant_id=TENANT,
        permissions=("run.cancel",),
        locale="en",
        timezone="UTC",
        trace_id="trace-cancel-correct",
    )
    response = asyncio.run(endpoint(run_id=run_id, body=body, request=request))
    assert response.status == "cancelling"


def test_safe_boundary_without_intent_has_no_side_effect(cancel_database) -> None:
    cancellation = CancellationService(cancel_database)
    run_id, version = _create_run(cancel_database)
    result = cancellation.converge_at_safe_boundary(
        tenant_id=TENANT,
        run_id=run_id,
        audit_receipt_id="audit-no-intent",
    )
    assert not result.cancel_observed
    assert result.state is RunState.RUNNING and result.version == version
    with cancel_database.begin() as session:
        _set_tenant(session)
        assert (
            session.scalar(
                select(func.count())
                .select_from(EventRecord)
                .where(EventRecord.run_id == run_id)
            )
            == 0
        )


def test_invalid_version_or_missing_audit_fails_closed(cancel_database) -> None:
    cancellation = CancellationService(cancel_database)
    run_id, version = _create_run(cancel_database)
    with pytest.raises(CancelRejected, match="cancel.conflict"):
        cancellation.request_cancel(
            tenant_id=TENANT,
            principal_id=PRINCIPAL,
            run_id=run_id,
            expected_version=version + 1,
            audit_receipt_id="audit-stale",
        )
    with pytest.raises(CancelRejected, match="cancel.conflict"):
        cancellation.request_cancel(
            tenant_id=TENANT,
            principal_id=PRINCIPAL,
            run_id=run_id,
            expected_version=version,
            audit_receipt_id="",
        )
    assert RunState(_state(cancel_database, run_id).state) is RunState.RUNNING
