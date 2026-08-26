"""Fail-closed production composition for the independently deployed Worker."""

from __future__ import annotations

import os
import re

from sqlalchemy import create_engine, event
from sqlalchemy.engine import make_url
from sqlalchemy.orm import Session, sessionmaker

from app.models.gemini import EnvironmentGeminiCredentialProvider
from app.runtime.context_planner import ContextPlanner
from app.worker.execution import DurableWorkerExecutor
from app.worker.itinerary_processor import (
    GeminiItineraryProcessor,
    ItineraryStageRuntimePolicy,
    OverflowRecoveryPolicy,
)
from app.worker.main import WorkerRuntime


TENANT_PATTERN = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.:-]{0,127}$")
WORKER_ID_PATTERN = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.:-]{0,127}$")


class WorkerCompositionError(RuntimeError):
    code = "worker.dependencies_unavailable"

    def __init__(self) -> None:
        super().__init__(self.code)


class WorkerDatabaseSession(Session):
    pass


@event.listens_for(WorkerDatabaseSession, "after_begin")
def _worker_role(session: Session, transaction, connection) -> None:
    del session, transaction
    connection.exec_driver_sql("SET LOCAL ROLE gonow_agent_worker")


class StaticTenantWorkSource:
    """Bound the personal deployment to an explicit non-wildcard tenant set."""

    def __init__(self, tenant_ids: tuple[str, ...]) -> None:
        if (
            not tenant_ids
            or len(set(tenant_ids)) != len(tenant_ids)
            or any(TENANT_PATTERN.fullmatch(value) is None for value in tenant_ids)
        ):
            raise WorkerCompositionError()
        self._tenant_ids = tuple(sorted(tenant_ids))

    def ready_tenants(self) -> tuple[str, ...]:
        return self._tenant_ids


def _required_environment(name: str) -> str:
    value = os.environ.get(name, "").strip()
    if not value:
        raise WorkerCompositionError()
    return value


def _context_planner_from_environment() -> ContextPlanner | None:
    enabled = os.environ.get("GONOW_CONTEXT_PLANNER_V2_ENABLED", "0").strip()
    if enabled in {"", "0"}:
        return None
    if enabled != "1":
        raise WorkerCompositionError()
    planner = ContextPlanner()
    if (
        os.environ.get("GONOW_CONTEXT_PLANNER_V2_POLICY_SHA256", "").strip()
        != planner.policy_digest
    ):
        raise WorkerCompositionError()
    return planner


def _stage_runtime_from_environment(
    planner: ContextPlanner | None,
) -> ItineraryStageRuntimePolicy | None:
    enabled = os.environ.get("GONOW_CONTEXT_STAGE_RUNTIME_V2_ENABLED", "0").strip()
    if enabled in {"", "0"}:
        return None
    if enabled != "1" or planner is None:
        raise WorkerCompositionError()
    return ItineraryStageRuntimePolicy()


def _overflow_recovery_from_environment(
    planner: ContextPlanner | None,
    stage_runtime: ItineraryStageRuntimePolicy | None,
) -> tuple[ItineraryStageRuntimePolicy | None, OverflowRecoveryPolicy | None]:
    enabled = os.environ.get(
        "GONOW_CONTEXT_OVERFLOW_RECOVERY_V2_ENABLED",
        "0",
    ).strip()
    if enabled in {"", "0"}:
        return stage_runtime, None
    if enabled != "1" or planner is None or stage_runtime is None:
        raise WorkerCompositionError()
    return (
        ItineraryStageRuntimePolicy(
            max_total_tokens=250_000,
            max_model_calls=5,
        ),
        OverflowRecoveryPolicy(),
    )


def build_worker_runtime_from_environment() -> WorkerRuntime:
    database_url = _required_environment("GONOW_DATABASE_URL")
    raw_tenants = _required_environment("GONOW_WORKER_TENANTS")
    worker_id = os.environ.get("GONOW_WORKER_ID", "gonow-worker-personal").strip()
    if WORKER_ID_PATTERN.fullmatch(worker_id) is None:
        raise WorkerCompositionError()
    if not os.environ.get("GEMINI_API_KEY", ""):
        raise WorkerCompositionError()
    if os.environ.get("GONOW_COST_ROUTER_ENABLED", "0").strip() not in {"", "0"}:
        # P12B is local provisional: production composition cannot allocate it.
        raise WorkerCompositionError()
    try:
        parsed = make_url(database_url)
    except Exception as error:
        raise WorkerCompositionError() from error
    if parsed.drivername != "postgresql+pg8000" or not parsed.host or not parsed.database:
        raise WorkerCompositionError()
    tenants = tuple(value.strip() for value in raw_tenants.split(",") if value.strip())
    tenant_source = StaticTenantWorkSource(tenants)
    context_planner = _context_planner_from_environment()
    stage_runtime_policy = _stage_runtime_from_environment(context_planner)
    stage_runtime_policy, overflow_recovery_policy = (
        _overflow_recovery_from_environment(
            context_planner,
            stage_runtime_policy,
        )
    )
    engine = create_engine(database_url, pool_pre_ping=True)
    factory = sessionmaker(
        engine,
        class_=WorkerDatabaseSession,
        expire_on_commit=False,
    )
    executor = DurableWorkerExecutor(
        factory,
        processor=GeminiItineraryProcessor(
            credentials=EnvironmentGeminiCredentialProvider(),
            context_planner=context_planner,
            stage_runtime_policy=stage_runtime_policy,
            overflow_recovery_policy=overflow_recovery_policy,
        ),
    )
    return WorkerRuntime(
        executor=executor,
        tenant_source=tenant_source,
        worker_id=worker_id,
        resource_closer=engine.dispose,
    )
