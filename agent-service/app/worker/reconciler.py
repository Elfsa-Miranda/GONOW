"""Bounded PostgreSQL reconciler for orphan Run, Job, and Lease records."""

from __future__ import annotations

from dataclasses import dataclass
from datetime import timedelta

from sqlalchemy import func, select, update
from sqlalchemy.orm import Session, sessionmaker

from app.persistence.models.jobs import JobRecord, LeaseRecord
from app.persistence.models.runtime import RunRecord, RunState
from app.persistence.repositories.events import EventsRepository
from app.persistence.repositories.runs import RunStateConflict, RunsRepository


@dataclass(frozen=True, slots=True)
class ReconcileResult:
    scanned_records: int
    orphan_jobs: int
    expired_leases_released: int
    missing_leases: int
    jobs_requeued: int
    jobs_failed: int
    runs_recovering: int
    runs_cancelled: int
    runs_failed: int
    active_runs_preserved: int
    audit_events: int
    cas_conflicts: int
    limit_reached: bool


class DurableReconciler:
    """Repair only stale records proven to have no live lease owner."""

    def __init__(self, session_factory: sessionmaker[Session]) -> None:
        self._session_factory = session_factory

    @staticmethod
    def _set_tenant(session: Session, tenant_id: str) -> None:
        session.execute(select(func.set_config("app.tenant_id", tenant_id, True)))

    @staticmethod
    def _has_live_lease(session: Session, tenant_id: str, run_id) -> bool:
        return (
            session.execute(
                select(LeaseRecord.lease_id)
                .join(
                    JobRecord,
                    (JobRecord.job_id == LeaseRecord.job_id)
                    & (JobRecord.tenant_id == LeaseRecord.tenant_id),
                )
                .where(
                    JobRecord.run_id == run_id,
                    JobRecord.tenant_id == tenant_id,
                    JobRecord.status == "leased",
                    LeaseRecord.released_at.is_(None),
                    LeaseRecord.expires_at > func.statement_timestamp(),
                )
                .limit(1)
            ).scalar_one_or_none()
            is not None
        )

    @staticmethod
    def _has_recoverable_job(session: Session, tenant_id: str, run_id) -> bool:
        return (
            session.execute(
                select(JobRecord.job_id)
                .where(
                    JobRecord.run_id == run_id,
                    JobRecord.tenant_id == tenant_id,
                    JobRecord.status == "queued",
                    JobRecord.attempt_count < JobRecord.max_attempts,
                )
                .limit(1)
            ).scalar_one_or_none()
            is not None
        )

    def reconcile_once(
        self,
        *,
        tenant_id: str,
        audit_receipt_id: str,
        stale_after_seconds: int,
        max_records: int = 50,
    ) -> ReconcileResult:
        if (
            not tenant_id
            or not audit_receipt_id
            or not 1 <= stale_after_seconds <= 86_400
            or not 1 <= max_records <= 100
        ):
            raise ValueError("reconciler boundary is invalid")
        counters = {
            "scanned_records": 0,
            "orphan_jobs": 0,
            "expired_leases_released": 0,
            "missing_leases": 0,
            "jobs_requeued": 0,
            "jobs_failed": 0,
            "runs_recovering": 0,
            "runs_cancelled": 0,
            "runs_failed": 0,
            "active_runs_preserved": 0,
            "audit_events": 0,
            "cas_conflicts": 0,
        }
        with self._session_factory.begin() as session:
            self._set_tenant(session, tenant_id)
            database_now = session.execute(select(func.statement_timestamp())).scalar_one()
            stale_cutoff = database_now - timedelta(seconds=stale_after_seconds)

            orphan_jobs = tuple(
                session.scalars(
                    select(JobRecord)
                    .join(
                        RunRecord,
                        (RunRecord.run_id == JobRecord.run_id)
                        & (RunRecord.tenant_id == JobRecord.tenant_id),
                    )
                    .where(
                        JobRecord.tenant_id == tenant_id,
                        JobRecord.status == "leased",
                        RunRecord.state.in_(
                            (
                                RunState.QUEUED.value,
                                RunState.RUNNING.value,
                                RunState.RESUMING.value,
                                RunState.RECOVERING.value,
                                RunState.CANCELLING.value,
                            )
                        ),
                        ~select(LeaseRecord.lease_id)
                        .where(
                            LeaseRecord.job_id == JobRecord.job_id,
                            LeaseRecord.tenant_id == JobRecord.tenant_id,
                            LeaseRecord.released_at.is_(None),
                            LeaseRecord.expires_at > func.statement_timestamp(),
                        )
                        .exists(),
                    )
                    .order_by(JobRecord.updated_at, JobRecord.job_id)
                    .limit(max_records)
                    .with_for_update(of=JobRecord, skip_locked=True)
                )
            )
            for job in orphan_jobs:
                counters["scanned_records"] += 1
                counters["orphan_jobs"] += 1
                lease = session.execute(
                    select(LeaseRecord)
                    .where(
                        LeaseRecord.job_id == job.job_id,
                        LeaseRecord.tenant_id == tenant_id,
                        LeaseRecord.released_at.is_(None),
                    )
                    .order_by(LeaseRecord.fencing_token.desc())
                    .with_for_update()
                    .limit(1)
                ).scalar_one_or_none()
                if lease is None:
                    counters["missing_leases"] += 1
                else:
                    released = session.execute(
                        update(LeaseRecord)
                        .where(
                            LeaseRecord.lease_id == lease.lease_id,
                            LeaseRecord.tenant_id == tenant_id,
                            LeaseRecord.released_at.is_(None),
                            LeaseRecord.expires_at <= func.statement_timestamp(),
                        )
                        .values(released_at=func.statement_timestamp())
                    ).rowcount
                    if released != 1:
                        counters["active_runs_preserved"] += 1
                        continue
                    counters["expired_leases_released"] += 1
                if job.attempt_count < job.max_attempts:
                    job.status = "queued"
                    job.available_at = func.statement_timestamp()
                    counters["jobs_requeued"] += 1
                    classification = "requeued"
                else:
                    job.status = "failed"
                    counters["jobs_failed"] += 1
                    classification = "attempts_exhausted"
                job.updated_at = func.statement_timestamp()
                EventsRepository(session).append(
                    tenant_id=tenant_id,
                    run_id=job.run_id,
                    event_type="reconciler.job_repaired",
                    payload={
                        "classification": classification,
                        "job_id": str(job.job_id),
                    },
                    audit_receipt_id=audit_receipt_id,
                )
                counters["audit_events"] += 1

            remaining = max_records - counters["scanned_records"]
            if remaining > 0:
                stale_runs = tuple(
                    session.scalars(
                        select(RunRecord)
                        .where(
                            RunRecord.tenant_id == tenant_id,
                            RunRecord.state.in_(
                                (
                                    RunState.RUNNING.value,
                                    RunState.RESUMING.value,
                                    RunState.RECOVERING.value,
                                    RunState.CANCELLING.value,
                                )
                            ),
                            RunRecord.updated_at <= stale_cutoff,
                        )
                        .order_by(RunRecord.updated_at, RunRecord.run_id)
                        .limit(remaining)
                        .with_for_update(skip_locked=True)
                    )
                )
                for run in stale_runs:
                    counters["scanned_records"] += 1
                    if self._has_live_lease(session, tenant_id, run.run_id):
                        counters["active_runs_preserved"] += 1
                        continue
                    current = RunState(run.state)
                    recoverable = self._has_recoverable_job(
                        session, tenant_id, run.run_id
                    )
                    target: RunState | None
                    event_type: str
                    if current is RunState.CANCELLING:
                        target = RunState.CANCELLED
                        event_type = "reconciler.run_cancelled"
                    elif current is RunState.RUNNING and recoverable:
                        target = RunState.RECOVERING
                        event_type = "reconciler.run_recovering"
                    elif current is RunState.RECOVERING and recoverable:
                        target = None
                        event_type = ""
                    else:
                        target = RunState.FAILED
                        event_type = "reconciler.run_failed"
                    if target is None:
                        continue
                    EventsRepository(session).append(
                        tenant_id=tenant_id,
                        run_id=run.run_id,
                        event_type=event_type,
                        payload={
                            "from_state": current.value,
                            "to_state": target.value,
                            "live_lease": False,
                        },
                        audit_receipt_id=audit_receipt_id,
                    )
                    counters["audit_events"] += 1
                    try:
                        RunsRepository(session).transition_state(
                            tenant_id=tenant_id,
                            run_id=run.run_id,
                            expected_state=current,
                            expected_version=run.version,
                            target_state=target,
                        )
                    except RunStateConflict:
                        counters["cas_conflicts"] += 1
                        continue
                    if target is RunState.RECOVERING:
                        counters["runs_recovering"] += 1
                    elif target is RunState.CANCELLED:
                        counters["runs_cancelled"] += 1
                    elif target is RunState.FAILED:
                        counters["runs_failed"] += 1

        return ReconcileResult(
            **counters,
            limit_reached=counters["scanned_records"] >= max_records,
        )
