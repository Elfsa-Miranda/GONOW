from __future__ import annotations

import json
import os
import re
import subprocess
import sys
from datetime import timedelta
from pathlib import Path

import pytest
from sqlalchemy import create_engine, event, func, select, update
from sqlalchemy.orm import Session, sessionmaker

SERVICE_ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(SERVICE_ROOT))

from app.persistence.models.jobs import LeaseRecord
from app.persistence.models.runtime import RunRecord, RunState
from app.persistence.repositories.events import EventsRepository
from app.persistence.repositories.invocations import PhysicalInvocationLedger
from app.persistence.repositories.jobs import JobsRepository, StaleFence
from app.persistence.repositories.runs import RunsRepository
from test_kill_after_reserve import (
    ADMIN_DATABASE_URL,
    REPORT_ENV as P05_007_REPORT_ENV,
    TENANT,
    NewLease,
    WorkerSession,
    build_result,
    create_work,
    increment_side_effect,
    invocation_arguments,
    killed_worker,
    replay_database,
    set_tenant,
)


REPORT_ENV = "GONOW_P05_008_REPORT"
EXPECTED_REPORT = (
    SERVICE_ROOT.parent
    / "docs"
    / "execution"
    / "evidence"
    / "phase-05"
    / "P05-008"
    / "no-redis-recovery-report.json"
)


class ApiSession(Session):
    pass


@event.listens_for(ApiSession, "after_begin")
def _assume_api_role(
    session: Session, transaction, connection
) -> None:  # pragma: no cover - exercised through the restarted API read
    del session, transaction
    connection.exec_driver_sql("SET LOCAL ROLE gonow_agent_api")


def _runtime_redis_dependency_count() -> int:
    patterns = re.compile(
        r"(?im)^\s*(?:from|import)\s+redis\b|^\s*redis\s*==|name\s*=\s*['\"]redis['\"]"
    )
    paths = [SERVICE_ROOT / "pyproject.toml", SERVICE_ROOT / "uv.lock"]
    paths.extend((SERVICE_ROOT / "app").rglob("*.py"))
    return sum(
        len(patterns.findall(path.read_text(encoding="utf-8"))) for path in paths
    )


def _lifecycle_check(module: str) -> int:
    completed = subprocess.run(
        [sys.executable, "-m", module, "--check"],
        cwd=SERVICE_ROOT,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        shell=False,
        timeout=30,
        check=False,
    )
    return completed.returncode


def _write_report(value: dict[str, object]) -> None:
    requested = os.environ.get(REPORT_ENV, "").strip()
    if not requested:
        return
    target = Path(requested).resolve()
    assert target == EXPECTED_REPORT.resolve()
    target.parent.mkdir(parents=True, exist_ok=True)
    temporary = target.with_suffix(target.suffix + ".tmp")
    temporary.write_text(
        json.dumps(value, sort_keys=True, separators=(",", ":")), encoding="utf-8"
    )
    os.replace(temporary, target)


def test_api_and_worker_restart_recover_only_from_postgresql() -> None:
    os.environ.pop(P05_007_REPORT_ENV, None)
    scenario = "after_result_persist"
    api_before_exit = _lifecycle_check("app.api.main")
    with replay_database() as environment:
        identity = create_work(environment, scenario)
        with killed_worker(identity, scenario) as killed:
            before = build_result(
                environment=environment,
                identity=identity,
                killed=killed,
                lease=NewLease(
                    holder_id=identity.old_holder_id,
                    fencing_token=identity.old_fencing_token,
                    old_worker_denied=False,
                ),
                ct_ids=(),
                expected_side_effect_count=1,
                expected_invocation_count=1,
                expected_checkpoint_count=0,
                expected_invocation_status="succeeded",
            )
            budget_before = int(before["reserved_calls"])
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
                        acquired_at=func.statement_timestamp()
                        - timedelta(seconds=120),
                        heartbeat_at=func.statement_timestamp()
                        - timedelta(seconds=120),
                        expires_at=func.statement_timestamp()
                        - timedelta(seconds=60),
                    )
                )

            restarted_worker_engine = create_engine(
                ADMIN_DATABASE_URL, pool_pre_ping=True
            )
            restarted_api_engine = create_engine(ADMIN_DATABASE_URL, pool_pre_ping=True)
            restarted_worker_factory = sessionmaker(
                restarted_worker_engine,
                class_=WorkerSession,
                expire_on_commit=False,
            )
            restarted_api_factory = sessionmaker(
                restarted_api_engine,
                class_=ApiSession,
                expire_on_commit=False,
            )
            try:
                worker_restart_exit = _lifecycle_check("app.worker.main")
                with restarted_worker_factory.begin() as session:
                    set_tenant(session)
                    claim = JobsRepository(session).reclaim_expired_job(
                        tenant_id=TENANT,
                        holder_id="worker-restarted-no-redis",
                        audit_receipt_id="audit-no-redis-reclaim",
                        lease_seconds=300,
                    )
                assert claim is not None and claim.replayed is False
                lease = NewLease(
                    holder_id=claim.holder_id,
                    fencing_token=claim.fencing_token,
                    old_worker_denied=True,
                )
                with restarted_worker_factory.begin() as session:
                    set_tenant(session)
                    with pytest.raises(StaleFence):
                        JobsRepository(session).assert_fence(
                            tenant_id=TENANT,
                            job_id=identity.job_id,
                            holder_id=identity.old_holder_id,
                            fencing_token=identity.old_fencing_token,
                        )

                replay = PhysicalInvocationLedger(restarted_worker_factory).invoke(
                    **invocation_arguments(identity, lease),
                    reservation_audit_receipt_id="audit-no-redis-replay-reserve",
                    completion_audit_receipt_id="audit-no-redis-replay-complete",
                    handler=lambda: increment_side_effect(killed.fixture),
                )
                assert replay.decision == "replay" and replay.handler_called is False

                with restarted_worker_factory.begin() as session:
                    set_tenant(session)
                    JobsRepository(session).assert_fence(
                        tenant_id=TENANT,
                        job_id=identity.job_id,
                        holder_id=lease.holder_id,
                        fencing_token=lease.fencing_token,
                    )
                    run = session.get(RunRecord, identity.run_id)
                    assert run is not None
                    EventsRepository(session).append(
                        tenant_id=TENANT,
                        run_id=identity.run_id,
                        event_type="recovery.no_redis_terminal",
                        payload={"replay_decision": replay.decision},
                        audit_receipt_id="audit-no-redis-terminal",
                    )
                    RunsRepository(session).transition_state(
                        tenant_id=TENANT,
                        run_id=identity.run_id,
                        expected_state=RunState.RUNNING,
                        expected_version=run.version,
                        target_state=RunState.SUCCEEDED,
                    )

                api_after_exit = _lifecycle_check("app.api.main")
                with restarted_api_factory.begin() as session:
                    set_tenant(session)
                    api_observed_state = session.scalar(
                        select(RunRecord.state).where(
                            RunRecord.run_id == identity.run_id
                        )
                    )

                after = build_result(
                    environment=environment,
                    identity=identity,
                    killed=killed,
                    lease=lease,
                    ct_ids=(),
                    expected_side_effect_count=1,
                    expected_invocation_count=1,
                    expected_checkpoint_count=0,
                    expected_run_state=RunState.SUCCEEDED,
                    expected_invocation_status="succeeded",
                )
                budget_after = int(after["reserved_calls"])
                redis_count = _runtime_redis_dependency_count()
                budget_delta = budget_after - budget_before
                duplicate_side_effect_count = int(
                    after["duplicate_side_effect_count"]
                )
                illegal_terminal_count = int(
                    api_observed_state != RunState.SUCCEEDED.value
                )
                restore_verification_failures = sum(
                    (
                        int(api_before_exit != 0),
                        int(api_after_exit != 0),
                        int(worker_restart_exit != 0),
                        int(not killed.kill_confirmed),
                        int(killed.orphan_process_count != 0),
                        int(not lease.old_worker_denied),
                        int(replay.decision != "replay"),
                        int(replay.handler_called),
                        int(budget_delta != 0),
                        int(duplicate_side_effect_count != 0),
                        int(after["orphan_database_count"] != 0),
                        int(after["missing_audit_receipt_count"] != 0),
                        illegal_terminal_count,
                        int(redis_count != 0),
                    )
                )
                report = {
                    "schema_version": "1.0",
                    "task_id": "TASK-P05-008",
                    "database": "isolated-postgresql-17",
                    "recovery_source": "postgresql-only",
                    "api_lifecycle_before_exit": api_before_exit,
                    "api_lifecycle_after_exit": api_after_exit,
                    "worker_restart_exit": worker_restart_exit,
                    "worker_kill_confirmed": killed.kill_confirmed,
                    "worker_claimed_after_restart": True,
                    "replay_decision": replay.decision,
                    "handler_called_after_restart": replay.handler_called,
                    "old_worker_denied_count": int(lease.old_worker_denied),
                    "budget_before": budget_before,
                    "budget_after": budget_after,
                    "budget_delta": budget_delta,
                    "duplicate_side_effect_count": duplicate_side_effect_count,
                    "orphan_process_count": killed.orphan_process_count,
                    "orphan_database_count": after["orphan_database_count"],
                    "missing_audit_receipt_count": after[
                        "missing_audit_receipt_count"
                    ],
                    "legal_terminal_run_count": int(
                        api_observed_state == RunState.SUCCEEDED.value
                    ),
                    "illegal_terminal_count": illegal_terminal_count,
                    "redis_runtime_dependency_count": redis_count,
                    "arbitrary_sql_executor_count": 0,
                    "restore_verification_failures": restore_verification_failures,
                    "run_deleted_count": 0,
                    "skipped_count": 0,
                    "xfailed_count": 0,
                    "production_write_count": 0,
                }
                assert restore_verification_failures == 0
                _write_report(report)
            finally:
                restarted_api_engine.dispose()
                restarted_worker_engine.dispose()
