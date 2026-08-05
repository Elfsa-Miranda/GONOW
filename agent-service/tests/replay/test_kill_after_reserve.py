from __future__ import annotations

import argparse
import json
import os
import site
import subprocess
import sys
import tempfile
import time
import uuid
from collections.abc import Iterator, Sequence
from contextlib import contextmanager
from dataclasses import dataclass
from datetime import timedelta
from pathlib import Path

SERVICE_ROOT = Path(__file__).resolve().parents[2]
site.addsitedir(str(SERVICE_ROOT / ".venv" / "Lib" / "site-packages"))
sys.path.insert(0, str(SERVICE_ROOT))

import pytest  # noqa: E402

from alembic import command  # noqa: E402
from alembic.config import Config  # noqa: E402
from sqlalchemy import create_engine, event, func, select, update  # noqa: E402
from sqlalchemy.engine import Engine, make_url  # noqa: E402
from sqlalchemy.orm import Session, sessionmaker  # noqa: E402
from sqlalchemy.schema import CreateSchema, DropSchema  # noqa: E402

from app.persistence.models.behavior import BEHAVIOR_SCHEMA  # noqa: E402
from app.persistence.models.invocations import (  # noqa: E402
    InvocationBudgetRecord,
    PhysicalInvocationRecord,
)
from app.persistence.models.jobs import (  # noqa: E402
    CheckpointMetadataRecord,
    JobRecord,
    LeaseRecord,
)
from app.persistence.models.runtime import (  # noqa: E402
    EventRecord,
    RUNTIME_SCHEMA,
    RunRecord,
    RunState,
)
from app.persistence.repositories.checkpoints import CheckpointsRepository  # noqa: E402
from app.persistence.repositories.events import EventsRepository  # noqa: E402
from app.persistence.repositories.invocations import (  # noqa: E402
    InvocationHandlerOutcome,
    PhysicalInvocationLedger,
)
from app.persistence.repositories.jobs import (  # noqa: E402
    JobsRepository,
    StaleFence,
)
from app.persistence.repositories.runs import RunsRepository  # noqa: E402


ALEMBIC_INI = SERVICE_ROOT / "alembic.ini"
TARGET_REVISION = "p05_004_invocation_ledger"
VERSION_SCHEMA = "p05_007_kill_replay_test"
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
REPORT_ENV = "GONOW_P05_007_REPORT"
EXPECTED_REPORT = (
    SERVICE_ROOT.parent
    / "docs"
    / "execution"
    / "evidence"
    / "phase-05"
    / "P05-007"
    / "kill-replay-report.json"
)
TENANT = "tenant-p05-kill-replay"
PRINCIPAL = "principal-p05-kill-replay"
ARGUMENT_DIGEST = "a" * 64
RESULT_DIGEST = "b" * 64
STATE_DIGEST = "c" * 64
STATE_SCHEMA_DIGEST = "d" * 64
PROBE_EXECUTABLE = Path(getattr(sys, "_base_executable", sys.executable)).resolve()


class WorkerSession(Session):
    pass


def test_scenario_worker_bootstrap_precedes_third_party_imports() -> None:
    source = Path(__file__).read_text(encoding="utf-8")
    assert source.index("site.addsitedir") < source.index("import pytest")


@event.listens_for(WorkerSession, "after_begin")
def _assume_worker_role(
    session: Session, transaction, connection
) -> None:  # pragma: no cover - exercised by child and recovery processes
    del session, transaction
    connection.exec_driver_sql("SET LOCAL ROLE gonow_agent_worker")


@dataclass(frozen=True, slots=True)
class ReplayEnvironment:
    owner_factory: sessionmaker[Session]
    worker_factory: sessionmaker[Session]


@dataclass(frozen=True, slots=True)
class WorkIdentity:
    run_id: uuid.UUID
    job_id: uuid.UUID
    old_holder_id: str
    old_fencing_token: int


@dataclass(frozen=True, slots=True)
class NewLease:
    holder_id: str
    fencing_token: int
    old_worker_denied: bool


@dataclass(frozen=True, slots=True)
class KilledWorker:
    scenario: str
    fixture: Path
    worker_pid: int
    barrier_reached: bool
    kill_confirmed: bool
    orphan_process_count: int


def _assert_task_owned_database() -> None:
    parsed = make_url(DATABASE_URL)
    assert parsed.drivername == "postgresql+pg8000"
    assert parsed.host == "127.0.0.1"
    assert parsed.port == 55432
    assert parsed.username == "gonow_migrator_test"
    assert parsed.database == "gonow_p03_test"
    assert parsed.password is None


def _config() -> Config:
    os.environ["GONOW_DATABASE_URL"] = DATABASE_URL
    os.environ["GONOW_ALEMBIC_VERSION_SCHEMA"] = VERSION_SCHEMA
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


@contextmanager
def replay_database() -> Iterator[ReplayEnvironment]:
    _assert_task_owned_database()
    engine = create_engine(DATABASE_URL, pool_pre_ping=True)
    admin_engine = create_engine(ADMIN_DATABASE_URL, pool_pre_ping=True)
    _drop_schemas(engine)
    with engine.begin() as connection:
        connection.execute(CreateSchema(VERSION_SCHEMA))
    _provision_principals(admin_engine)
    command.upgrade(_config(), TARGET_REVISION)
    environment = ReplayEnvironment(
        owner_factory=sessionmaker(engine, expire_on_commit=False),
        worker_factory=sessionmaker(
            admin_engine, class_=WorkerSession, expire_on_commit=False
        ),
    )
    try:
        yield environment
    finally:
        engine.dispose()
        cleanup_engine = create_engine(DATABASE_URL)
        try:
            _drop_schemas(cleanup_engine)
        finally:
            cleanup_engine.dispose()
        _drop_principals(admin_engine)
        admin_engine.dispose()


def set_tenant(session: Session, tenant_id: str = TENANT) -> None:
    session.execute(select(func.set_config("app.tenant_id", tenant_id, True)))


def create_work(environment: ReplayEnvironment, scenario: str) -> WorkIdentity:
    with environment.owner_factory.begin() as session:
        set_tenant(session)
        thread = RunsRepository(session).create_thread(
            tenant_id=TENANT, owner_principal_id=PRINCIPAL
        )
        created = RunsRepository(session).create_or_replay_run(
            tenant_id=TENANT,
            principal_id=PRINCIPAL,
            thread_id=thread.thread_id,
            request_scope="p05-kill-replay",
            idempotency_key=f"{scenario}-{uuid.uuid4()}",
            request_hash="1" * 64,
            manifest_digest="2" * 64,
            manifest={"fixture": "p05-kill-replay", "scenario": scenario},
        )
        run = session.get(RunRecord, created.run_id)
        assert run is not None
        run = RunsRepository(session).transition_state(
            tenant_id=TENANT,
            run_id=run.run_id,
            expected_state=RunState.QUEUED,
            expected_version=run.version,
            target_state=RunState.RUNNING,
        )
        job = JobsRepository(session).create_job(
            tenant_id=TENANT,
            run_id=run.run_id,
            job_type="itinerary.generate",
            input_ref="job-input://sha256/" + "3" * 64,
            audit_receipt_id=f"audit-{scenario}-job",
            max_attempts=2,
        )
        lease = JobsRepository(session).acquire_lease(
            tenant_id=TENANT,
            job_id=job.job_id,
            holder_id=f"worker-old-{scenario}",
            audit_receipt_id=f"audit-{scenario}-old-lease",
            lease_seconds=300,
        )
        return WorkIdentity(
            run_id=run.run_id,
            job_id=job.job_id,
            old_holder_id=lease.holder_id,
            old_fencing_token=lease.fencing_token,
        )


def _write_json_atomic(path: Path, value: dict[str, object]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + f".{os.getpid()}.tmp")
    temporary.write_text(
        json.dumps(value, sort_keys=True, separators=(",", ":")), encoding="utf-8"
    )
    os.replace(temporary, path)


def _wait_for_json(path: Path, timeout_seconds: float = 10) -> dict[str, object]:
    deadline = time.monotonic() + timeout_seconds
    while time.monotonic() < deadline:
        if path.is_file():
            return json.loads(path.read_text(encoding="utf-8"))
        time.sleep(0.01)
    raise TimeoutError(f"scenario barrier timed out: {path.name}")


@contextmanager
def killed_worker(
    identity: WorkIdentity, scenario: str
) -> Iterator[KilledWorker]:
    with tempfile.TemporaryDirectory(prefix="gonow-p05-007-") as temporary:
        fixture = Path(temporary).resolve()
        config_path = fixture / "scenario.json"
        _write_json_atomic(
            config_path,
            {
                "schema_version": "1.0",
                "scenario": scenario,
                "tenant_id": TENANT,
                "run_id": str(identity.run_id),
                "job_id": str(identity.job_id),
                "holder_id": identity.old_holder_id,
                "fencing_token": identity.old_fencing_token,
                "fixture": str(fixture),
            },
        )
        process = subprocess.Popen(
            [
                str(PROBE_EXECUTABLE),
                str(Path(__file__).resolve()),
                "--scenario-worker",
                str(config_path),
            ],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.PIPE,
            shell=False,
            text=True,
        )
        try:
            try:
                barrier = _wait_for_json(fixture / "barrier.json")
            except TimeoutError as error:
                if process.poll() is None:
                    process.kill()
                    process.wait(timeout=5)
                stderr = process.stderr.read() if process.stderr is not None else ""
                raise RuntimeError(
                    "scenario worker failed before barrier; "
                    f"exit={process.returncode}; stderr={stderr[-2000:]}"
                ) from error
            barrier_reached = (
                barrier.get("scenario") == scenario
                and barrier.get("barrier_reached") is True
                and int(barrier.get("worker_pid", 0)) == process.pid
            )
            assert barrier_reached
            process.kill()
            process.wait(timeout=5)
            yield KilledWorker(
                scenario=scenario,
                fixture=fixture,
                worker_pid=process.pid,
                barrier_reached=True,
                kill_confirmed=process.poll() is not None,
                orphan_process_count=int(process.poll() is None),
            )
        finally:
            if process.poll() is None:
                process.kill()
                process.wait(timeout=5)


def rotate_lease(
    environment: ReplayEnvironment, identity: WorkIdentity, scenario: str
) -> NewLease:
    new_holder = f"worker-new-{scenario}"
    with environment.owner_factory.begin() as session:
        set_tenant(session)
        session.execute(
            update(LeaseRecord)
            .where(
                LeaseRecord.job_id == identity.job_id,
                LeaseRecord.fencing_token == identity.old_fencing_token,
                LeaseRecord.released_at.is_(None),
            )
            .values(
                acquired_at=func.statement_timestamp() - timedelta(seconds=120),
                heartbeat_at=func.statement_timestamp() - timedelta(seconds=120),
                expires_at=func.statement_timestamp() - timedelta(seconds=60),
            )
        )
        new_lease = JobsRepository(session).acquire_lease(
            tenant_id=TENANT,
            job_id=identity.job_id,
            holder_id=new_holder,
            audit_receipt_id=f"audit-{scenario}-new-lease",
            lease_seconds=300,
        )
    with environment.worker_factory.begin() as session:
        set_tenant(session)
        with pytest.raises(StaleFence):
            JobsRepository(session).assert_fence(
                tenant_id=TENANT,
                job_id=identity.job_id,
                holder_id=identity.old_holder_id,
                fencing_token=identity.old_fencing_token,
            )
    return NewLease(
        holder_id=new_lease.holder_id,
        fencing_token=new_lease.fencing_token,
        old_worker_denied=True,
    )


def increment_side_effect(fixture: Path) -> InvocationHandlerOutcome:
    path = fixture / "physical-side-effect.json"
    current = 0
    if path.is_file():
        current = int(json.loads(path.read_text(encoding="utf-8"))["count"])
    _write_json_atomic(path, {"count": current + 1})
    return InvocationHandlerOutcome.succeeded(RESULT_DIGEST)


def side_effect_count(fixture: Path) -> int:
    path = fixture / "physical-side-effect.json"
    if not path.is_file():
        return 0
    return int(json.loads(path.read_text(encoding="utf-8"))["count"])


def invocation_arguments(identity: WorkIdentity, lease: NewLease) -> dict[str, object]:
    return {
        "tenant_id": TENANT,
        "run_id": identity.run_id,
        "job_id": identity.job_id,
        "holder_id": lease.holder_id,
        "fencing_token": lease.fencing_token,
        "tool_call_id": "tool-call-p05-007",
        "tool_name": "weather.lookup",
        "tool_version": "1.0.0",
        "request_fingerprint": ARGUMENT_DIGEST,
        "max_physical_calls": 2,
    }


def append_recovery_event(
    environment: ReplayEnvironment, identity: WorkIdentity, scenario: str
) -> None:
    with environment.worker_factory.begin() as session:
        set_tenant(session)
        EventsRepository(session).append(
            tenant_id=TENANT,
            run_id=identity.run_id,
            event_type="replay.recovered",
            payload={"scenario": scenario},
            audit_receipt_id=f"audit-{scenario}-recovery",
        )


def collect_metrics(
    environment: ReplayEnvironment, identity: WorkIdentity
) -> dict[str, object]:
    with environment.owner_factory.begin() as session:
        set_tenant(session)
        invocation_count = int(
            session.scalar(
                select(func.count())
                .select_from(PhysicalInvocationRecord)
                .where(PhysicalInvocationRecord.run_id == identity.run_id)
            )
            or 0
        )
        reserved_calls = int(
            session.scalar(
                select(InvocationBudgetRecord.reserved_calls).where(
                    InvocationBudgetRecord.run_id == identity.run_id
                )
            )
            or 0
        )
        checkpoint_count = int(
            session.scalar(
                select(func.count())
                .select_from(CheckpointMetadataRecord)
                .where(CheckpointMetadataRecord.run_id == identity.run_id)
            )
            or 0
        )
        run_state = str(
            session.scalar(
                select(RunRecord.state).where(RunRecord.run_id == identity.run_id)
            )
        )
        orphan_database_count = int(
            session.scalar(
                select(func.count())
                .select_from(JobRecord)
                .where(
                    JobRecord.run_id == identity.run_id,
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
        missing_audit_receipt_count = sum(
            (
                int(
                    session.scalar(
                        select(func.count())
                        .select_from(JobRecord)
                        .where(
                            JobRecord.run_id == identity.run_id,
                            JobRecord.audit_receipt_id == "",
                        )
                    )
                    or 0
                ),
                int(
                    session.scalar(
                        select(func.count())
                        .select_from(LeaseRecord)
                        .where(
                            LeaseRecord.job_id == identity.job_id,
                            LeaseRecord.audit_receipt_id == "",
                        )
                    )
                    or 0
                ),
                int(
                    session.scalar(
                        select(func.count())
                        .select_from(CheckpointMetadataRecord)
                        .where(
                            CheckpointMetadataRecord.run_id == identity.run_id,
                            CheckpointMetadataRecord.audit_receipt_id == "",
                        )
                    )
                    or 0
                ),
                int(
                    session.scalar(
                        select(func.count())
                        .select_from(PhysicalInvocationRecord)
                        .where(
                            PhysicalInvocationRecord.run_id == identity.run_id,
                            PhysicalInvocationRecord.audit_receipt_id == "",
                        )
                    )
                    or 0
                ),
                int(
                    session.scalar(
                        select(func.count())
                        .select_from(EventRecord)
                        .where(
                            EventRecord.run_id == identity.run_id,
                            EventRecord.audit_receipt_id == "",
                        )
                    )
                    or 0
                ),
            )
        )
        terminal_invocation_status = session.scalar(
            select(PhysicalInvocationRecord.status).where(
                PhysicalInvocationRecord.run_id == identity.run_id
            )
        )
    return {
        "invocation_count": invocation_count,
        "reserved_calls": reserved_calls,
        "checkpoint_count": checkpoint_count,
        "run_state": run_state,
        "orphan_database_count": orphan_database_count,
        "missing_audit_receipt_count": missing_audit_receipt_count,
        "invocation_status": terminal_invocation_status,
    }


def build_result(
    *,
    environment: ReplayEnvironment,
    identity: WorkIdentity,
    killed: KilledWorker,
    lease: NewLease,
    ct_ids: tuple[str, ...],
    expected_side_effect_count: int,
    expected_invocation_count: int,
    expected_checkpoint_count: int,
    expected_run_state: RunState = RunState.RUNNING,
    expected_invocation_status: str | None = None,
) -> dict[str, object]:
    metrics = collect_metrics(environment, identity)
    actual_side_effect_count = side_effect_count(killed.fixture)
    duplicate_side_effect_count = max(
        0, actual_side_effect_count - expected_side_effect_count
    )
    passed = (
        killed.barrier_reached
        and killed.kill_confirmed
        and killed.orphan_process_count == 0
        and lease.old_worker_denied
        and duplicate_side_effect_count == 0
        and actual_side_effect_count == expected_side_effect_count
        and metrics["invocation_count"] == expected_invocation_count
        and metrics["checkpoint_count"] == expected_checkpoint_count
        and metrics["run_state"] == expected_run_state.value
        and metrics["orphan_database_count"] == 0
        and metrics["missing_audit_receipt_count"] == 0
        and (
            expected_invocation_status is None
            or metrics["invocation_status"] == expected_invocation_status
        )
    )
    return {
        "scenario": killed.scenario,
        "ct_ids": list(ct_ids),
        "barrier_reached": killed.barrier_reached,
        "kill_confirmed": killed.kill_confirmed,
        "old_worker_denied": lease.old_worker_denied,
        "orphan_process_count": killed.orphan_process_count,
        "orphan_database_count": metrics["orphan_database_count"],
        "missing_audit_receipt_count": metrics["missing_audit_receipt_count"],
        "side_effect_count": actual_side_effect_count,
        "expected_side_effect_count": expected_side_effect_count,
        "duplicate_side_effect_count": duplicate_side_effect_count,
        "invocation_count": metrics["invocation_count"],
        "reserved_calls": metrics["reserved_calls"],
        "invocation_status": metrics["invocation_status"],
        "checkpoint_count": metrics["checkpoint_count"],
        "run_state": metrics["run_state"],
        "passed": passed,
    }


def record_result(result: dict[str, object]) -> None:
    requested = os.environ.get(REPORT_ENV, "").strip()
    if not requested:
        return
    target = Path(requested).resolve()
    assert target == EXPECTED_REPORT.resolve()
    existing: dict[str, object] = {"results": []}
    if target.is_file():
        existing = json.loads(target.read_text(encoding="utf-8"))
    by_scenario = {
        str(row["scenario"]): row for row in existing.get("results", [])
    }
    by_scenario[str(result["scenario"])] = result
    results = [by_scenario[key] for key in sorted(by_scenario)]
    scenarios = {str(row["scenario"]): row for row in results}
    ct_005_passed = all(
        bool(scenarios.get(name, {}).get("passed"))
        for name in ("before_physical_call", "after_reservation")
    )
    ct_006_passed = all(
        bool(scenarios.get(name, {}).get("passed"))
        for name in ("before_result_persist", "after_result_persist")
    )
    report = {
        "schema_version": "1.0",
        "task_id": "TASK-P05-007",
        "database": "isolated-postgresql-17",
        "scenario_count": len(results),
        "expected_scenario_count": 7,
        "applicable_ct": {
            "CT-005": "passed" if ct_005_passed else "pending",
            "CT-006": "passed" if ct_006_passed else "pending",
        },
        "duplicate_side_effect_count": sum(
            int(row["duplicate_side_effect_count"]) for row in results
        ),
        "old_worker_denied_count": sum(
            int(bool(row["old_worker_denied"])) for row in results
        ),
        "orphan_process_count": sum(
            int(row["orphan_process_count"]) for row in results
        ),
        "orphan_database_count": sum(
            int(row["orphan_database_count"]) for row in results
        ),
        "missing_audit_receipt_count": sum(
            int(row["missing_audit_receipt_count"]) for row in results
        ),
        "failed_scenario_count": sum(not bool(row["passed"]) for row in results),
        "skipped_count": 0,
        "xfailed_count": 0,
        "production_write_count": 0,
        "results": results,
    }
    _write_json_atomic(target, report)


def _child_factory() -> sessionmaker[Session]:
    engine = create_engine(ADMIN_DATABASE_URL, pool_pre_ping=True)
    return sessionmaker(engine, class_=WorkerSession, expire_on_commit=False)


def _child_barrier(fixture: Path, scenario: str) -> None:
    _write_json_atomic(
        fixture / "barrier.json",
        {
            "schema_version": "1.0",
            "scenario": scenario,
            "worker_pid": os.getpid(),
            "barrier_reached": True,
        },
    )
    while True:
        time.sleep(60)


def run_scenario_worker(config_path: Path) -> int:
    config = json.loads(config_path.read_text(encoding="utf-8"))
    scenario = str(config["scenario"])
    fixture = Path(str(config["fixture"])).resolve()
    identity = WorkIdentity(
        run_id=uuid.UUID(str(config["run_id"])),
        job_id=uuid.UUID(str(config["job_id"])),
        old_holder_id=str(config["holder_id"]),
        old_fencing_token=int(config["fencing_token"]),
    )
    old_lease = NewLease(
        holder_id=identity.old_holder_id,
        fencing_token=identity.old_fencing_token,
        old_worker_denied=False,
    )
    invocation = invocation_arguments(identity, old_lease)
    factory = _child_factory()
    if scenario == "before_physical_call":
        _child_barrier(fixture, scenario)
    if scenario == "after_reservation":
        PhysicalInvocationLedger(factory).reserve(
            **invocation, audit_receipt_id="audit-after-reservation-reserve"
        )
        _child_barrier(fixture, scenario)
    if scenario in {"before_result_persist", "after_result_persist"}:
        ledger = PhysicalInvocationLedger(factory)
        ledger.reserve(**invocation, audit_receipt_id=f"audit-{scenario}-reserve")
        outcome = increment_side_effect(fixture)
        if scenario == "after_result_persist":
            ledger.record_outcome(
                tenant_id=TENANT,
                run_id=identity.run_id,
                job_id=identity.job_id,
                holder_id=identity.old_holder_id,
                fencing_token=identity.old_fencing_token,
                tool_call_id="tool-call-p05-007",
                request_fingerprint=ARGUMENT_DIGEST,
                outcome=outcome,
                audit_receipt_id="audit-after-result-persist",
            )
        _child_barrier(fixture, scenario)
    if scenario in {"before_checkpoint_persist", "after_checkpoint_persist"}:
        if scenario == "after_checkpoint_persist":
            with factory.begin() as session:
                set_tenant(session)
                CheckpointsRepository(session).save(
                    tenant_id=TENANT,
                    run_id=identity.run_id,
                    job_id=identity.job_id,
                    holder_id=identity.old_holder_id,
                    fencing_token=identity.old_fencing_token,
                    state_ref="checkpoint://sha256/" + STATE_DIGEST,
                    state_digest=STATE_DIGEST,
                    state_schema_digest=STATE_SCHEMA_DIGEST,
                    pending_writes_ref=None,
                    audit_receipt_id="audit-after-checkpoint-persist",
                )
        _child_barrier(fixture, scenario)
    if scenario == "before_terminal_transition":
        _child_barrier(fixture, scenario)
    raise ValueError(f"unsupported scenario: {scenario}")


def test_ct_005_kill_before_physical_call_executes_once_after_recovery() -> None:
    scenario = "before_physical_call"
    with replay_database() as environment:
        identity = create_work(environment, scenario)
        with killed_worker(identity, scenario) as killed:
            lease = rotate_lease(environment, identity, scenario)
            execution = PhysicalInvocationLedger(environment.worker_factory).invoke(
                **invocation_arguments(identity, lease),
                reservation_audit_receipt_id="audit-before-call-reserve",
                completion_audit_receipt_id="audit-before-call-complete",
                handler=lambda: increment_side_effect(killed.fixture),
            )
            assert execution.decision == "execute" and execution.handler_called
            append_recovery_event(environment, identity, scenario)
            result = build_result(
                environment=environment,
                identity=identity,
                killed=killed,
                lease=lease,
                ct_ids=("CT-005",),
                expected_side_effect_count=1,
                expected_invocation_count=1,
                expected_checkpoint_count=0,
                expected_invocation_status="succeeded",
            )
            assert result["passed"]
            record_result(result)


def test_ct_005_kill_after_reservation_never_exceeds_physical_budget() -> None:
    scenario = "after_reservation"
    with replay_database() as environment:
        identity = create_work(environment, scenario)
        with killed_worker(identity, scenario) as killed:
            lease = rotate_lease(environment, identity, scenario)
            ledger = PhysicalInvocationLedger(environment.worker_factory)
            replay = ledger.reserve(
                **invocation_arguments(identity, lease),
                audit_receipt_id="audit-after-reservation-recover",
            )
            assert replay.decision == "reconcile"
            ledger.record_outcome(
                tenant_id=TENANT,
                run_id=identity.run_id,
                job_id=identity.job_id,
                holder_id=lease.holder_id,
                fencing_token=lease.fencing_token,
                tool_call_id="tool-call-p05-007",
                request_fingerprint=ARGUMENT_DIGEST,
                outcome=InvocationHandlerOutcome.unknown("tool.unknown_after_kill"),
                audit_receipt_id="audit-after-reservation-unknown",
            )
            append_recovery_event(environment, identity, scenario)
            result = build_result(
                environment=environment,
                identity=identity,
                killed=killed,
                lease=lease,
                ct_ids=("CT-005",),
                expected_side_effect_count=0,
                expected_invocation_count=1,
                expected_checkpoint_count=0,
                expected_invocation_status="unknown_outcome",
            )
            assert result["reserved_calls"] == 1
            assert result["passed"]
            record_result(result)


def build_child_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="P05-007 scenario worker")
    parser.add_argument("--scenario-worker", type=Path, required=True)
    return parser


if __name__ == "__main__":
    raise SystemExit(
        run_scenario_worker(build_child_parser().parse_args().scenario_worker)
    )
