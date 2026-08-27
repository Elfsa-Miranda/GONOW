"""Fenced Worker composition from durable Job claim to one terminal Run state."""

from __future__ import annotations

from dataclasses import dataclass
from enum import StrEnum
import json
from typing import Any, Protocol

from sqlalchemy import func, select
from sqlalchemy.orm import Session, sessionmaker

from app.persistence.models.jobs import JobRecord
from app.persistence.models.runtime import RunRecord, RunState
from app.persistence.repositories.candidates import CandidatesRepository
from app.persistence.repositories.events import EventsRepository
from app.persistence.repositories.job_inputs import JobInputsRepository
from app.persistence.repositories.jobs import JobClaim, JobsRepository
from app.persistence.repositories.runs import RunsRepository
from app.runtime.behavior_manifest import BehaviorManifestError, digest_behavior_manifest
from app.runtime.candidate import ItineraryCandidate
from app.runtime.interrupts import MissingInfoInterrupt, interrupt_json
from app.worker.job_runner import ClaimState, DurableJobRunner


class WorkerExecutionState(StrEnum):
    EMPTY = "empty"
    SUCCEEDED = "succeeded"
    WAITING_INPUT = "waiting_input"
    CANCELLED = "cancelled"
    FAILED = "failed"


class WorkerExecutionError(RuntimeError):
    code = "worker.execution_failed"
    default_code = code

    def __init__(self, code: str = default_code) -> None:
        self.code = code
        super().__init__(code)


class WorkerClarificationRequired(WorkerExecutionError):
    code = "context.clarification_required"

    def __init__(self, interrupt: MissingInfoInterrupt) -> None:
        self.interrupt = interrupt
        super().__init__(self.code)


@dataclass(frozen=True, slots=True)
class ClaimedItineraryJob:
    claim: JobClaim
    behavior_digest: str
    context_policy_digest: str
    input_digest: str
    structured_input: dict[str, Any]


@dataclass(frozen=True, slots=True)
class WorkerExecutionResult:
    state: WorkerExecutionState
    claim: JobClaim | None
    candidate_ref: str | None = None


class ItineraryJobProcessor(Protocol):
    """Certified model/tool/graph adapter; it cannot receive a database session."""

    def process(self, job: ClaimedItineraryJob) -> ItineraryCandidate: ...


class DurableWorkerExecutor:
    def __init__(
        self,
        session_factory: sessionmaker[Session],
        *,
        processor: ItineraryJobProcessor,
    ) -> None:
        self._session_factory = session_factory
        self._runner = DurableJobRunner(session_factory)
        self._processor = processor

    @staticmethod
    def _set_tenant(session: Session, tenant_id: str) -> None:
        session.execute(select(func.set_config("app.tenant_id", tenant_id, True)))

    def execute_once(
        self,
        *,
        tenant_id: str,
        holder_id: str,
        audit_receipt_id: str,
        lease_seconds: int = 30,
    ) -> WorkerExecutionResult:
        attempt = self._runner.claim_once(
            tenant_id=tenant_id,
            holder_id=holder_id,
            audit_receipt_id=audit_receipt_id,
            lease_seconds=lease_seconds,
        )
        if attempt.state is ClaimState.EMPTY or attempt.claim is None:
            return WorkerExecutionResult(state=WorkerExecutionState.EMPTY, claim=None)
        claim = attempt.claim
        prepared = self._prepare(claim=claim, audit_receipt_id=audit_receipt_id)
        if isinstance(prepared, WorkerExecutionResult):
            return prepared
        try:
            candidate = self._processor.process(prepared)
            if (
                candidate.run_id != str(claim.run_id)
                or candidate.behavior_digest != prepared.behavior_digest
                or candidate.input_digest != prepared.input_digest
            ):
                raise WorkerExecutionError()
            return self._complete(
                claim=claim,
                candidate=candidate,
                audit_receipt_id=audit_receipt_id,
            )
        except WorkerClarificationRequired as error:
            return self._wait_for_input(
                claim=claim,
                interrupt=error.interrupt,
                audit_receipt_id=audit_receipt_id,
            )
        except WorkerExecutionError as error:
            self._fail(
                claim=claim,
                audit_receipt_id=audit_receipt_id,
                reason_code=error.code,
            )
            raise
        except Exception as error:
            self._fail(
                claim=claim,
                audit_receipt_id=audit_receipt_id,
                reason_code=WorkerExecutionError.default_code,
            )
            raise WorkerExecutionError() from error

    def _wait_for_input(
        self,
        *,
        claim: JobClaim,
        interrupt: MissingInfoInterrupt,
        audit_receipt_id: str,
    ) -> WorkerExecutionResult:
        with self._session_factory.begin() as session:
            self._set_tenant(session, claim.tenant_id)
            jobs = JobsRepository(session)
            jobs.assert_fence(
                tenant_id=claim.tenant_id,
                job_id=claim.job_id,
                holder_id=claim.holder_id,
                fencing_token=claim.fencing_token,
            )
            run = session.execute(
                select(RunRecord)
                .where(
                    RunRecord.tenant_id == claim.tenant_id,
                    RunRecord.run_id == claim.run_id,
                )
                .with_for_update()
            ).scalar_one()
            if RunState(run.state) is not RunState.RUNNING:
                raise WorkerExecutionError()
            EventsRepository(session).append(
                tenant_id=claim.tenant_id,
                run_id=claim.run_id,
                event_type="interrupt.requested",
                payload={"interrupt": json.loads(interrupt_json(interrupt))},
                audit_receipt_id=audit_receipt_id,
            )
            RunsRepository(session).transition_state(
                tenant_id=claim.tenant_id,
                run_id=claim.run_id,
                expected_state=RunState.RUNNING,
                expected_version=run.version,
                target_state=RunState.WAITING_INPUT,
            )
            job = session.execute(
                select(JobRecord)
                .where(
                    JobRecord.tenant_id == claim.tenant_id,
                    JobRecord.job_id == claim.job_id,
                )
                .with_for_update()
            ).scalar_one()
            job.status = "completed"
            job.updated_at = func.statement_timestamp()
            jobs.release_lease(
                tenant_id=claim.tenant_id,
                job_id=claim.job_id,
                holder_id=claim.holder_id,
                fencing_token=claim.fencing_token,
            )
            return WorkerExecutionResult(
                state=WorkerExecutionState.WAITING_INPUT,
                claim=claim,
            )

    def _prepare(
        self,
        *,
        claim: JobClaim,
        audit_receipt_id: str,
    ) -> ClaimedItineraryJob | WorkerExecutionResult:
        with self._session_factory.begin() as session:
            self._set_tenant(session, claim.tenant_id)
            JobsRepository(session).assert_fence(
                tenant_id=claim.tenant_id,
                job_id=claim.job_id,
                holder_id=claim.holder_id,
                fencing_token=claim.fencing_token,
            )
            run = session.execute(
                select(RunRecord)
                .where(
                    RunRecord.tenant_id == claim.tenant_id,
                    RunRecord.run_id == claim.run_id,
                )
                .with_for_update()
            ).scalar_one()
            state = RunState(run.state)
            if state is RunState.CANCELLING:
                self._cancel_locked(
                    session,
                    claim=claim,
                    run=run,
                    audit_receipt_id=audit_receipt_id,
                )
                return WorkerExecutionResult(
                    state=WorkerExecutionState.CANCELLED,
                    claim=claim,
                )
            if state in {RunState.QUEUED, RunState.RECOVERING, RunState.RESUMING}:
                transitioned = RunsRepository(session).transition_state(
                    tenant_id=claim.tenant_id,
                    run_id=claim.run_id,
                    expected_state=state,
                    expected_version=run.version,
                    target_state=RunState.RUNNING,
                )
                EventsRepository(session).append(
                    tenant_id=claim.tenant_id,
                    run_id=claim.run_id,
                    event_type="step.started",
                    payload={"stage": "itinerary_planning", "version": transitioned.version},
                    audit_receipt_id=audit_receipt_id,
                )
            elif state is not RunState.RUNNING:
                raise WorkerExecutionError()
            job_input = JobInputsRepository(session).load(
                tenant_id=claim.tenant_id,
                input_ref=claim.input_ref,
            )
            try:
                manifest = digest_behavior_manifest(run.manifest)
                context_policy_digest = str(
                    manifest.normalized["components"]["context"]["sha256"]
                )
            except (BehaviorManifestError, KeyError, TypeError, ValueError) as error:
                raise WorkerExecutionError("behavior.not_qualified") from error
            if manifest.sha256 != run.manifest_digest:
                raise WorkerExecutionError("behavior.not_qualified")
            return ClaimedItineraryJob(
                claim=claim,
                behavior_digest=run.manifest_digest,
                context_policy_digest=context_policy_digest,
                input_digest=job_input.input_sha256,
                structured_input=dict(job_input.payload),
            )

    def _complete(
        self,
        *,
        claim: JobClaim,
        candidate: ItineraryCandidate,
        audit_receipt_id: str,
    ) -> WorkerExecutionResult:
        with self._session_factory.begin() as session:
            self._set_tenant(session, claim.tenant_id)
            jobs = JobsRepository(session)
            jobs.assert_fence(
                tenant_id=claim.tenant_id,
                job_id=claim.job_id,
                holder_id=claim.holder_id,
                fencing_token=claim.fencing_token,
            )
            run = session.execute(
                select(RunRecord)
                .where(
                    RunRecord.tenant_id == claim.tenant_id,
                    RunRecord.run_id == claim.run_id,
                )
                .with_for_update()
            ).scalar_one()
            if RunState(run.state) is RunState.CANCELLING:
                self._cancel_locked(
                    session,
                    claim=claim,
                    run=run,
                    audit_receipt_id=audit_receipt_id,
                )
                return WorkerExecutionResult(
                    state=WorkerExecutionState.CANCELLED,
                    claim=claim,
                )
            if RunState(run.state) is not RunState.RUNNING:
                raise WorkerExecutionError()
            persisted = CandidatesRepository(session).persist_fenced(
                tenant_id=claim.tenant_id,
                job_id=claim.job_id,
                holder_id=claim.holder_id,
                fencing_token=claim.fencing_token,
                candidate=candidate,
            )
            EventsRepository(session).append(
                tenant_id=claim.tenant_id,
                run_id=claim.run_id,
                event_type="candidate.ready",
                payload={
                    "candidate_ref": persisted.candidate_ref,
                    "candidate_digest": persisted.candidate_digest,
                },
                audit_receipt_id=audit_receipt_id,
            )
            EventsRepository(session).append(
                tenant_id=claim.tenant_id,
                run_id=claim.run_id,
                event_type="run.succeeded",
                payload={
                    "candidate_ref": persisted.candidate_ref,
                    "version": run.version + 1,
                },
                audit_receipt_id=audit_receipt_id,
            )
            RunsRepository(session).transition_state(
                tenant_id=claim.tenant_id,
                run_id=claim.run_id,
                expected_state=RunState.RUNNING,
                expected_version=run.version,
                target_state=RunState.SUCCEEDED,
            )
            job = session.execute(
                select(JobRecord)
                .where(
                    JobRecord.tenant_id == claim.tenant_id,
                    JobRecord.job_id == claim.job_id,
                )
                .with_for_update()
            ).scalar_one()
            job.status = "completed"
            job.updated_at = func.statement_timestamp()
            jobs.release_lease(
                tenant_id=claim.tenant_id,
                job_id=claim.job_id,
                holder_id=claim.holder_id,
                fencing_token=claim.fencing_token,
            )
            return WorkerExecutionResult(
                state=WorkerExecutionState.SUCCEEDED,
                claim=claim,
                candidate_ref=persisted.candidate_ref,
            )

    def _fail(
        self,
        *,
        claim: JobClaim,
        audit_receipt_id: str,
        reason_code: str,
    ) -> None:
        with self._session_factory.begin() as session:
            self._set_tenant(session, claim.tenant_id)
            jobs = JobsRepository(session)
            jobs.assert_fence(
                tenant_id=claim.tenant_id,
                job_id=claim.job_id,
                holder_id=claim.holder_id,
                fencing_token=claim.fencing_token,
            )
            run = session.execute(
                select(RunRecord)
                .where(
                    RunRecord.tenant_id == claim.tenant_id,
                    RunRecord.run_id == claim.run_id,
                )
                .with_for_update()
            ).scalar_one()
            state = RunState(run.state)
            if state is RunState.CANCELLING:
                self._cancel_locked(
                    session,
                    claim=claim,
                    run=run,
                    audit_receipt_id=audit_receipt_id,
                )
                return
            if state is RunState.RUNNING:
                EventsRepository(session).append(
                    tenant_id=claim.tenant_id,
                    run_id=claim.run_id,
                    event_type="run.failed",
                    payload={"reason_code": reason_code},
                    audit_receipt_id=audit_receipt_id,
                )
                RunsRepository(session).transition_state(
                    tenant_id=claim.tenant_id,
                    run_id=claim.run_id,
                    expected_state=RunState.RUNNING,
                    expected_version=run.version,
                    target_state=RunState.FAILED,
                )
            job = session.execute(
                select(JobRecord)
                .where(
                    JobRecord.tenant_id == claim.tenant_id,
                    JobRecord.job_id == claim.job_id,
                )
                .with_for_update()
            ).scalar_one()
            job.status = "failed"
            job.updated_at = func.statement_timestamp()
            jobs.release_lease(
                tenant_id=claim.tenant_id,
                job_id=claim.job_id,
                holder_id=claim.holder_id,
                fencing_token=claim.fencing_token,
            )

    @staticmethod
    def _cancel_locked(
        session: Session,
        *,
        claim: JobClaim,
        run: RunRecord,
        audit_receipt_id: str,
    ) -> None:
        jobs = JobsRepository(session)
        EventsRepository(session).append(
            tenant_id=claim.tenant_id,
            run_id=claim.run_id,
            event_type="run.cancelled",
            payload={"safe_boundary": "before_candidate_commit"},
            audit_receipt_id=audit_receipt_id,
        )
        RunsRepository(session).transition_state(
            tenant_id=claim.tenant_id,
            run_id=claim.run_id,
            expected_state=RunState.CANCELLING,
            expected_version=run.version,
            target_state=RunState.CANCELLED,
        )
        job = session.execute(
            select(JobRecord)
            .where(
                JobRecord.tenant_id == claim.tenant_id,
                JobRecord.job_id == claim.job_id,
            )
            .with_for_update()
        ).scalar_one()
        job.status = "cancelled"
        job.updated_at = func.statement_timestamp()
        jobs.release_lease(
            tenant_id=claim.tenant_id,
            job_id=claim.job_id,
            holder_id=claim.holder_id,
            fencing_token=claim.fencing_token,
        )
