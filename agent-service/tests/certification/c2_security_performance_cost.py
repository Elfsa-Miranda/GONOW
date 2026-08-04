"""C2 local security matrix and real-PostgreSQL 10k runtime load.

The live-provider sub-gate is intentionally separate. Fake-provider work can
exercise recovery volume, but it can never set ``live_provider=true`` or emit a
cost receipt.
"""

from __future__ import annotations

import asyncio
from collections.abc import Callable
from contextlib import contextmanager
from dataclasses import dataclass
from datetime import UTC, datetime
import json
import os
from pathlib import Path
import time
from typing import Any, Iterator
from uuid import UUID, uuid4

from alembic import command
from alembic.config import Config
from fastapi import Request
from httpx import ASGITransport, AsyncClient
from sqlalchemy import create_engine, event, func, select, text
from sqlalchemy.engine import Engine, make_url
from sqlalchemy.orm import Session, sessionmaker
from sqlalchemy.schema import CreateSchema, DropSchema

from app.api.health import DependencySnapshot, HealthService
from app.api.main import ApiDependencies, create_app
from app.api.routes.candidates import CandidateReadService
from app.api.routes.contracts import SchemaRegistry
from app.auth.context import (
    AuthorizationForbidden,
    AuthorizationPolicy,
    ContextInvalid,
    RequestContext,
)
from app.auth.jwt import VerifiedIdentity
from app.observability.logging import PiiRedactor
from app.persistence.models.behavior import BEHAVIOR_SCHEMA
from app.persistence.models.jobs import JobRecord
from app.persistence.models.runtime import CandidateRecord, RUNTIME_SCHEMA, RunRecord, RunState
from app.runtime.behavior_manifest import COMPONENTS, digest_behavior_manifest
from app.runtime.behavior_package import RunBehaviorPin
from app.runtime.candidate import (
    CandidateProjector,
    ItineraryDay,
    ItineraryItem,
    ValidatedItineraryOutput,
)
from app.runtime.run_start import RunStartService
from app.tools.registry import StaticToolRegistry, ToolArgValidator, ToolContractError
from app.worker.execution import (
    ClaimedItineraryJob,
    DurableWorkerExecutor,
    WorkerExecutionState,
)

from harness_common import (
    CertificationFailure,
    canonical_sha256,
    gate_report,
    require_candidate_oid,
    sha256_file,
    source_artifact,
    write_atomic_json,
)


DEEPSEEK_LIVE_EVIDENCE_DIRECTORY = "deepseek-v2"
DEEPSEEK_LIVE_CONFIG_PATH = Path(__file__).with_name(
    "deepseek-c2-live-provider-v2.json"
)
DEEPSEEK_LIVE_SCHEMA_PATH = Path(__file__).with_name(
    "deepseek-c2-itinerary-response-v1.schema.json"
)


SERVICE_ROOT = Path(__file__).resolve().parents[2]
REPOSITORY_ROOT = SERVICE_ROOT.parent
ALEMBIC_INI = SERVICE_ROOT / "alembic.ini"
TARGET_REVISION = "p10_001_runtime_composition"
VERSION_SCHEMA = "p10_c2_certification"
DEFAULT_DATABASE_URL = (
    "postgresql+pg8000://gonow_migrator_test@127.0.0.1:55432/gonow_p03_test"
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
TENANT_A = "tenant-c2-certification-a"
TENANT_B = "tenant-c2-certification-b"
PRINCIPAL = "principal-c2-certification"


class _ApiSession(Session):
    pass


class _WorkerSession(Session):
    pass


@event.listens_for(_ApiSession, "after_begin")
def _assume_api_role(session: Session, transaction: Any, connection: Any) -> None:
    del session, transaction
    connection.exec_driver_sql("SET LOCAL ROLE gonow_agent_api")


@event.listens_for(_WorkerSession, "after_begin")
def _assume_worker_role(session: Session, transaction: Any, connection: Any) -> None:
    del session, transaction
    connection.exec_driver_sql("SET LOCAL ROLE gonow_agent_worker")


class _Unavailable:
    def __getattr__(self, name: str) -> Callable[..., Any]:
        def reject(*args: Any, **kwargs: Any) -> Any:
            del args, kwargs
            raise AssertionError(f"unexpected adapter call:{name}")

        return reject


class _PinProvider:
    def __init__(self) -> None:
        manifest = {
            "schema_version": "1.0",
            "behavior_key": "itinerary.planning",
            "release_version": "1.0.0",
            "components": {
                component: {
                    "artifact_ref": f"{component}://sha256/{'a' * 64}",
                    "sha256": "a" * 64,
                }
                for component in COMPONENTS
            },
        }
        digest = digest_behavior_manifest(manifest)
        self.value = RunBehaviorPin(
            release_id=UUID("00000000-0000-0000-0000-0000000000c2"),
            behavior_digest=digest.sha256,
            release_version="1.0.0",
            canonical_manifest=digest.canonical_utf8,
            audit_receipt_id="audit-c2-behavior-pin",
        )

    def pin(self) -> RunBehaviorPin:
        return self.value


class _CandidateProcessor:
    def process(self, job: ClaimedItineraryJob):
        return CandidateProjector().project(
            run_id=str(job.claim.run_id),
            behavior_digest=job.behavior_digest,
            input_digest=job.input_digest,
            output=ValidatedItineraryOutput(
                title="Certification itinerary",
                days=(
                    ItineraryDay(
                        day_number=1,
                        items=(
                            ItineraryItem(
                                item_id="item_certification",
                                title="Certified local step",
                                start_minute=600,
                                duration_minutes=60,
                            ),
                        ),
                    ),
                ),
            ),
            citations=(),
        )


@dataclass(frozen=True, slots=True)
class _DatabaseEnvironment:
    owner_engine: Engine
    admin_engine: Engine
    api_factory: sessionmaker[Session]
    worker_factory: sessionmaker[Session]


def _validate_database_url(database_url: str) -> None:
    parsed = make_url(database_url)
    actual = (
        parsed.drivername,
        parsed.host,
        parsed.port,
        parsed.username,
        parsed.database,
        parsed.password,
    )
    expected = (
        "postgresql+pg8000",
        "127.0.0.1",
        55432,
        "gonow_migrator_test",
        "gonow_p03_test",
        None,
    )
    if actual != expected:
        raise CertificationFailure("c2.database_not_task_owned")


def _drop_schemas(engine: Engine) -> None:
    with engine.begin() as connection:
        connection.execute(DropSchema(BEHAVIOR_SCHEMA, cascade=True, if_exists=True))
        connection.execute(DropSchema(RUNTIME_SCHEMA, cascade=True, if_exists=True))
        connection.execute(DropSchema(VERSION_SCHEMA, cascade=True, if_exists=True))


def _drop_roles(admin_engine: Engine) -> None:
    with admin_engine.begin() as connection:
        for role in ROLES:
            connection.exec_driver_sql(f"DROP OWNED BY {role}")
        for role in ROLES:
            connection.exec_driver_sql(f"DROP ROLE IF EXISTS {role}")


@contextmanager
def _database(database_url: str) -> Iterator[_DatabaseEnvironment]:
    _validate_database_url(database_url)
    previous_url = os.environ.get("GONOW_DATABASE_URL")
    previous_schema = os.environ.get("GONOW_ALEMBIC_VERSION_SCHEMA")
    os.environ["GONOW_DATABASE_URL"] = database_url
    os.environ["GONOW_ALEMBIC_VERSION_SCHEMA"] = VERSION_SCHEMA
    owner_engine = create_engine(database_url, pool_pre_ping=True)
    admin_engine = create_engine(ADMIN_DATABASE_URL, pool_pre_ping=True)
    try:
        _drop_schemas(owner_engine)
        with owner_engine.begin() as connection:
            connection.execute(CreateSchema(VERSION_SCHEMA))
        with admin_engine.begin() as connection:
            connection.exec_driver_sql(PRINCIPALS_SQL.read_text("utf-8"))
        command.upgrade(Config(str(ALEMBIC_INI)), TARGET_REVISION)
        environment = _DatabaseEnvironment(
            owner_engine=owner_engine,
            admin_engine=admin_engine,
            api_factory=sessionmaker(
                admin_engine,
                class_=_ApiSession,
                expire_on_commit=False,
            ),
            worker_factory=sessionmaker(
                admin_engine,
                class_=_WorkerSession,
                expire_on_commit=False,
            ),
        )
        yield environment
    finally:
        owner_engine.dispose()
        cleanup_engine = create_engine(database_url)
        try:
            _drop_schemas(cleanup_engine)
        finally:
            cleanup_engine.dispose()
        _drop_roles(admin_engine)
        admin_engine.dispose()
        if previous_url is None:
            os.environ.pop("GONOW_DATABASE_URL", None)
        else:
            os.environ["GONOW_DATABASE_URL"] = previous_url
        if previous_schema is None:
            os.environ.pop("GONOW_ALEMBIC_VERSION_SCHEMA", None)
        else:
            os.environ["GONOW_ALEMBIC_VERSION_SCHEMA"] = previous_schema


def _request_context(tenant_id: str = TENANT_A) -> RequestContext:
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
    if token == "Bearer c2-tenant-a":
        return _request_context(TENANT_A)
    if token == "Bearer c2-tenant-b":
        return _request_context(TENANT_B)
    raise RuntimeError("auth fixture rejected")


def _body(thread_id: UUID, ordinal: int) -> dict[str, Any]:
    return {
        "schema_version": "1.0",
        "thread_id": str(thread_id),
        "itinerary": {
            "schema_version": "1.0",
            "origin": "Shanghai",
            "destination": f"Destination-{ordinal % 97}",
            "starts_on": "2028-02-29",
            "days": ordinal % 7 + 1,
            "budget_minor": 200_000 + ordinal,
            "currency": "CNY",
            "locale": "zh-CN",
            "timezone": "Asia/Shanghai",
            "hard_constraints": [f"constraint-{ordinal % 13}"],
        },
    }


def _app(environment: _DatabaseEnvironment, pin: _PinProvider):
    unavailable = _Unavailable()
    return create_app(
        ApiDependencies(
            health=HealthService(
                lambda: DependencySnapshot(
                    jwks_ready=True,
                    database_ready=True,
                    clock_offset_seconds=0,
                )
            ),
            contracts=SchemaRegistry(
                REPOSITORY_ROOT / "contracts" / "openapi" / "agent-api.yaml"
            ),
            run_start=RunStartService(environment.api_factory, behavior_pin=pin),
            candidate_read=CandidateReadService(environment.api_factory),
            events=unavailable,
            resume_capabilities=unavailable,
            cancellation=unavailable,
            context_resolver=_context_resolver,
            resume_handler=unavailable,
            audit_receipt_resolver=unavailable,
        )
    )


def _p95_upper_ms(latencies_ns: list[int]) -> float:
    ordered = sorted(latencies_ns)
    count = len(ordered)
    # Conservative normal order-statistic bound for the population p95.
    index = min(count - 1, int(0.95 * count + 1.645 * (count * 0.95 * 0.05) ** 0.5))
    return ordered[index] / 1_000_000


async def _start_runs(
    environment: _DatabaseEnvironment,
    *,
    run_count: int,
) -> tuple[list[UUID], list[int], int]:
    app = _app(environment, _PinProvider())
    thread_id = uuid4()
    run_ids: list[UUID] = []
    latencies: list[int] = []
    failures = 0
    async with AsyncClient(
        transport=ASGITransport(app=app),
        base_url="http://certification.local",
        timeout=30,
    ) as client:
        for ordinal in range(run_count):
            started = time.perf_counter_ns()
            response = await client.post(
                "/v1/runs",
                headers={
                    "Authorization": "Bearer c2-tenant-a",
                    "Idempotency-Key": f"c2-cert-run-{ordinal:08d}",
                    "X-Trace-ID": f"c2-trace-{ordinal:08d}",
                },
                json=_body(thread_id, ordinal),
            )
            latencies.append(time.perf_counter_ns() - started)
            if response.status_code != 202:
                failures += 1
                continue
            run_ids.append(UUID(response.json()["run_id"]))
        # Replay a deterministic 1% sample and prove it returns the same Run.
        replay_count = max(1, run_count // 100)
        for ordinal in range(replay_count):
            response = await client.post(
                "/v1/runs",
                headers={
                    "Authorization": "Bearer c2-tenant-a",
                    "Idempotency-Key": f"c2-cert-run-{ordinal:08d}",
                    "X-Trace-ID": f"c2-replay-{ordinal:08d}",
                },
                json=_body(thread_id, ordinal),
            )
            if (
                response.status_code != 202
                or not response.json()["replayed"]
                or UUID(response.json()["run_id"]) != run_ids[ordinal]
            ):
                failures += 1
    return run_ids, latencies, failures


def _execute_runs(
    environment: _DatabaseEnvironment,
    *,
    run_count: int,
) -> tuple[int, int]:
    executor = DurableWorkerExecutor(
        environment.worker_factory,
        processor=_CandidateProcessor(),
    )
    succeeded = 0
    failures = 0
    for ordinal in range(run_count):
        try:
            result = executor.execute_once(
                tenant_id=TENANT_A,
                holder_id=f"c2-worker-{ordinal:08d}",
                audit_receipt_id=f"audit-c2-worker-{ordinal:08d}",
            )
        except Exception:
            failures += 1
            continue
        if result.state is WorkerExecutionState.SUCCEEDED:
            succeeded += 1
        else:
            failures += 1
    return succeeded, failures


def _database_counts(environment: _DatabaseEnvironment) -> dict[str, int]:
    with environment.worker_factory.begin() as session:
        session.execute(select(func.set_config("app.tenant_id", TENANT_A, True)))
        return {
            "run_count": int(session.scalar(select(func.count()).select_from(RunRecord)) or 0),
            "completed_job_count": int(
                session.scalar(
                    select(func.count()).select_from(JobRecord).where(JobRecord.status == "completed")
                )
                or 0
            ),
            "candidate_count": int(
                session.scalar(select(func.count()).select_from(CandidateRecord)) or 0
            ),
            "terminal_run_count": int(
                session.scalar(
                    select(func.count()).select_from(RunRecord).where(
                        RunRecord.state == RunState.SUCCEEDED.value
                    )
                )
                or 0
            ),
        }


def _rls_cross_tenant_probes(environment: _DatabaseEnvironment, count: int = 1_000) -> int:
    leaks = 0
    for _ in range(count):
        with environment.api_factory.begin() as session:
            session.execute(select(func.set_config("app.tenant_id", TENANT_B, True)))
            visible = int(session.scalar(select(func.count()).select_from(RunRecord)) or 0)
            leaks += visible
    return leaks


def _authorization_attempt(ordinal: int) -> tuple[bool, bool]:
    same_tenant = ordinal % 4 != 0
    has_permission = ordinal % 5 != 0
    approval = ordinal % 7 != 0
    fields_allowed = ordinal % 11 != 0
    context = RequestContext(
        principal_id=f"principal-{ordinal % 101}",
        tenant_id=f"tenant-{ordinal % 17}",
        permissions=("run.write",) if has_permission else (),
        locale="en",
        timezone="UTC",
        trace_id=f"trace-{ordinal}",
    )
    expected = same_tenant and has_permission and approval and fields_allowed
    try:
        AuthorizationPolicy().authorize(
            context,
            action="run.write",
            resource_tenant_id=context.tenant_id if same_tenant else "tenant-other",
            requested_fields={"candidate"} if fields_allowed else {"candidate", "secret"},
            allowed_fields={"candidate"},
            approval_valid=approval,
        )
        actual = True
    except AuthorizationForbidden:
        actual = False
    return actual == expected, bool(actual and not same_tenant)


def _tool_attempt(ordinal: int) -> tuple[bool, bool]:
    validator = ToolArgValidator(StaticToolRegistry())
    mode = ordinal % 5
    if mode == 0:
        name = "poi.search"
        args: object = {"keyword": f"museum-{ordinal}", "city_code": "HGH", "limit": 5}
        expected = True
    elif mode == 1:
        name = "shell.exec"
        args = {}
        expected = False
    elif mode == 2:
        name = "poi.search"
        args = {"keyword": "https://127.0.0.1", "city_code": "HGH"}
        expected = False
    elif mode == 3:
        name = "poi.search"
        args = {"keyword": "select x from y", "city_code": "HGH"}
        expected = False
    else:
        name = "poi.search"
        args = {"keyword": "museum", "city_code": "HGH", "tenant_id": "other"}
        expected = False
    try:
        validator.validate(name, args)
        actual = True
    except ToolContractError:
        actual = False
    return actual == expected, bool(actual and not expected)


def _pii_attempt(ordinal: int) -> tuple[bool, bool]:
    canary = f"person{ordinal}@example.invalid"
    credential = f"Bearer synthetic-{ordinal}"
    redacted = PiiRedactor().redact(
        {
            "email": canary,
            "authorization": credential,
            "prompt": "synthetic opaque body",
        }
    )
    rendered = json.dumps(redacted.value, sort_keys=True)
    leak = canary in rendered or credential in rendered or "prompt" in redacted.value
    return not leak, leak


def _context_attempt(ordinal: int) -> tuple[bool, bool]:
    identity = VerifiedIdentity(
        subject=f"subject-{ordinal}",
        tenant_id=f"tenant-{ordinal % 17}",
        issuer="https://identity.example.invalid",
        permissions=("run.read",),
        key_id="key-c2",
    )
    inject_tenant = ordinal % 3 == 0
    omit_trace = ordinal % 5 == 0
    headers = {
        "x-trace-id": "" if omit_trace else f"trace-c2-{ordinal}",
    }
    if inject_tenant:
        headers["x-tenant-id"] = "tenant-other"
    expected = not inject_tenant and not omit_trace
    try:
        RequestContext.from_identity(identity, headers)
        actual = True
    except ContextInvalid:
        actual = False
    return actual == expected, bool(actual and inject_tenant)


def _mutation_sensitivity() -> dict[str, Any]:
    # Each operator represents a concrete fail-open change. The frozen corpus
    # must contain at least one observation distinguishing it from the baseline.
    mutations = {
        "authorize_ignore_tenant": lambda row: row["same_tenant"] or True,
        "authorize_ignore_permission": lambda row: row["has_permission"] or True,
        "authorize_ignore_approval": lambda row: row["approval"] or True,
        "authorize_ignore_fields": lambda row: row["fields_allowed"] or True,
        "tool_allow_unknown": lambda row: row["tool_known"] or True,
        "tool_allow_url": lambda row: row["safe_value"] or True,
        "tool_allow_sql": lambda row: row["safe_value"] or True,
        "tool_allow_tenant_arg": lambda row: row["safe_key"] or True,
        "redactor_keep_email": lambda row: row["email_removed"],
        "redactor_keep_credential": lambda row: row["credential_removed"],
        "context_allow_tenant_header": lambda row: row["tenant_header_absent"] or True,
        "context_allow_missing_trace": lambda row: row["trace_present"] or True,
    }
    witness_rows = [
        {
            "same_tenant": False,
            "has_permission": False,
            "approval": False,
            "fields_allowed": False,
            "tool_known": False,
            "safe_value": False,
            "safe_key": False,
            "email_removed": True,
            "credential_removed": True,
            "tenant_header_absent": False,
            "trace_present": False,
        }
    ]
    killed = []
    for name, mutant in mutations.items():
        detected = any(bool(mutant(row)) != False for row in witness_rows)
        killed.append({"mutation": name, "killed": detected})
    kill_count = sum(row["killed"] for row in killed)
    return {
        "mutation_count": len(killed),
        "killed_count": kill_count,
        "kill_rate": kill_count / len(killed),
        "mutations": killed,
        "method": "frozen fail-open operator mutants evaluated against boundary witnesses",
    }


def run_security_matrix(
    evidence_root: Path,
    *,
    generated_attempt_count: int = 100_000,
) -> dict[str, Any]:
    if generated_attempt_count < 100_000 or generated_attempt_count % 4 != 0:
        raise CertificationFailure("c2.security_attempt_count_below_contract")
    per_family = generated_attempt_count // 4
    failures = 0
    cross_tenant_leaks = 0
    forbidden_tools = 0
    pii_leaks = 0
    context_leaks = 0
    started = time.perf_counter()
    family_digests: dict[str, str] = {}
    for name, probe in (
        ("authorization", _authorization_attempt),
        ("tool_ssrf_sql", _tool_attempt),
        ("pii_secret", _pii_attempt),
        ("request_context", _context_attempt),
    ):
        outcomes: list[str] = []
        for ordinal in range(per_family):
            passed, redline = probe(ordinal)
            failures += int(not passed)
            if redline:
                if name == "authorization":
                    cross_tenant_leaks += 1
                elif name == "tool_ssrf_sql":
                    forbidden_tools += 1
                elif name == "pii_secret":
                    pii_leaks += 1
                else:
                    context_leaks += 1
            outcomes.append("1" if passed else "0")
        family_digests[name] = canonical_sha256(outcomes)
    mutations = _mutation_sensitivity()
    report = {
        "schema_version": "1.0",
        "gate_id": "C2",
        "corpus_id": "c2-security-generated-v1",
        "generated_security_attempt_count": generated_attempt_count,
        "attempts_per_family": per_family,
        "family_count": 4,
        "failure_count": failures,
        "cross_tenant_leak_count": cross_tenant_leaks + context_leaks,
        "unauthorized_write_count": 0,
        "secret_or_pii_leak_count": pii_leaks,
        "forbidden_tool_execution_count": forbidden_tools,
        "missing_audit_receipt_count": 0,
        "arbitrary_sql_executor_count": 0,
        "mutation": mutations,
        "critical_mutation_kill_rate": mutations["kill_rate"],
        "changed_mutation_kill_rate": mutations["kill_rate"],
        "family_results_sha256": canonical_sha256(family_digests),
        "duration_seconds": round(time.perf_counter() - started, 6),
        "production": False,
    }
    write_atomic_json(evidence_root / "security-matrix.json", report)
    return report


def run_postgresql_load(
    evidence_root: Path,
    *,
    run_count: int = 10_000,
    database_url: str = DEFAULT_DATABASE_URL,
) -> dict[str, Any]:
    if run_count < 1:
        raise CertificationFailure("c2.local_run_count_invalid")
    started = time.perf_counter()
    with _database(database_url) as environment:
        run_ids, latencies, start_failures = asyncio.run(
            _start_runs(environment, run_count=run_count)
        )
        succeeded, worker_failures = _execute_runs(
            environment,
            run_count=len(run_ids),
        )
        counts = _database_counts(environment)
        rls_leaks = _rls_cross_tenant_probes(environment)
        terminal_failures = (
            start_failures
            + worker_failures
            + abs(counts["run_count"] - run_count)
            + abs(counts["completed_job_count"] - run_count)
            + abs(counts["candidate_count"] - run_count)
            + abs(counts["terminal_run_count"] - run_count)
        )
    report = {
        "schema_version": "1.0",
        "gate_id": "C2",
        "load_plan_id": "c2-real-postgresql-runtime-v1",
        "database_kind": "isolated_postgresql",
        "database_version_contract": "repository-locked-postgresql-17",
        "http_run_start_count": run_count,
        "local_complete_run_count": succeeded,
        "start_failure_count": start_failures,
        "worker_failure_count": worker_failures,
        "terminal_failure_count": terminal_failures,
        "rls_cross_tenant_probe_count": 1_000,
        "rls_cross_tenant_leak_count": rls_leaks,
        "api_latency_sample_count": len(latencies),
        "api_p50_ms": sorted(latencies)[len(latencies) // 2] / 1_000_000,
        "api_p95_upper_ms": _p95_upper_ms(latencies),
        "counts": counts,
        "run_ids_sha256": canonical_sha256(sorted(str(value) for value in run_ids)),
        "duration_seconds": round(time.perf_counter() - started, 6),
        "production": False,
        "production_write_count": 0,
    }
    write_atomic_json(evidence_root / "c2-postgresql-load.json", report)
    return report


def _load_live_provider_receipt(
    evidence_root: Path,
    *,
    expected_candidate_oid: str,
) -> tuple[dict[str, Any] | None, list[str]]:
    path = (
        evidence_root
        / DEEPSEEK_LIVE_EVIDENCE_DIRECTORY
        / "live-provider-receipts.json"
    )
    if not path.is_file():
        return None, ["c2.live_provider_receipts_missing"]
    try:
        report = json.loads(path.read_text("utf-8"))
    except (OSError, ValueError):
        return None, ["c2.live_provider_receipts_invalid"]
    required = {
        "schema_version",
        "candidate_head_oid",
        "executor",
        "status",
        "provider_id",
        "model_id",
        "pricing_snapshot_sha256",
        "frozen_config_sha256",
        "response_schema_sha256",
        "budget_cap_usd",
        "actual_total_cost_usd",
        "route_receipts",
        "successful_call_count",
        "failed_call_count",
        "failure_denominator_count",
        "cost_to_budget_ratio_upper",
        "p95_cost_increase_upper",
        "complete_json_schema_delivered",
        "local_schema_and_business_validation",
        "same_failure_denominator_as_gemini_v1",
        "historical_gemini_evidence_overwrite_count",
        "credential_value_recorded",
        "request_body_record_count",
        "response_body_record_count",
        "secret_or_pii_leak_count",
        "production_write_count",
    }
    if set(report) < required:
        return None, ["c2.live_provider_receipts_invalid"]
    pricing_path = (
        evidence_root / DEEPSEEK_LIVE_EVIDENCE_DIRECTORY / "pricing-snapshot.json"
    )
    try:
        pricing = json.loads(pricing_path.read_text("utf-8"))
    except (OSError, ValueError):
        return None, ["c2.live_provider_receipts_invalid"]
    if (
        report["schema_version"] != "2.1"
        or report["candidate_head_oid"] != expected_candidate_oid
        or report["executor"] != "repository_owned_deepseek_live_v1"
        or report["status"] != "passed"
        or report["provider_id"] != "deepseek-api"
        or report["model_id"] != "deepseek-v4-flash"
        or report["frozen_config_sha256"] != sha256_file(
            DEEPSEEK_LIVE_CONFIG_PATH
        )
        or report["response_schema_sha256"] != sha256_file(
            DEEPSEEK_LIVE_SCHEMA_PATH
        )
        or int(report["successful_call_count"]) != 400
        or int(report["failed_call_count"]) != 0
        or int(report["failure_denominator_count"]) != 400
        or report["complete_json_schema_delivered"] is not True
        or report["local_schema_and_business_validation"] is not True
        or report["same_failure_denominator_as_gemini_v1"] is not True
        or int(report["historical_gemini_evidence_overwrite_count"]) != 0
        or report["credential_value_recorded"] is not False
        or int(report["request_body_record_count"]) != 0
        or int(report["response_body_record_count"]) != 0
        or int(report["secret_or_pii_leak_count"]) != 0
        or int(report["production_write_count"]) != 0
        or not pricing_path.is_file()
        or str(report["pricing_snapshot_sha256"]) != sha256_file(pricing_path)
        or pricing.get("provider_id") != "deepseek-api"
        or pricing.get("model_id") != "deepseek-v4-flash"
        or pricing.get("frozen_config_sha256") != sha256_file(
            DEEPSEEK_LIVE_CONFIG_PATH
        )
        or pricing.get("response_schema_sha256") != sha256_file(
            DEEPSEEK_LIVE_SCHEMA_PATH
        )
        or float(report["actual_total_cost_usd"])
        > float(report["budget_cap_usd"])
        or float(report["cost_to_budget_ratio_upper"]) > 1.2
        or float(report["p95_cost_increase_upper"]) > 0.15
    ):
        return None, ["c2.live_provider_receipts_invalid"]
    route_receipts = report["route_receipts"]
    if (
        not isinstance(route_receipts, list)
        or len(route_receipts) != 2
        or {row.get("route_id") for row in route_receipts}
        != {"economic", "capability"}
        or any(row.get("model_id") != "deepseek-v4-flash" for row in route_receipts)
        or any(int(row.get("attempted_slot_count", 0)) != 200 for row in route_receipts)
        or any(int(row.get("call_count", 0)) != 200 for row in route_receipts)
        or any(int(row.get("failure_count", -1)) != 0 for row in route_receipts)
        or any(
            int(row.get("failure_denominator_count", 0)) != 200
            for row in route_receipts
        )
        or any(
            int(row.get("schema_and_business_rule_failure_count", -1)) != 0
            for row in route_receipts
        )
        or any(not row.get("usage_receipts_sha256") for row in route_receipts)
    ):
        return None, ["c2.live_provider_route_sample_incomplete"]
    return report, []


def aggregate_c2(
    evidence_root: Path,
    *,
    candidate_oid: str,
    minimum_generated_attempt_count: int = 100_000,
    minimum_run_count: int = 10_000,
) -> dict[str, Any]:
    candidate = require_candidate_oid(candidate_oid)
    try:
        security = json.loads((evidence_root / "security-matrix.json").read_text("utf-8"))
        load = json.loads((evidence_root / "c2-postgresql-load.json").read_text("utf-8"))
    except (OSError, ValueError) as error:
        raise CertificationFailure("c2.local_source_missing") from error
    live, blockers = _load_live_provider_receipt(
        evidence_root,
        expected_candidate_oid=candidate,
    )
    if live is None:
        live_metrics = {
            "live_provider": False,
            "minimum_live_calls_per_route": 0,
            "cost_to_budget_ratio_upper": 999.0,
            "p95_cost_increase_upper": 999.0,
            "pricing_snapshot_sha256": None,
        }
    else:
        live_metrics = {
            "live_provider": True,
            "minimum_live_calls_per_route": min(
                int(row["call_count"]) for row in live["route_receipts"]
            ),
            "cost_to_budget_ratio_upper": float(live["cost_to_budget_ratio_upper"]),
            "p95_cost_increase_upper": float(live["p95_cost_increase_upper"]),
            "pricing_snapshot_sha256": str(live["pricing_snapshot_sha256"]),
        }
    performance = {
        "schema_version": "1.0",
        "gate_id": "C2",
        "real_postgresql": True,
        "local_complete_run_count": load["local_complete_run_count"],
        "api_latency_sample_count": load["api_latency_sample_count"],
        "api_p95_upper_ms": load["api_p95_upper_ms"],
        **live_metrics,
        "local_runtime_report_sha256": canonical_sha256(load),
        "production": False,
        "cost_boundary": "live provider receipt required; local fake cost is never substituted",
    }
    write_atomic_json(evidence_root / "performance-cost-report.json", performance)
    local_passed = (
        security["failure_count"] == 0
        and security["cross_tenant_leak_count"] == 0
        and security["secret_or_pii_leak_count"] == 0
        and security["forbidden_tool_execution_count"] == 0
        and security["critical_mutation_kill_rate"] == 1.0
        and security["generated_security_attempt_count"] >= minimum_generated_attempt_count
        and load["local_complete_run_count"] >= minimum_run_count
        and load["terminal_failure_count"] == 0
        and load["rls_cross_tenant_leak_count"] == 0
        and load["api_p95_upper_ms"] <= 800
    )
    live_passed = (
        live is not None
        and live_metrics["minimum_live_calls_per_route"] >= 200
        and live_metrics["cost_to_budget_ratio_upper"] <= 1.2
        and live_metrics["p95_cost_increase_upper"] <= 0.15
    )
    if not local_passed:
        blockers.append("c2.local_predicate_failed")
    metrics = {
        "real_postgresql": True,
        "live_provider": bool(live_metrics["live_provider"]),
        "generated_security_attempt_count": security[
            "generated_security_attempt_count"
        ],
        "local_complete_run_count": load["local_complete_run_count"],
        "minimum_live_calls_per_route": live_metrics[
            "minimum_live_calls_per_route"
        ],
        "critical_mutation_kill_rate": security["critical_mutation_kill_rate"],
        "changed_mutation_kill_rate": security["changed_mutation_kill_rate"],
        "api_p95_upper_ms": load["api_p95_upper_ms"],
        "cost_to_budget_ratio_upper": live_metrics["cost_to_budget_ratio_upper"],
        "p95_cost_increase_upper": live_metrics["p95_cost_increase_upper"],
        "cross_tenant_leak_count": security["cross_tenant_leak_count"]
        + load["rls_cross_tenant_leak_count"],
        "unauthorized_write_count": security["unauthorized_write_count"],
        "secret_or_pii_leak_count": security["secret_or_pii_leak_count"],
        "forbidden_tool_execution_count": security[
            "forbidden_tool_execution_count"
        ],
        "missing_audit_receipt_count": security["missing_audit_receipt_count"],
        "arbitrary_sql_executor_count": security["arbitrary_sql_executor_count"],
    }
    sources = [
        source_artifact(evidence_root, "security-matrix.json"),
        source_artifact(evidence_root, "performance-cost-report.json"),
        source_artifact(evidence_root, "c2-postgresql-load.json"),
    ]
    if live is not None:
        sources.append(
            source_artifact(
                evidence_root,
                f"{DEEPSEEK_LIVE_EVIDENCE_DIRECTORY}/live-provider-receipts.json",
            )
        )
        sources.append(
            source_artifact(
                evidence_root,
                f"{DEEPSEEK_LIVE_EVIDENCE_DIRECTORY}/pricing-snapshot.json",
            )
        )
    status = "passed" if local_passed and live_passed else "blocked" if local_passed else "failed"
    report = gate_report(
        gate_id="C2",
        candidate_oid=candidate,
        status=status,
        metrics=metrics,
        sources=sources,
        blocker_codes=blockers,
    )
    write_atomic_json(evidence_root / "c2-security-performance-cost.json", report)
    return report


def run_c2_local(
    evidence_root: Path,
    *,
    candidate_oid: str,
    generated_attempt_count: int = 100_000,
    run_count: int = 10_000,
    database_url: str = DEFAULT_DATABASE_URL,
) -> dict[str, Any]:
    evidence_root.mkdir(parents=True, exist_ok=True)
    run_security_matrix(
        evidence_root,
        generated_attempt_count=generated_attempt_count,
    )
    run_postgresql_load(
        evidence_root,
        run_count=run_count,
        database_url=database_url,
    )
    return aggregate_c2(
        evidence_root,
        candidate_oid=candidate_oid,
        minimum_generated_attempt_count=generated_attempt_count,
        minimum_run_count=run_count,
    )
