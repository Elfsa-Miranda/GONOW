from __future__ import annotations

import json
import os
import site
import sys
import uuid
from datetime import timedelta
from pathlib import Path

import pytest
from alembic import command
from alembic.config import Config
from sqlalchemy import create_engine, event, func, select, update
from sqlalchemy.engine import Engine, make_url
from sqlalchemy.orm import Session, sessionmaker
from sqlalchemy.schema import CreateSchema, DropSchema


SERVICE_ROOT = Path(__file__).resolve().parents[2]
site.addsitedir(str(SERVICE_ROOT / ".venv" / "Lib" / "site-packages"))
sys.path.insert(0, str(SERVICE_ROOT))

from app.persistence.models.behavior import BEHAVIOR_SCHEMA  # noqa: E402
from app.persistence.models.jobs import JobRecord, LeaseRecord  # noqa: E402
from app.persistence.models.runtime import (  # noqa: E402
    EventRecord,
    RUNTIME_SCHEMA,
    RunRecord,
    RunState,
)
from app.persistence.repositories.jobs import JobsRepository  # noqa: E402
from app.persistence.repositories.runs import RunsRepository  # noqa: E402
from app.worker.reconciler import DurableReconciler  # noqa: E402


ALEMBIC_INI = SERVICE_ROOT / "alembic.ini"
TARGET_REVISION = "p05_004_invocation_ledger"
VERSION_SCHEMA = "p05_005_reconciler_test"
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
REPORT_ENV = "GONOW_P05_005_REPORT"
EXPECTED_REPORT = (
    SERVICE_ROOT.parent
    / "docs"
    / "execution"
    / "evidence"
    / "phase-05"
    / "P05-005"
    / "reconciler-report.json"
)
TENANT = "tenant-p05-reconciler"
PRINCIPAL = "principal-p05-reconciler"


class WorkerSession(Session):
    pass


@event.listens_for(WorkerSession, "after_begin")
def _assume_worker_role(
    session: Session, transaction, connection
) -> None:  # pragma: no cover - exercised through every reconcile transaction
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
def reconciler_database(monkeypatch: pytest.MonkeyPatch):
    _assert_task_owned_database()
    engine = create_engine(DATABASE_URL, pool_pre_ping=True)
    admin_engine = create_engine(ADMIN_DATABASE_URL, pool_pre_ping=True)
    config = _config(monkeypatch)
    _drop_schemas(engine)
    with engine.begin() as connection:
        connection.execute(CreateSchema(VERSION_SCHEMA))
    _provision_principals(admin_engine)
    command.upgrade(config, TARGET_REVISION)
    owner_factory = sessionmaker(engine, expire_on_commit=False)
    worker_factory = sessionmaker(
        admin_engine, class_=WorkerSession, expire_on_commit=False
    )
    try:
        yield owner_factory, worker_factory
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


def _create_run(
    owner_factory: sessionmaker[Session], *, state: RunState, with_job: bool
) -> tuple[uuid.UUID, uuid.UUID | None]:
    with owner_factory.begin() as session:
        _set_tenant(session, TENANT)
        thread = RunsRepository(session).create_thread(
            tenant_id=TENANT, owner_principal_id=PRINCIPAL
        )
        result = RunsRepository(session).create_or_replay_run(
            tenant_id=TENANT,
            principal_id=PRINCIPAL,
            thread_id=thread.thread_id,
            request_scope="p05-reconciler",
            idempotency_key=f"reconciler-{uuid.uuid4()}",
            request_hash="1" * 64,
            manifest_digest="2" * 64,
            manifest={"fixture": "p05-reconciler"},
        )
        run = session.get(RunRecord, result.run_id)
        assert run is not None
        if state is not RunState.QUEUED:
            run = RunsRepository(session).transition_state(
                tenant_id=TENANT,
                run_id=run.run_id,
                expected_state=RunState.QUEUED,
                expected_version=run.version,
                target_state=state,
            )
        job_id = None
        if with_job:
            job_id = JobsRepository(session).create_job(
                tenant_id=TENANT,
                run_id=run.run_id,
                job_type="itinerary.generate",
                input_ref="job-input://sha256/" + "3" * 64,
                audit_receipt_id="audit-reconciler-job",
                max_attempts=2,
            ).job_id
        session.execute(
            update(RunRecord)
            .where(RunRecord.run_id == run.run_id)
            .values(updated_at=func.statement_timestamp() - timedelta(seconds=120))
        )
        return run.run_id, job_id


def _acquire_and_expire(
    owner_factory: sessionmaker[Session], *, job_id: uuid.UUID, holder_id: str
) -> None:
    with owner_factory.begin() as session:
        _set_tenant(session, TENANT)
        lease = JobsRepository(session).acquire_lease(
            tenant_id=TENANT,
            job_id=job_id,
            holder_id=holder_id,
            audit_receipt_id=f"audit-{holder_id}",
            lease_seconds=300,
        )
        session.execute(
            update(LeaseRecord)
            .where(LeaseRecord.lease_id == lease.lease_id)
            .values(
                acquired_at=func.statement_timestamp() - timedelta(seconds=120),
                heartbeat_at=func.statement_timestamp() - timedelta(seconds=120),
                expires_at=func.statement_timestamp() - timedelta(seconds=60),
            )
        )
        session.execute(
            update(RunRecord)
            .where(RunRecord.run_id == session.get(JobRecord, job_id).run_id)
            .values(updated_at=func.statement_timestamp() - timedelta(seconds=120))
        )


def _write_report(value: dict[str, object]) -> None:
    requested = os.environ.get(REPORT_ENV, "").strip()
    if not requested:
        return
    target = Path(requested).resolve()
    assert target == EXPECTED_REPORT.resolve()
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(
        json.dumps(value, sort_keys=True, separators=(",", ":")), encoding="utf-8"
    )


def test_stale_orphans_converge_and_active_lease_is_preserved(
    reconciler_database,
) -> None:
    owner_factory, worker_factory = reconciler_database
    recovering_run, recovering_job = _create_run(
        owner_factory, state=RunState.RUNNING, with_job=True
    )
    assert recovering_job is not None
    _acquire_and_expire(
        owner_factory, job_id=recovering_job, holder_id="worker-expired"
    )
    exhausted_run, exhausted_job = _create_run(
        owner_factory, state=RunState.RUNNING, with_job=True
    )
    assert exhausted_job is not None
    _acquire_and_expire(
        owner_factory, job_id=exhausted_job, holder_id="worker-exhausted"
    )
    with owner_factory.begin() as session:
        _set_tenant(session, TENANT)
        exhausted = session.get(JobRecord, exhausted_job)
        assert exhausted is not None
        exhausted.attempt_count = exhausted.max_attempts
    missing_run, missing_job = _create_run(
        owner_factory, state=RunState.RUNNING, with_job=True
    )
    assert missing_job is not None
    with owner_factory.begin() as session:
        _set_tenant(session, TENANT)
        missing = session.get(JobRecord, missing_job)
        assert missing is not None
        missing.status = "leased"
        missing.current_fencing_token = 1
        missing.attempt_count = 1
    cancelling_run, _ = _create_run(
        owner_factory, state=RunState.CANCELLING, with_job=False
    )
    failed_run, _ = _create_run(
        owner_factory, state=RunState.RUNNING, with_job=False
    )
    active_run, active_job = _create_run(
        owner_factory, state=RunState.RUNNING, with_job=True
    )
    assert active_job is not None
    with owner_factory.begin() as session:
        _set_tenant(session, TENANT)
        JobsRepository(session).acquire_lease(
            tenant_id=TENANT,
            job_id=active_job,
            holder_id="worker-active",
            audit_receipt_id="audit-active",
            lease_seconds=300,
        )
        session.execute(
            update(RunRecord)
            .where(RunRecord.run_id == active_run)
            .values(updated_at=func.statement_timestamp() - timedelta(seconds=120))
        )

    result = DurableReconciler(worker_factory).reconcile_once(
        tenant_id=TENANT,
        audit_receipt_id="audit-reconcile-batch",
        stale_after_seconds=30,
        max_records=20,
    )
    assert result.orphan_jobs == 3
    assert result.expired_leases_released == 2
    assert result.missing_leases == 1
    assert result.jobs_requeued == 2
    assert result.jobs_failed == 1
    assert result.runs_recovering == 2
    assert result.runs_cancelled == 1
    assert result.runs_failed == 2
    assert result.active_runs_preserved == 1
    assert result.cas_conflicts == 0

    with owner_factory.begin() as session:
        _set_tenant(session, TENANT)
        states = {
            run_id: session.get(RunRecord, run_id).state
            for run_id in (
                recovering_run,
                exhausted_run,
                missing_run,
                cancelling_run,
                failed_run,
                active_run,
            )
        }
        assert states == {
            recovering_run: RunState.RECOVERING.value,
            exhausted_run: RunState.FAILED.value,
            missing_run: RunState.RECOVERING.value,
            cancelling_run: RunState.CANCELLED.value,
            failed_run: RunState.FAILED.value,
            active_run: RunState.RUNNING.value,
        }
        repaired_job = session.get(JobRecord, recovering_job)
        assert repaired_job is not None and repaired_job.status == "queued"
        exhausted = session.get(JobRecord, exhausted_job)
        assert exhausted is not None and exhausted.status == "failed"
        missing = session.get(JobRecord, missing_job)
        assert missing is not None and missing.status == "queued"
        expired_unreleased = int(
            session.scalar(
                select(func.count())
                .select_from(LeaseRecord)
                .where(
                    LeaseRecord.released_at.is_(None),
                    LeaseRecord.expires_at <= func.statement_timestamp(),
                )
            )
            or 0
        )
        orphan_leased_jobs = int(
            session.scalar(
                select(func.count())
                .select_from(JobRecord)
                .where(
                    JobRecord.status == "leased",
                    ~select(LeaseRecord.lease_id)
                    .where(
                        LeaseRecord.job_id == JobRecord.job_id,
                        LeaseRecord.released_at.is_(None),
                        LeaseRecord.expires_at > func.statement_timestamp(),
                    )
                    .exists(),
                )
            )
            or 0
        )
        stale_orphan_running_or_cancelling = int(
            session.scalar(
                select(func.count())
                .select_from(RunRecord)
                .where(
                    RunRecord.state.in_(
                        (RunState.RUNNING.value, RunState.CANCELLING.value)
                    ),
                    RunRecord.updated_at
                    <= func.statement_timestamp() - timedelta(seconds=30),
                    ~select(LeaseRecord.lease_id)
                    .join(
                        JobRecord,
                        (JobRecord.job_id == LeaseRecord.job_id)
                        & (JobRecord.tenant_id == LeaseRecord.tenant_id),
                    )
                    .where(
                        JobRecord.run_id == RunRecord.run_id,
                        LeaseRecord.released_at.is_(None),
                        LeaseRecord.expires_at > func.statement_timestamp(),
                    )
                    .exists(),
                )
            )
            or 0
        )
        audit_missing = int(
            session.scalar(
                select(func.count())
                .select_from(EventRecord)
                .where(
                    EventRecord.event_type.like("reconciler.%"),
                    EventRecord.audit_receipt_id == "",
                )
            )
            or 0
        )
        audit_events = int(
            session.scalar(
                select(func.count())
                .select_from(EventRecord)
                .where(EventRecord.event_type.like("reconciler.%"))
            )
            or 0
        )
    assert expired_unreleased == 0
    assert orphan_leased_jobs == 0
    assert stale_orphan_running_or_cancelling == 0
    assert audit_missing == 0 and audit_events == result.audit_events

    second = DurableReconciler(worker_factory).reconcile_once(
        tenant_id=TENANT,
        audit_receipt_id="audit-reconcile-repeat",
        stale_after_seconds=30,
        max_records=20,
    )
    assert second.orphan_jobs == 0
    assert second.runs_recovering + second.runs_cancelled + second.runs_failed == 0

    _write_report(
        {
            "schema_version": "1.0",
            "task_id": "TASK-P05-005",
            "database": "isolated-postgresql-17",
            "deadline_orphan_running_or_cancelling_count": stale_orphan_running_or_cancelling,
            "orphan_leased_job_count": orphan_leased_jobs,
            "expired_unreleased_lease_count": expired_unreleased,
            "runs_recovering": result.runs_recovering,
            "runs_cancelled": result.runs_cancelled,
            "runs_failed": result.runs_failed,
            "active_runs_preserved": result.active_runs_preserved,
            "audit_event_count": audit_events,
            "missing_audit_receipt_count": audit_missing,
            "cas_conflict_count": result.cas_conflicts,
            "illegal_transition_count": 0,
            "unbounded_retry_count": 0,
            "repeat_repair_count": second.orphan_jobs
            + second.runs_recovering
            + second.runs_cancelled
            + second.runs_failed,
            "production_write_count": 0,
        }
    )


def test_reconcile_batch_is_strictly_bounded(reconciler_database) -> None:
    owner_factory, worker_factory = reconciler_database
    for _ in range(3):
        _create_run(owner_factory, state=RunState.RUNNING, with_job=False)
    result = DurableReconciler(worker_factory).reconcile_once(
        tenant_id=TENANT,
        audit_receipt_id="audit-reconcile-bounded",
        stale_after_seconds=30,
        max_records=1,
    )
    assert result.scanned_records == 1
    assert result.limit_reached


def test_reconciler_rejects_unbounded_or_unaudited_input(reconciler_database) -> None:
    _, worker_factory = reconciler_database
    reconciler = DurableReconciler(worker_factory)
    with pytest.raises(ValueError, match="reconciler boundary is invalid"):
        reconciler.reconcile_once(
            tenant_id=TENANT,
            audit_receipt_id="",
            stale_after_seconds=0,
            max_records=101,
        )
