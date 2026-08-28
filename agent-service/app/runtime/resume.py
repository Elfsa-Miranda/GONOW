"""Transactional transition from a consumed resume capability to queued work."""

from __future__ import annotations

import hashlib
from uuid import UUID

from sqlalchemy import func, select
from sqlalchemy.orm import Session, sessionmaker

from app.auth.context import RequestContext
from app.auth.resume_token import ResumeCapabilityRecord, ResumeCapabilityRejected
from app.persistence.models.jobs import JobRecord
from app.persistence.models.runtime import RunRecord, RunState
from app.persistence.repositories.events import EventsRepository
from app.persistence.repositories.jobs import JobsRepository
from app.persistence.repositories.runs import RunsRepository


class ResumeTransitionService:
    """Create one fenced follow-up Job only from an exact waiting Run binding."""

    def __init__(self, session_factory: sessionmaker[Session]) -> None:
        self._session_factory = session_factory

    @staticmethod
    def _audit_receipt(context: RequestContext, capability_id: UUID) -> str:
        return hashlib.sha256(
            (
                "gonow:resume:"
                + context.tenant_id
                + ":"
                + context.principal_id
                + ":"
                + context.trace_id
                + ":"
                + str(capability_id)
            ).encode("utf-8")
        ).hexdigest()

    def __call__(
        self,
        context: RequestContext,
        capability: ResumeCapabilityRecord,
    ) -> None:
        if (
            capability.consumed_at is None
            or capability.tenant_id != context.tenant_id
            or capability.principal_id != context.principal_id
        ):
            raise ResumeCapabilityRejected()
        receipt = self._audit_receipt(context, capability.capability_id)
        try:
            with self._session_factory.begin() as session:
                session.execute(
                    select(func.set_config("app.tenant_id", context.tenant_id, True))
                )
                run = session.execute(
                    select(RunRecord)
                    .where(
                        RunRecord.run_id == capability.run_id,
                        RunRecord.tenant_id == context.tenant_id,
                        RunRecord.principal_id == context.principal_id,
                    )
                    .with_for_update()
                ).scalar_one_or_none()
                if run is None or RunState(run.state) is not RunState.WAITING_INPUT:
                    raise ResumeCapabilityRejected()
                active_job = session.execute(
                    select(JobRecord.job_id).where(
                        JobRecord.run_id == capability.run_id,
                        JobRecord.tenant_id == context.tenant_id,
                        JobRecord.status.in_(("queued", "leased")),
                    )
                ).scalar_one_or_none()
                source_job = session.execute(
                    select(JobRecord)
                    .where(
                        JobRecord.run_id == capability.run_id,
                        JobRecord.tenant_id == context.tenant_id,
                    )
                    .order_by(JobRecord.created_at.desc(), JobRecord.job_id.desc())
                    .limit(1)
                ).scalar_one_or_none()
                if active_job is not None or source_job is None:
                    raise ResumeCapabilityRejected()
                transitioned = RunsRepository(session).transition_state(
                    tenant_id=context.tenant_id,
                    run_id=capability.run_id,
                    expected_state=RunState.WAITING_INPUT,
                    expected_version=run.version,
                    target_state=RunState.RESUMING,
                )
                JobsRepository(session).create_job(
                    tenant_id=context.tenant_id,
                    run_id=capability.run_id,
                    job_type=source_job.job_type,
                    input_ref=source_job.input_ref,
                    audit_receipt_id=receipt,
                )
                EventsRepository(session).append(
                    tenant_id=context.tenant_id,
                    run_id=capability.run_id,
                    event_type="resuming",
                    payload={
                        "interrupt_id": str(capability.interrupt_id),
                        "command_version": capability.command_version,
                        "version": transitioned.version,
                    },
                    audit_receipt_id=receipt,
                )
        except ResumeCapabilityRejected:
            raise
        except Exception as error:
            raise ResumeCapabilityRejected() from error
