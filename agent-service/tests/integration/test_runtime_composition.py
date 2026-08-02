from __future__ import annotations

from datetime import UTC, datetime, timedelta
import json
import os
from pathlib import Path
import site
import sys
from uuid import UUID, uuid4

from alembic import command
from alembic.config import Config
from fastapi import Request
from httpx import ASGITransport, AsyncClient
import pytest
from sqlalchemy import create_engine, event, func, select, text, update
from sqlalchemy.engine import Engine, make_url
from sqlalchemy.orm import Session, sessionmaker
from sqlalchemy.schema import CreateSchema, DropSchema


SERVICE_ROOT = Path(__file__).resolve().parents[2]
REPOSITORY_ROOT = SERVICE_ROOT.parent
site.addsitedir(str(SERVICE_ROOT / ".venv" / "Lib" / "site-packages"))
sys.path.insert(0, str(SERVICE_ROOT))

from app.api.health import DependencySnapshot, HealthService  # noqa: E402
from app.api.main import ApiDependencies, create_app  # noqa: E402
from app.api.routes.candidates import CandidateReadService  # noqa: E402
from app.api.routes.contracts import SchemaRegistry  # noqa: E402
from app.auth.context import RequestContext  # noqa: E402
from app.auth.resume_token import (  # noqa: E402
    ResumeCapabilityRejected,
    ResumeCapabilityService,
)
from app.persistence.models.behavior import BEHAVIOR_SCHEMA  # noqa: E402
from app.persistence.models.jobs import JobRecord, LeaseRecord  # noqa: E402
from app.persistence.models.runtime import (  # noqa: E402
    CandidateRecord,
    EventRecord,
    IdempotencyRecord,
    JobInputRecord,
    RUNTIME_SCHEMA,
    ResumeCapabilityRow,
    RunRecord,
    RunState,
    ThreadRecord,
)
from app.persistence.repositories.resume_capabilities import (  # noqa: E402
    PostgresResumeCapabilityStore,
)
from app.persistence.repositories.jobs import StaleFence  # noqa: E402
from app.runtime.candidate import (  # noqa: E402
    CandidateProjector,
    ItineraryDay,
    ItineraryItem,
    ValidatedItineraryOutput,
)
from app.runtime.cancellation import CancellationService  # noqa: E402
from app.runtime.behavior_manifest import COMPONENTS, digest_behavior_manifest  # noqa: E402
from app.runtime.behavior_package import RunBehaviorPin  # noqa: E402
from app.runtime.run_start import RunStartService  # noqa: E402
from app.worker.execution import (  # noqa: E402
    ClaimedItineraryJob,
    DurableWorkerExecutor,
    WorkerExecutionState,
)
from app.worker.lease import DurableLeaseCoordinator  # noqa: E402


ALEMBIC_INI = SERVICE_ROOT / "alembic.ini"
TARGET_REVISION = "p10_001_runtime_composition"
VERSION_SCHEMA = "p10_001_runtime_composition_test"
DATABASE_URL = os.environ.get(
    "GONOW_P10_TEST_DATABASE_URL",
    "postgresql+pg8000://gonow_migrator_test@127.0.0.1:55432/gonow_p03_test",
)
ADMIN_DATABASE_URL = (
    "postgresql+pg8000://gonow_bootstrap_admin@127.0.0.1:55432/gonow_p03_test"
)
PRINCIPALS_SQL = SERVICE_ROOT / "tests" / "security" / "fixtures" / "rls_principals.sql"
ROLES = (
    "gonow_agent_api",
    "gonow_agent_worker",
    "gonow_command_service",
    "gonow_release_operator",
    "gonow_observer",
)
TENANT_A = "tenant-p10-runtime-a"
TENANT_B = "tenant-p10-runtime-b"
PRINCIPAL = "principal-p10-runtime"


class ApiSession(Session):
    pass


class WorkerSession(Session):
    pass


@event.listens_for(ApiSession, "after_begin")
def _api_role(session: Session, transaction, connection) -> None:
    del session, transaction
    connection.exec_driver_sql("SET LOCAL ROLE gonow_agent_api")


@event.listens_for(WorkerSession, "after_begin")
def _worker_role(session: Session, transaction, connection) -> None:
    del session, transaction
    connection.exec_driver_sql("SET LOCAL ROLE gonow_agent_worker")


class _NeverUsed:
    def __getattr__(self, name: str):
        raise AssertionError(f"unexpected adapter call: {name}")


class _PinProvider:
    def __init__(self, pin: RunBehaviorPin) -> None:
        self.current = pin

    def pin(self) -> RunBehaviorPin:
        return self.current


class _CandidateProcessor:
    def __init__(self, before_return=None) -> None:
        self._before_return = before_return

    def process(self, job: ClaimedItineraryJob):
        candidate = CandidateProjector().project(
            run_id=str(job.claim.run_id),
            behavior_digest=job.behavior_digest,
            input_digest=job.input_digest,
            output=ValidatedItineraryOutput(
                title="Two-day Hangzhou plan",
                days=(
                    ItineraryDay(
                        day_number=1,
                        items=(
                            ItineraryItem(
                                item_id="item_arrival",
                                title="Arrive and check in",
                                start_minute=600,
                                duration_minutes=90,
                            ),
                        ),
                    ),
                ),
            ),
            citations=(),
        )
        if self._before_return is not None:
            self._before_return(job)
        return candidate


def _pin(seed: str) -> RunBehaviorPin:
    manifest = {
        "schema_version": "1.0",
        "behavior_key": "itinerary.planning",
        "release_version": "1.0.0",
        "components": {
            component: {
                "artifact_ref": f"{component}://sha256/{seed * 64}",
                "sha256": seed * 64,
            }
            for component in COMPONENTS
        },
    }
    digest = digest_behavior_manifest(manifest)
    return RunBehaviorPin(
        release_id=uuid4(),
        behavior_digest=digest.sha256,
        release_version="1.0.0",
        canonical_manifest=digest.canonical_utf8,
        audit_receipt_id=f"audit-pin-{seed}",
    )


def _assert_isolated_database() -> None:
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


def _reset(engine: Engine, config: Config) -> None:
    with engine.begin() as connection:
        connection.execute(DropSchema(BEHAVIOR_SCHEMA, cascade=True, if_exists=True))
        connection.execute(DropSchema(RUNTIME_SCHEMA, cascade=True, if_exists=True))
        connection.execute(DropSchema(VERSION_SCHEMA, cascade=True, if_exists=True))
        connection.execute(CreateSchema(VERSION_SCHEMA))
    command.upgrade(config, TARGET_REVISION)


def _drop_roles(admin_engine: Engine) -> None:
    with admin_engine.begin() as connection:
        for role in ROLES:
            connection.exec_driver_sql(f"DROP OWNED BY {role}")
        for role in ROLES:
            connection.exec_driver_sql(f"DROP ROLE IF EXISTS {role}")


@pytest.fixture()
def runtime_database():
    _assert_isolated_database()
    patch = pytest.MonkeyPatch()
    patch.setenv("GONOW_DATABASE_URL", DATABASE_URL)
    patch.setenv("GONOW_ALEMBIC_VERSION_SCHEMA", VERSION_SCHEMA)
    engine = create_engine(DATABASE_URL, pool_pre_ping=True)
    admin_engine = create_engine(ADMIN_DATABASE_URL, pool_pre_ping=True)
    config = Config(str(ALEMBIC_INI))
    with admin_engine.begin() as connection:
        connection.exec_driver_sql(PRINCIPALS_SQL.read_text(encoding="utf-8"))
    _reset(engine, config)
    api_factory = sessionmaker(
        admin_engine,
        class_=ApiSession,
        expire_on_commit=False,
    )
    worker_factory = sessionmaker(
        admin_engine,
        class_=WorkerSession,
        expire_on_commit=False,
    )
    try:
        yield engine, admin_engine, api_factory, worker_factory
    finally:
        with engine.begin() as connection:
            connection.execute(DropSchema(BEHAVIOR_SCHEMA, cascade=True, if_exists=True))
            connection.execute(DropSchema(RUNTIME_SCHEMA, cascade=True, if_exists=True))
            connection.execute(DropSchema(VERSION_SCHEMA, cascade=True, if_exists=True))
        engine.dispose()
        _drop_roles(admin_engine)
        admin_engine.dispose()
        patch.undo()


def _context(tenant_id: str) -> RequestContext:
    return RequestContext(
        principal_id=PRINCIPAL,
        tenant_id=tenant_id,
        permissions=("run.create", "candidate.read"),
        locale="zh-CN",
        timezone="Asia/Shanghai",
        trace_id=f"trace-{tenant_id}",
    )


async def _context_resolver(request: Request) -> RequestContext:
    token = request.headers.get("authorization", "")
    if token == "Bearer tenant-a-token":
        return _context(TENANT_A)
    if token == "Bearer tenant-b-token":
        return _context(TENANT_B)
    raise RuntimeError("auth fixture rejected")


def _body(thread_id: UUID, *, destination: str = "Hangzhou") -> dict[str, object]:
    return {
        "schema_version": "1.0",
        "thread_id": str(thread_id),
        "itinerary": {
            "schema_version": "1.0",
            "origin": "Shanghai",
            "destination": destination,
            "starts_on": "2026-08-03",
            "days": 2,
            "budget_minor": 200_000,
            "currency": "CNY",
            "locale": "zh-CN",
            "timezone": "Asia/Shanghai",
            "hard_constraints": ["no red-eye travel"],
        },
    }


def _counts(factory: sessionmaker[Session], tenant_id: str) -> dict[str, int]:
    tables = {
        "threads": ThreadRecord,
        "runs": RunRecord,
        "idempotency": IdempotencyRecord,
        "jobs": JobRecord,
        "inputs": JobInputRecord,
        "events": EventRecord,
        "capabilities": ResumeCapabilityRow,
        "candidates": CandidateRecord,
    }
    with factory.begin() as session:
        session.execute(select(func.set_config("app.tenant_id", tenant_id, True)))
        return {
            name: session.scalar(select(func.count()).select_from(model)) or 0
            for name, model in tables.items()
        }


def _app(api_factory: sessionmaker[Session], provider: _PinProvider):
    unused = _NeverUsed()
    dependencies = ApiDependencies(
        health=HealthService(
            lambda: DependencySnapshot(
                jwks_ready=True,
                database_ready=True,
                clock_offset_seconds=0,
            )
        ),
        contracts=SchemaRegistry(REPOSITORY_ROOT / "contracts" / "openapi" / "agent-api.yaml"),
        run_start=RunStartService(api_factory, behavior_pin=provider),
        candidate_read=CandidateReadService(api_factory),
        events=unused,
        resume_capabilities=unused,
        cancellation=unused,
        context_resolver=_context_resolver,
        resume_handler=unused,
        audit_receipt_resolver=unused,
    )
    return create_app(dependencies)


@pytest.mark.asyncio
async def test_http_run_start_is_atomic_idempotent_and_tenant_isolated(
    runtime_database,
) -> None:
    _, _, api_factory, _ = runtime_database
    first_pin = _pin("a")
    provider = _PinProvider(first_pin)
    app = _app(api_factory, provider)
    thread_id = uuid4()
    headers = {
        "Authorization": "Bearer tenant-a-token",
        "Idempotency-Key": "itinerary-start-0001",
        "X-Trace-ID": "request-p10-start",
    }
    async with AsyncClient(
        transport=ASGITransport(app=app),
        base_url="http://test",
    ) as client:
        first = await client.post("/v1/runs", headers=headers, json=_body(thread_id))
        provider.current = _pin("b")
        replay = await client.post("/v1/runs", headers=headers, json=_body(thread_id))
        conflict = await client.post(
            "/v1/runs",
            headers=headers,
            json=_body(thread_id, destination="Suzhou"),
        )
        cross_tenant = await client.post(
            "/v1/runs",
            headers={
                **headers,
                "Authorization": "Bearer tenant-b-token",
                "Idempotency-Key": "itinerary-start-tenant-b",
            },
            json=_body(thread_id),
        )
        invalid = await client.post(
            "/v1/runs",
            headers={**headers, "Idempotency-Key": "short"},
            json=_body(uuid4()),
        )

    assert first.status_code == 202
    assert replay.status_code == 202
    assert first.json()["run_id"] == replay.json()["run_id"]
    assert first.json()["behavior_digest"] == first_pin.behavior_digest
    assert replay.json()["behavior_digest"] == first_pin.behavior_digest
    assert first.json()["replayed"] is False
    assert replay.json()["replayed"] is True
    assert conflict.status_code == 409
    assert conflict.json()["error"]["code"] == "idempotency.conflict"
    assert cross_tenant.status_code == 409
    assert cross_tenant.json()["error"]["code"] == "run.start_rejected"
    assert invalid.status_code == 400
    assert invalid.json()["error"]["code"] == "context.invalid"
    assert _counts(api_factory, TENANT_A) == {
        "threads": 1,
        "runs": 1,
        "idempotency": 1,
        "jobs": 1,
        "inputs": 1,
        "events": 1,
        "capabilities": 0,
        "candidates": 0,
    }
    assert all(value == 0 for value in _counts(api_factory, TENANT_B).values())


def test_resume_capability_survives_restart_and_consumes_once(runtime_database) -> None:
    _, _, api_factory, worker_factory = runtime_database
    provider = _PinProvider(_pin("c"))
    started = RunStartService(api_factory, behavior_pin=provider).start(
        context=_context(TENANT_A),
        thread_id=uuid4(),
        idempotency_key="resume-source-run-0001",
        structured_input=_body(uuid4())["itinerary"],  # type: ignore[arg-type]
    )
    now = [datetime(2026, 8, 2, 12, 0, tzinfo=UTC)]
    interrupt_id = uuid4()
    command_hash = "d" * 64
    issued = ResumeCapabilityService(
        PostgresResumeCapabilityStore(worker_factory),
        clock=lambda: now[0],
        token_factory=lambda: "grc_runtime_restart_fixture",
    ).issue(
        tenant_id=TENANT_A,
        principal_id=PRINCIPAL,
        run_id=started.run_id,
        interrupt_id=interrupt_id,
        command_hash=command_hash,
        command_version="1.0",
        ttl=timedelta(minutes=5),
    )

    restarted = ResumeCapabilityService(
        PostgresResumeCapabilityStore(api_factory),
        clock=lambda: now[0],
    )
    consumed = restarted.consume(
        token=issued.token,
        tenant_id=TENANT_A,
        principal_id=PRINCIPAL,
        run_id=started.run_id,
        interrupt_id=interrupt_id,
        command_hash=command_hash,
        command_version="1.0",
    )
    with pytest.raises(ResumeCapabilityRejected):
        restarted.consume(
            token=issued.token,
            tenant_id=TENANT_A,
            principal_id=PRINCIPAL,
            run_id=started.run_id,
            interrupt_id=interrupt_id,
            command_hash=command_hash,
            command_version="1.0",
        )
    assert consumed.consumed_at == now[0]
    with api_factory.begin() as session:
        session.execute(select(func.set_config("app.tenant_id", TENANT_A, True)))
        row = session.scalar(
            select(ResumeCapabilityRow).where(
                ResumeCapabilityRow.capability_id == issued.capability_id
            )
        )
        assert row is not None
        assert row.token_hash != issued.token
        assert issued.token not in json.dumps(
            {
                "token_hash": row.token_hash,
                "command_hash": row.command_hash,
                "command_version": row.command_version,
            }
        )
    assert _counts(api_factory, TENANT_B)["capabilities"] == 0


def test_new_tables_are_forced_rls_with_least_privilege(runtime_database) -> None:
    _, admin_engine, _, _ = runtime_database
    with admin_engine.begin() as connection:
        flags = connection.execute(
            text(
                "SELECT relname, relrowsecurity, relforcerowsecurity "
                "FROM pg_class JOIN pg_namespace ON pg_namespace.oid = relnamespace "
                "WHERE nspname = 'agent_runtime' "
                "AND relname IN ('job_inputs', 'resume_capabilities', 'candidates')"
            )
        ).all()
        privileges = connection.execute(
            text(
                "SELECT "
                "has_table_privilege('gonow_agent_api', 'agent_runtime.job_inputs', 'INSERT'), "
                "has_table_privilege('gonow_agent_api', 'agent_runtime.resume_capabilities', 'UPDATE'), "
                "has_table_privilege('gonow_agent_worker', 'agent_runtime.resume_capabilities', 'INSERT'), "
                "has_table_privilege('gonow_agent_worker', 'agent_runtime.resume_capabilities', 'UPDATE'), "
                "has_table_privilege('gonow_agent_worker', 'agent_runtime.candidates', 'INSERT'), "
                "has_table_privilege('gonow_agent_api', 'agent_runtime.candidates', 'INSERT')"
            )
        ).one()
    assert sorted(flags) == [
        ("candidates", True, True),
        ("job_inputs", True, True),
        ("resume_capabilities", True, True),
    ]
    assert tuple(privileges) == (True, True, True, False, True, False)


@pytest.mark.asyncio
async def test_worker_claim_persists_candidate_and_converges_terminal(runtime_database) -> None:
    _, _, api_factory, worker_factory = runtime_database
    provider = _PinProvider(_pin("e"))
    started = RunStartService(
        api_factory,
        behavior_pin=provider,
    ).start(
        context=_context(TENANT_A),
        thread_id=uuid4(),
        idempotency_key="worker-success-source-0001",
        structured_input=_body(uuid4())["itinerary"],  # type: ignore[arg-type]
    )
    executor = DurableWorkerExecutor(
        worker_factory,
        processor=_CandidateProcessor(),
    )
    result = executor.execute_once(
        tenant_id=TENANT_A,
        holder_id="worker-p10-success",
        audit_receipt_id="audit-worker-p10-success",
    )
    replay = executor.execute_once(
        tenant_id=TENANT_A,
        holder_id="worker-p10-success-replay",
        audit_receipt_id="audit-worker-p10-success-replay",
    )
    with worker_factory.begin() as session:
        session.execute(select(func.set_config("app.tenant_id", TENANT_A, True)))
        run = session.scalar(select(RunRecord).where(RunRecord.run_id == started.run_id))
        job = session.scalar(select(JobRecord).where(JobRecord.run_id == started.run_id))
        candidate = session.scalar(
            select(CandidateRecord).where(CandidateRecord.run_id == started.run_id)
        )
        events = session.scalars(
            select(EventRecord)
            .where(EventRecord.run_id == started.run_id)
            .order_by(EventRecord.seq)
        ).all()
    assert result.state is WorkerExecutionState.SUCCEEDED
    assert result.candidate_ref is not None
    assert replay.state is WorkerExecutionState.EMPTY
    assert run is not None and run.state == RunState.SUCCEEDED.value
    assert job is not None and job.status == "completed"
    assert candidate is not None and candidate.candidate_ref == result.candidate_ref
    assert [record.event_type for record in events] == [
        "run.created",
        "step.started",
        "candidate.ready",
        "run.succeeded",
    ]
    app = _app(api_factory, provider)
    async with AsyncClient(
        transport=ASGITransport(app=app),
        base_url="http://test",
    ) as client:
        owner = await client.get(
            f"/v1/runs/{started.run_id}/candidate",
            headers={"Authorization": "Bearer tenant-a-token"},
        )
        other_tenant = await client.get(
            f"/v1/runs/{started.run_id}/candidate",
            headers={"Authorization": "Bearer tenant-b-token"},
        )
    assert owner.status_code == 200
    assert owner.json()["candidate_id"] == candidate.candidate_id
    assert other_tenant.status_code == 403
    assert other_tenant.json()["error"]["code"] == "auth.forbidden"


def test_cancel_at_worker_boundary_discards_candidate(runtime_database) -> None:
    _, _, api_factory, worker_factory = runtime_database
    started = RunStartService(
        api_factory,
        behavior_pin=_PinProvider(_pin("f")),
    ).start(
        context=_context(TENANT_A),
        thread_id=uuid4(),
        idempotency_key="worker-cancel-source-0001",
        structured_input=_body(uuid4())["itinerary"],  # type: ignore[arg-type]
    )

    def request_cancel(job: ClaimedItineraryJob) -> None:
        with api_factory.begin() as session:
            session.execute(select(func.set_config("app.tenant_id", TENANT_A, True)))
            run = session.scalar(
                select(RunRecord).where(RunRecord.run_id == job.claim.run_id)
            )
            assert run is not None
            version = run.version
        CancellationService(api_factory).request_cancel(
            tenant_id=TENANT_A,
            principal_id=PRINCIPAL,
            run_id=job.claim.run_id,
            expected_version=version,
            audit_receipt_id="audit-worker-cancel-request",
        )

    result = DurableWorkerExecutor(
        worker_factory,
        processor=_CandidateProcessor(before_return=request_cancel),
    ).execute_once(
        tenant_id=TENANT_A,
        holder_id="worker-p10-cancel",
        audit_receipt_id="audit-worker-p10-cancel",
    )
    with worker_factory.begin() as session:
        session.execute(select(func.set_config("app.tenant_id", TENANT_A, True)))
        run = session.scalar(select(RunRecord).where(RunRecord.run_id == started.run_id))
        candidate_count = session.scalar(
            select(func.count())
            .select_from(CandidateRecord)
            .where(CandidateRecord.run_id == started.run_id)
        )
    assert result.state is WorkerExecutionState.CANCELLED
    assert run is not None and run.state == RunState.CANCELLED.value
    assert candidate_count == 0


def test_reclaimed_fence_rejects_old_worker_candidate_and_terminal(runtime_database) -> None:
    _, _, api_factory, worker_factory = runtime_database
    started = RunStartService(
        api_factory,
        behavior_pin=_PinProvider(_pin("1")),
    ).start(
        context=_context(TENANT_A),
        thread_id=uuid4(),
        idempotency_key="worker-fence-source-0001",
        structured_input=_body(uuid4())["itinerary"],  # type: ignore[arg-type]
    )
    reclaimed = []

    def expire_and_reclaim(job: ClaimedItineraryJob) -> None:
        with worker_factory.begin() as session:
            session.execute(select(func.set_config("app.tenant_id", TENANT_A, True)))
            changed = session.execute(
                update(LeaseRecord)
                .where(
                    LeaseRecord.job_id == job.claim.job_id,
                    LeaseRecord.fencing_token == job.claim.fencing_token,
                    LeaseRecord.released_at.is_(None),
                )
                .values(
                    acquired_at=func.statement_timestamp() - timedelta(seconds=3),
                    heartbeat_at=func.statement_timestamp() - timedelta(seconds=2),
                    expires_at=func.statement_timestamp() - timedelta(seconds=1),
                )
            ).rowcount
            assert changed == 1
        next_claim = DurableLeaseCoordinator(worker_factory).reclaim_once(
            tenant_id=TENANT_A,
            holder_id="worker-p10-new",
            audit_receipt_id="audit-worker-p10-reclaim",
        )
        assert next_claim is not None
        reclaimed.append(next_claim)

    with pytest.raises(StaleFence):
        DurableWorkerExecutor(
            worker_factory,
            processor=_CandidateProcessor(before_return=expire_and_reclaim),
        ).execute_once(
            tenant_id=TENANT_A,
            holder_id="worker-p10-old",
            audit_receipt_id="audit-worker-p10-old",
        )
    with worker_factory.begin() as session:
        session.execute(select(func.set_config("app.tenant_id", TENANT_A, True)))
        before = session.scalar(
            select(func.count())
            .select_from(CandidateRecord)
            .where(CandidateRecord.run_id == started.run_id)
        )
        run = session.scalar(select(RunRecord).where(RunRecord.run_id == started.run_id))
    assert before == 0
    assert run is not None and run.state == RunState.RUNNING.value
    assert reclaimed[0].fencing_token == 2

    recovered = DurableWorkerExecutor(
        worker_factory,
        processor=_CandidateProcessor(),
    ).execute_once(
        tenant_id=TENANT_A,
        holder_id="worker-p10-new",
        audit_receipt_id="audit-worker-p10-new",
    )
    assert recovered.state is WorkerExecutionState.SUCCEEDED
    with worker_factory.begin() as session:
        session.execute(select(func.set_config("app.tenant_id", TENANT_A, True)))
        after = session.scalar(
            select(func.count())
            .select_from(CandidateRecord)
            .where(CandidateRecord.run_id == started.run_id)
        )
        terminal = session.scalar(
            select(RunRecord).where(RunRecord.run_id == started.run_id)
        )
    assert after == 1
    assert terminal is not None and terminal.state == RunState.SUCCEEDED.value
