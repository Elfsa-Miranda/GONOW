from __future__ import annotations

import json
import os
import site
import sys
import threading
import uuid
from concurrent.futures import ThreadPoolExecutor
from datetime import timedelta
from pathlib import Path

import pytest
from alembic import command
from alembic.config import Config
from sqlalchemy import create_engine, event, func, inspect, select, text, update
from sqlalchemy.engine import Engine, make_url
from sqlalchemy.exc import DBAPIError
from sqlalchemy.orm import Session, sessionmaker
from sqlalchemy.schema import CreateSchema, DropSchema


SERVICE_ROOT = Path(__file__).resolve().parents[2]
site.addsitedir(str(SERVICE_ROOT / ".venv" / "Lib" / "site-packages"))
sys.path.insert(0, str(SERVICE_ROOT))

from app.persistence.models.behavior import BEHAVIOR_SCHEMA  # noqa: E402
from app.persistence.models.invocations import (  # noqa: E402
    InvocationBudgetRecord,
    PhysicalInvocationRecord,
)
from app.persistence.models.jobs import JobRecord, LeaseRecord  # noqa: E402
from app.persistence.models.runtime import RUNTIME_SCHEMA, RunRecord  # noqa: E402
from app.persistence.repositories.invocations import (  # noqa: E402
    InvocationBudgetConflict,
    InvocationConflict,
    InvocationHandlerOutcome,
    PhysicalBudgetExceeded,
    PhysicalInvocationLedger,
    invocation_fingerprint,
)
from app.persistence.repositories.jobs import JobsRepository  # noqa: E402
from app.persistence.repositories.runs import RunsRepository  # noqa: E402


ALEMBIC_INI = SERVICE_ROOT / "alembic.ini"
TARGET_REVISION = "p05_004_invocation_ledger"
PREVIOUS_REVISION = "p05_003_checkpoint_refs"
VERSION_SCHEMA = "p05_004_invocation_ledger_test"
DATABASE_URL = os.environ.get(
    "GONOW_P05_TEST_DATABASE_URL",
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
REPORT_ENV = "GONOW_P05_004_REPORT"
EXPECTED_REPORT = (
    SERVICE_ROOT.parent
    / "docs"
    / "execution"
    / "evidence"
    / "phase-05"
    / "P05-004"
    / "invocation-ledger-report.json"
)
TENANT = "tenant-p05-invocation"
PRINCIPAL = "principal-p05-invocation"
TOOL_NAME = "weather.current"
TOOL_VERSION = "1.0.0"


class SimulatedProcessKill(SystemExit):
    pass


class WorkerSession(Session):
    pass


@event.listens_for(WorkerSession, "after_begin")
def _assume_worker_role(
    session: Session, transaction, connection
) -> None:  # pragma: no cover - exercised through every ledger transaction
    del session, transaction
    connection.exec_driver_sql("SET LOCAL ROLE gonow_agent_worker")


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


def _drop_schemas(engine: Engine) -> None:
    with engine.begin() as connection:
        connection.execute(DropSchema(BEHAVIOR_SCHEMA, cascade=True, if_exists=True))
        connection.execute(DropSchema(RUNTIME_SCHEMA, cascade=True, if_exists=True))
        connection.execute(DropSchema(VERSION_SCHEMA, cascade=True, if_exists=True))


@pytest.fixture()
def invocation_database(monkeypatch: pytest.MonkeyPatch):
    _assert_task_owned_database()
    engine = create_engine(DATABASE_URL, pool_pre_ping=True, pool_size=8, max_overflow=0)
    admin_engine = create_engine(
        ADMIN_DATABASE_URL, pool_pre_ping=True, pool_size=8, max_overflow=0
    )
    config = _config(monkeypatch)
    _drop_schemas(engine)
    with engine.begin() as connection:
        connection.execute(CreateSchema(VERSION_SCHEMA))
    _provision_principals(admin_engine)
    command.upgrade(config, TARGET_REVISION)
    owner_factory = sessionmaker(engine, expire_on_commit=False)
    worker_factory = sessionmaker(
        admin_engine,
        class_=WorkerSession,
        expire_on_commit=False,
    )
    try:
        yield engine, admin_engine, config, owner_factory, worker_factory
    finally:
        engine.dispose()
        cleanup_engine = create_engine(DATABASE_URL)
        try:
            _drop_schemas(cleanup_engine)
        finally:
            cleanup_engine.dispose()
        _drop_principals(admin_engine)
        admin_engine.dispose()


def _set_tenant(session: Session, tenant_id: str) -> None:
    session.execute(select(func.set_config("app.tenant_id", tenant_id, True)))


def _seed(
    owner_factory: sessionmaker[Session], *, holder_id: str
) -> tuple[uuid.UUID, uuid.UUID, int]:
    with owner_factory.begin() as session:
        _set_tenant(session, TENANT)
        thread = RunsRepository(session).create_thread(
            tenant_id=TENANT,
            owner_principal_id=PRINCIPAL,
        )
        run = RunsRepository(session).create_or_replay_run(
            tenant_id=TENANT,
            principal_id=PRINCIPAL,
            thread_id=thread.thread_id,
            request_scope="p05-invocation",
            idempotency_key=f"invocation-{uuid.uuid4()}",
            request_hash="1" * 64,
            manifest_digest="2" * 64,
            manifest={"fixture": "p05-invocation"},
        )
        job = JobsRepository(session).create_job(
            tenant_id=TENANT,
            run_id=run.run_id,
            job_type="itinerary.generate",
            input_ref="job-input://sha256/" + "3" * 64,
            audit_receipt_id="audit-invocation-job",
            max_attempts=2,
        )
    with owner_factory.begin() as session:
        _set_tenant(session, TENANT)
        lease = JobsRepository(session).acquire_lease(
            tenant_id=TENANT,
            job_id=job.job_id,
            holder_id=holder_id,
            audit_receipt_id="audit-invocation-lease",
            lease_seconds=300,
        )
    return run.run_id, job.job_id, lease.fencing_token


def _invoke_kwargs(
    run_id: uuid.UUID,
    job_id: uuid.UUID,
    token: int,
    *,
    holder_id: str,
    tool_call_id: str,
    argument_digest: str,
    max_physical_calls: int,
) -> dict[str, object]:
    return {
        "tenant_id": TENANT,
        "run_id": run_id,
        "job_id": job_id,
        "holder_id": holder_id,
        "fencing_token": token,
        "tool_call_id": tool_call_id,
        "tool_name": TOOL_NAME,
        "tool_version": TOOL_VERSION,
        "request_fingerprint": invocation_fingerprint(
            tool_name=TOOL_NAME,
            tool_version=TOOL_VERSION,
            argument_sha256=argument_digest,
        ),
        "max_physical_calls": max_physical_calls,
        "reservation_audit_receipt_id": f"audit-reserve-{tool_call_id}",
        "completion_audit_receipt_id": f"audit-complete-{tool_call_id}",
    }


def _expire_lease(
    owner_factory: sessionmaker[Session], *, job_id: uuid.UUID, fencing_token: int
) -> None:
    with owner_factory.begin() as session:
        _set_tenant(session, TENANT)
        changed = session.execute(
            update(LeaseRecord)
            .where(
                LeaseRecord.job_id == job_id,
                LeaseRecord.fencing_token == fencing_token,
                LeaseRecord.released_at.is_(None),
            )
            .values(
                acquired_at=func.statement_timestamp() - timedelta(seconds=10),
                heartbeat_at=func.statement_timestamp() - timedelta(seconds=10),
                expires_at=func.statement_timestamp() - timedelta(seconds=1),
            )
        ).rowcount
        assert changed == 1


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


def test_ct005_ct006_replay_conflict_unknown_and_migration_rollback(
    invocation_database,
) -> None:
    engine, _, config, owner_factory, worker_factory = invocation_database
    ledger = PhysicalInvocationLedger(worker_factory)
    external_calls = 0

    replay_run, replay_job, replay_token = _seed(
        owner_factory, holder_id="worker-replay"
    )
    replay_kwargs = _invoke_kwargs(
        replay_run,
        replay_job,
        replay_token,
        holder_id="worker-replay",
        tool_call_id="call-replay",
        argument_digest="4" * 64,
        max_physical_calls=2,
    )

    def successful_handler() -> InvocationHandlerOutcome:
        nonlocal external_calls
        external_calls += 1
        return InvocationHandlerOutcome.succeeded("5" * 64)

    first = ledger.invoke(**replay_kwargs, handler=successful_handler)
    replayed = ledger.invoke(**replay_kwargs, handler=successful_handler)
    assert first.decision == "execute" and first.invocation.status == "succeeded"
    assert replayed.decision == "replay" and not replayed.handler_called
    assert external_calls == 1

    changed = dict(replay_kwargs)
    changed["request_fingerprint"] = invocation_fingerprint(
        tool_name=TOOL_NAME,
        tool_version=TOOL_VERSION,
        argument_sha256="6" * 64,
    )
    with pytest.raises(InvocationConflict, match="tool.invocation_conflict"):
        ledger.invoke(**changed, handler=successful_handler)
    assert external_calls == 1

    ct005_run, ct005_job, ct005_token = _seed(
        owner_factory, holder_id="worker-ct005"
    )
    ct005_kwargs = _invoke_kwargs(
        ct005_run,
        ct005_job,
        ct005_token,
        holder_id="worker-ct005",
        tool_call_id="call-ct005",
        argument_digest="7" * 64,
        max_physical_calls=1,
    )
    before_handler_calls = 0

    def before_handler() -> InvocationHandlerOutcome:
        nonlocal before_handler_calls
        before_handler_calls += 1
        return InvocationHandlerOutcome.succeeded("8" * 64)

    def kill_after_reservation(point: str) -> None:
        if point == "after_reservation":
            raise SimulatedProcessKill()

    with pytest.raises(SimulatedProcessKill):
        ledger.invoke(
            **ct005_kwargs,
            handler=before_handler,
            failure_injection_hook=kill_after_reservation,
        )
    recovered_ct005 = ledger.invoke(**ct005_kwargs, handler=before_handler)
    assert recovered_ct005.decision == "reconcile"
    assert not recovered_ct005.handler_called and before_handler_calls == 0
    ct005_second = _invoke_kwargs(
        ct005_run,
        ct005_job,
        ct005_token,
        holder_id="worker-ct005",
        tool_call_id="call-ct005-second",
        argument_digest="9" * 64,
        max_physical_calls=1,
    )
    with pytest.raises(PhysicalBudgetExceeded, match="budget.physical_tool_limit"):
        ledger.invoke(**ct005_second, handler=before_handler)

    ct006_run, ct006_job, ct006_token = _seed(
        owner_factory, holder_id="worker-ct006"
    )
    ct006_kwargs = _invoke_kwargs(
        ct006_run,
        ct006_job,
        ct006_token,
        holder_id="worker-ct006",
        tool_call_id="call-ct006",
        argument_digest="a" * 64,
        max_physical_calls=1,
    )
    after_handler_calls = 0

    def after_handler() -> InvocationHandlerOutcome:
        nonlocal after_handler_calls
        after_handler_calls += 1
        return InvocationHandlerOutcome.succeeded("b" * 64)

    def kill_before_persist(point: str) -> None:
        if point == "after_handler_before_persist":
            raise SimulatedProcessKill()

    with pytest.raises(SimulatedProcessKill):
        ledger.invoke(
            **ct006_kwargs,
            handler=after_handler,
            failure_injection_hook=kill_before_persist,
        )
    recovered_ct006 = ledger.invoke(**ct006_kwargs, handler=after_handler)
    assert recovered_ct006.decision == "reconcile"
    assert not recovered_ct006.handler_called and after_handler_calls == 1
    _expire_lease(
        owner_factory, job_id=ct006_job, fencing_token=ct006_token
    )
    with owner_factory.begin() as session:
        _set_tenant(session, TENANT)
        replacement = JobsRepository(session).reclaim_expired_job(
            tenant_id=TENANT,
            holder_id="worker-ct006-reconciler",
            audit_receipt_id="audit-ct006-reclaim",
            lease_seconds=300,
        )
        assert replacement is not None and replacement.job_id == ct006_job
    with pytest.raises(DBAPIError, match="consistency.stale_fence"):
        with worker_factory.begin() as session:
            _set_tenant(session, TENANT)
            session.execute(
                update(PhysicalInvocationRecord)
                .where(
                    PhysicalInvocationRecord.run_id == ct006_run,
                    PhysicalInvocationRecord.tool_call_id == "call-ct006",
                )
                .values(
                    status="unknown_outcome",
                    error_code="provider.unknown_outcome",
                    completion_holder_id="worker-ct006",
                    completion_fencing_token=ct006_token,
                    completion_audit_receipt_id="audit-stale-completion",
                    completed_at=func.statement_timestamp(),
                )
            )
    ledger.record_outcome(
        tenant_id=TENANT,
        run_id=ct006_run,
        job_id=ct006_job,
        holder_id=replacement.holder_id,
        fencing_token=replacement.fencing_token,
        tool_call_id="call-ct006",
        request_fingerprint=str(ct006_kwargs["request_fingerprint"]),
        outcome=InvocationHandlerOutcome.unknown("provider.unknown_outcome"),
        audit_receipt_id="audit-ct006-reconciled",
    )

    unknown_run, unknown_job, unknown_token = _seed(
        owner_factory, holder_id="worker-unknown"
    )
    unknown_kwargs = _invoke_kwargs(
        unknown_run,
        unknown_job,
        unknown_token,
        holder_id="worker-unknown",
        tool_call_id="call-unknown",
        argument_digest="c" * 64,
        max_physical_calls=1,
    )
    unknown_calls = 0

    def unknown_handler() -> InvocationHandlerOutcome:
        nonlocal unknown_calls
        unknown_calls += 1
        return InvocationHandlerOutcome.unknown("provider.unknown_outcome")

    unknown = ledger.invoke(**unknown_kwargs, handler=unknown_handler)
    unknown_replay = ledger.invoke(**unknown_kwargs, handler=unknown_handler)
    assert unknown.invocation.status == "unknown_outcome"
    assert unknown_replay.decision == "replay" and unknown_calls == 1
    unknown_second = _invoke_kwargs(
        unknown_run,
        unknown_job,
        unknown_token,
        holder_id="worker-unknown",
        tool_call_id="call-unknown-second",
        argument_digest="d" * 64,
        max_physical_calls=1,
    )
    with pytest.raises(PhysicalBudgetExceeded):
        ledger.invoke(**unknown_second, handler=unknown_handler)

    with worker_factory.begin() as session:
        _set_tenant(session, "tenant-invocation-isolation-canary")
        assert session.scalar(select(func.count()).select_from(PhysicalInvocationRecord)) == 0
        assert session.scalar(select(func.count()).select_from(InvocationBudgetRecord)) == 0

    with engine.connect() as connection:
        table_names = set(inspect(connection).get_table_names(schema=RUNTIME_SCHEMA))
        forced_rls_count = int(
            connection.scalar(
                text(
                    "SELECT count(*) FROM pg_class c "
                    "JOIN pg_namespace n ON n.oid = c.relnamespace "
                    "WHERE n.nspname = 'agent_runtime' "
                    "AND c.relname = ANY(:tables) "
                    "AND c.relrowsecurity AND c.relforcerowsecurity"
                ),
                {"tables": ["invocation_budgets", "physical_invocations"]},
            )
            or 0
        )
    assert {"invocation_budgets", "physical_invocations"} <= table_names
    assert forced_rls_count == 2

    with owner_factory.begin() as session:
        _set_tenant(session, TENANT)
        run_count_before = int(session.scalar(select(func.count()).select_from(RunRecord)) or 0)
        job_count_before = int(session.scalar(select(func.count()).select_from(JobRecord)) or 0)
        missing_audit_receipt_count = int(
            session.scalar(
                select(func.count())
                .select_from(PhysicalInvocationRecord)
                .where(PhysicalInvocationRecord.audit_receipt_id == "")
            )
            or 0
        )

    command.downgrade(config, PREVIOUS_REVISION)
    with engine.connect() as connection:
        downgraded = set(inspect(connection).get_table_names(schema=RUNTIME_SCHEMA))
    assert "invocation_budgets" not in downgraded
    assert "physical_invocations" not in downgraded
    assert {"runs", "jobs", "checkpoint_metadata", "checkpoint_payloads"} <= downgraded
    with owner_factory.begin() as session:
        _set_tenant(session, TENANT)
        assert session.scalar(select(func.count()).select_from(RunRecord)) == run_count_before
        assert session.scalar(select(func.count()).select_from(JobRecord)) == job_count_before
    command.upgrade(config, TARGET_REVISION)

    _write_report(
        {
            "schema_version": "1.0",
            "task_id": "TASK-P05-004",
            "database": "isolated-postgresql-17",
            "ct005_status": "passed",
            "ct006_status": "passed",
            "reserved_budget_overrun": 0,
            "same_fingerprint_external_call_count": external_calls,
            "changed_fingerprint_conflict_count": 1,
            "handler_before_reservation_count": 0,
            "ct005_handler_call_count": before_handler_calls,
            "ct006_external_call_count": after_handler_calls,
            "stale_invocation_write_rejection_count": 1,
            "unknown_outcome_external_call_count": unknown_calls,
            "unknown_outcome_refund_count": 0,
            "missing_audit_receipt_count": missing_audit_receipt_count,
            "forced_rls_table_count": forced_rls_count,
            "migration_downgrade_rebuild_failures": 0,
            "prior_runtime_rows_preserved": True,
            "redis_count": 0,
            "production_write_count": 0,
        }
    )


def test_concurrent_reservations_never_exceed_the_run_budget(
    invocation_database,
) -> None:
    _, _, _, owner_factory, worker_factory = invocation_database
    run_id, job_id, token = _seed(owner_factory, holder_id="worker-concurrent")
    ledger = PhysicalInvocationLedger(worker_factory)
    barrier = threading.Barrier(6)

    def reserve(index: int) -> str:
        kwargs = _invoke_kwargs(
            run_id,
            job_id,
            token,
            holder_id="worker-concurrent",
            tool_call_id=f"call-concurrent-{index}",
            argument_digest=f"{index + 1:x}" * 64,
            max_physical_calls=2,
        )
        barrier.wait(timeout=10)
        try:
            return ledger.reserve(
                **{
                    key: value
                    for key, value in kwargs.items()
                    if key
                    not in {
                        "reservation_audit_receipt_id",
                        "completion_audit_receipt_id",
                    }
                },
                audit_receipt_id=kwargs["reservation_audit_receipt_id"],
            ).decision
        except PhysicalBudgetExceeded:
            return "budget_exceeded"

    with ThreadPoolExecutor(max_workers=6) as pool:
        outcomes = list(pool.map(reserve, range(6)))
    assert outcomes.count("execute") == 2
    assert outcomes.count("budget_exceeded") == 4
    with worker_factory.begin() as session:
        _set_tenant(session, TENANT)
        budget = session.get(InvocationBudgetRecord, run_id)
        assert budget is not None and budget.reserved_calls == 2
        assert session.scalar(select(func.count()).select_from(PhysicalInvocationRecord)) == 2


def test_budget_limit_is_immutable_for_the_pinned_run(
    invocation_database,
) -> None:
    _, _, _, owner_factory, worker_factory = invocation_database
    run_id, job_id, token = _seed(owner_factory, holder_id="worker-limit")
    ledger = PhysicalInvocationLedger(worker_factory)
    kwargs = _invoke_kwargs(
        run_id,
        job_id,
        token,
        holder_id="worker-limit",
        tool_call_id="call-limit",
        argument_digest="e" * 64,
        max_physical_calls=2,
    )
    reservation_args = {
        key: value
        for key, value in kwargs.items()
        if key not in {"reservation_audit_receipt_id", "completion_audit_receipt_id"}
    }
    ledger.reserve(
        **reservation_args,
        audit_receipt_id=kwargs["reservation_audit_receipt_id"],
    )
    reservation_args["max_physical_calls"] = 3
    with pytest.raises(
        InvocationBudgetConflict, match="budget.physical_limit_conflict"
    ):
        ledger.reserve(
            **reservation_args,
            audit_receipt_id=kwargs["reservation_audit_receipt_id"],
        )
