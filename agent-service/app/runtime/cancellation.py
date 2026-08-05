"""Durable cancellation intent and safe-boundary terminal convergence."""

from __future__ import annotations

from dataclasses import dataclass
from uuid import UUID

from sqlalchemy import func, select
from sqlalchemy.orm import Session, sessionmaker

from app.persistence.models.runtime import RunRecord, RunState
from app.persistence.repositories.events import EventsRepository
from app.persistence.repositories.runs import RunsRepository


CANCELABLE_STATES = frozenset(
    {
        RunState.QUEUED,
        RunState.RUNNING,
        RunState.WAITING_INPUT,
        RunState.RESUMING,
        RunState.RECOVERING,
    }
)


class CancelRejected(RuntimeError):
    """Stable, non-oracular conflict for stale, foreign, or terminal Runs."""

    code = "cancel.conflict"

    def __init__(self) -> None:
        super().__init__(self.code)


@dataclass(frozen=True, slots=True)
class CancelRequestResult:
    run_id: UUID
    state: RunState
    version: int
    replayed: bool


@dataclass(frozen=True, slots=True)
class SafeBoundaryResult:
    run_id: UUID
    cancel_observed: bool
    state: RunState
    version: int
    replayed: bool


class CancellationService:
    """Use the persisted Run state as intent; every transition is a database CAS."""

    def __init__(self, session_factory: sessionmaker[Session]) -> None:
        self._session_factory = session_factory

    @staticmethod
    def _set_tenant(session: Session, tenant_id: str) -> None:
        session.execute(select(func.set_config("app.tenant_id", tenant_id, True)))

    @staticmethod
    def _locked_run(
        session: Session,
        *,
        tenant_id: str,
        run_id: UUID,
        principal_id: str | None = None,
    ) -> RunRecord | None:
        statement = select(RunRecord).where(
            RunRecord.run_id == run_id,
            RunRecord.tenant_id == tenant_id,
        )
        if principal_id is not None:
            statement = statement.where(RunRecord.principal_id == principal_id)
        return session.execute(statement.with_for_update()).scalar_one_or_none()

    def request_cancel(
        self,
        *,
        tenant_id: str,
        principal_id: str,
        run_id: UUID,
        expected_version: int,
        audit_receipt_id: str,
    ) -> CancelRequestResult:
        if not tenant_id or not principal_id or expected_version < 0 or not audit_receipt_id:
            raise CancelRejected()
        with self._session_factory.begin() as session:
            self._set_tenant(session, tenant_id)
            run = self._locked_run(
                session,
                tenant_id=tenant_id,
                run_id=run_id,
                principal_id=principal_id,
            )
            if run is None:
                raise CancelRejected()
            current = RunState(run.state)
            if current in {RunState.CANCELLING, RunState.CANCELLED}:
                return CancelRequestResult(
                    run_id=run.run_id,
                    state=current,
                    version=run.version,
                    replayed=True,
                )
            if current not in CANCELABLE_STATES or run.version != expected_version:
                raise CancelRejected()
            EventsRepository(session).append(
                tenant_id=tenant_id,
                run_id=run_id,
                event_type="run.cancel_requested",
                payload={"from_state": current.value, "safe_boundary_required": True},
                audit_receipt_id=audit_receipt_id,
            )
            transitioned = RunsRepository(session).transition_state(
                tenant_id=tenant_id,
                run_id=run_id,
                expected_state=current,
                expected_version=run.version,
                target_state=RunState.CANCELLING,
            )
            return CancelRequestResult(
                run_id=transitioned.run_id,
                state=RunState(transitioned.state),
                version=transitioned.version,
                replayed=False,
            )

    def converge_at_safe_boundary(
        self,
        *,
        tenant_id: str,
        run_id: UUID,
        audit_receipt_id: str,
    ) -> SafeBoundaryResult:
        if not tenant_id or not audit_receipt_id:
            raise CancelRejected()
        with self._session_factory.begin() as session:
            self._set_tenant(session, tenant_id)
            run = self._locked_run(session, tenant_id=tenant_id, run_id=run_id)
            if run is None:
                raise CancelRejected()
            current = RunState(run.state)
            if current is RunState.CANCELLED:
                return SafeBoundaryResult(
                    run_id=run.run_id,
                    cancel_observed=True,
                    state=current,
                    version=run.version,
                    replayed=True,
                )
            if current is not RunState.CANCELLING:
                return SafeBoundaryResult(
                    run_id=run.run_id,
                    cancel_observed=False,
                    state=current,
                    version=run.version,
                    replayed=False,
                )
            EventsRepository(session).append(
                tenant_id=tenant_id,
                run_id=run_id,
                event_type="run.cancelled",
                payload={"from_state": current.value, "safe_boundary_observed": True},
                audit_receipt_id=audit_receipt_id,
            )
            transitioned = RunsRepository(session).transition_state(
                tenant_id=tenant_id,
                run_id=run_id,
                expected_state=RunState.CANCELLING,
                expected_version=run.version,
                target_state=RunState.CANCELLED,
            )
            return SafeBoundaryResult(
                run_id=transitioned.run_id,
                cancel_observed=True,
                state=RunState(transitioned.state),
                version=transitioned.version,
                replayed=False,
            )
