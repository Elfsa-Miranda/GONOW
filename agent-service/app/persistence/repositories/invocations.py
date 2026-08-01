"""Crash-safe physical Tool invocation reservation and replay boundary."""

from __future__ import annotations

from collections.abc import Callable
from dataclasses import dataclass
import hashlib
import json
import re
from typing import Literal
import uuid

from sqlalchemy import func, select
from sqlalchemy.dialects.postgresql import insert as pg_insert
from sqlalchemy.orm import Session, sessionmaker

from app.persistence.models.invocations import (
    InvocationBudgetRecord,
    PhysicalInvocationRecord,
)
from app.persistence.repositories.jobs import JobsRepository
from app.persistence.repositories.runs import TransactionRequired


DIGEST_PATTERN = re.compile(r"^[0-9a-f]{64}$")
TOOL_NAME_PATTERN = re.compile(r"^[a-z][a-z0-9_.-]{0,126}$")
TOOL_CALL_PATTERN = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.:-]{0,127}$")
TOOL_VERSION_PATTERN = re.compile(r"^[0-9]+\.[0-9]+\.[0-9]+$")
ERROR_CODE_PATTERN = re.compile(r"^[a-z][a-z0-9_.-]{0,126}$")
RESULT_REF_PATTERN = re.compile(r"^tool-result://sha256/[0-9a-f]{64}$")
InvocationDecision = Literal["execute", "replay", "reconcile"]
InvocationStatus = Literal["reserved", "succeeded", "failed", "unknown_outcome"]


class InvocationConflict(RuntimeError):
    code = "tool.invocation_conflict"

    def __init__(self) -> None:
        super().__init__(self.code)


class PhysicalBudgetExceeded(RuntimeError):
    code = "budget.physical_tool_limit"

    def __init__(self) -> None:
        super().__init__(self.code)


class InvocationNotFound(RuntimeError):
    code = "tool.invocation_not_found"

    def __init__(self) -> None:
        super().__init__(self.code)


class InvocationBudgetConflict(RuntimeError):
    code = "budget.physical_limit_conflict"

    def __init__(self) -> None:
        super().__init__(self.code)


@dataclass(frozen=True, slots=True)
class InvocationSnapshot:
    invocation_id: uuid.UUID
    tenant_id: str
    run_id: uuid.UUID
    job_id: uuid.UUID
    tool_call_id: str
    tool_name: str
    tool_version: str
    request_fingerprint: str
    status: InvocationStatus
    result_ref: str | None
    result_digest: str | None
    error_code: str | None


@dataclass(frozen=True, slots=True)
class InvocationReservation:
    decision: InvocationDecision
    invocation: InvocationSnapshot


@dataclass(frozen=True, slots=True)
class InvocationHandlerOutcome:
    status: Literal["succeeded", "failed", "unknown_outcome"]
    result_ref: str | None = None
    result_digest: str | None = None
    error_code: str | None = None

    def __post_init__(self) -> None:
        succeeded = (
            self.status == "succeeded"
            and isinstance(self.result_ref, str)
            and RESULT_REF_PATTERN.fullmatch(self.result_ref) is not None
            and isinstance(self.result_digest, str)
            and DIGEST_PATTERN.fullmatch(self.result_digest) is not None
            and self.result_ref == f"tool-result://sha256/{self.result_digest}"
            and self.error_code is None
        )
        failed = (
            self.status in {"failed", "unknown_outcome"}
            and self.result_ref is None
            and self.result_digest is None
            and isinstance(self.error_code, str)
            and ERROR_CODE_PATTERN.fullmatch(self.error_code) is not None
        )
        if not (succeeded or failed):
            raise ValueError("physical invocation outcome is invalid")

    @classmethod
    def succeeded(cls, result_digest: str) -> InvocationHandlerOutcome:
        return cls(
            status="succeeded",
            result_ref=f"tool-result://sha256/{result_digest}",
            result_digest=result_digest,
        )

    @classmethod
    def failed(cls, error_code: str) -> InvocationHandlerOutcome:
        return cls(status="failed", error_code=error_code)

    @classmethod
    def unknown(cls, error_code: str) -> InvocationHandlerOutcome:
        return cls(status="unknown_outcome", error_code=error_code)


@dataclass(frozen=True, slots=True)
class InvocationExecution:
    decision: InvocationDecision
    invocation: InvocationSnapshot
    handler_called: bool


def invocation_fingerprint(
    *, tool_name: str, tool_version: str, argument_sha256: str
) -> str:
    if (
        TOOL_NAME_PATTERN.fullmatch(tool_name) is None
        or TOOL_VERSION_PATTERN.fullmatch(tool_version) is None
        or DIGEST_PATTERN.fullmatch(argument_sha256) is None
    ):
        raise ValueError("physical invocation fingerprint input is invalid")
    canonical = json.dumps(
        {
            "argument_sha256": argument_sha256,
            "tool_name": tool_name,
            "tool_version": tool_version,
        },
        sort_keys=True,
        separators=(",", ":"),
        ensure_ascii=False,
    ).encode("utf-8")
    return hashlib.sha256(canonical).hexdigest()


def _snapshot(record: PhysicalInvocationRecord) -> InvocationSnapshot:
    return InvocationSnapshot(
        invocation_id=record.invocation_id,
        tenant_id=record.tenant_id,
        run_id=record.run_id,
        job_id=record.job_id,
        tool_call_id=record.tool_call_id,
        tool_name=record.tool_name,
        tool_version=record.tool_version,
        request_fingerprint=record.request_fingerprint,
        status=record.status,  # type: ignore[arg-type]
        result_ref=record.result_ref,
        result_digest=record.result_digest,
        error_code=record.error_code,
    )


class InvocationsRepository:
    """Transaction-owned physical budget and invocation mutations."""

    def __init__(self, session: Session) -> None:
        self._session = session

    def _require_transaction(self) -> None:
        if not self._session.in_transaction():
            raise TransactionRequired()

    def reserve(
        self,
        *,
        tenant_id: str,
        run_id: uuid.UUID,
        job_id: uuid.UUID,
        holder_id: str,
        fencing_token: int,
        tool_call_id: str,
        tool_name: str,
        tool_version: str,
        request_fingerprint: str,
        max_physical_calls: int,
        audit_receipt_id: str,
    ) -> InvocationReservation:
        self._require_transaction()
        if (
            not tenant_id
            or not holder_id
            or not audit_receipt_id
            or fencing_token <= 0
            or not 1 <= max_physical_calls <= 1024
            or TOOL_CALL_PATTERN.fullmatch(tool_call_id) is None
            or TOOL_NAME_PATTERN.fullmatch(tool_name) is None
            or TOOL_VERSION_PATTERN.fullmatch(tool_version) is None
            or DIGEST_PATTERN.fullmatch(request_fingerprint) is None
        ):
            raise ValueError("physical invocation reservation is invalid")
        JobsRepository(self._session).assert_fence(
            tenant_id=tenant_id,
            job_id=job_id,
            holder_id=holder_id,
            fencing_token=fencing_token,
        )
        self._session.execute(
            pg_insert(InvocationBudgetRecord)
            .values(
                run_id=run_id,
                tenant_id=tenant_id,
                max_physical_calls=max_physical_calls,
                reserved_calls=0,
                audit_receipt_id=audit_receipt_id,
            )
            .on_conflict_do_nothing(index_elements=[InvocationBudgetRecord.run_id])
        )
        budget = self._session.execute(
            select(InvocationBudgetRecord)
            .where(
                InvocationBudgetRecord.run_id == run_id,
                InvocationBudgetRecord.tenant_id == tenant_id,
            )
            .with_for_update()
        ).scalar_one()
        if budget.max_physical_calls != max_physical_calls:
            raise InvocationBudgetConflict()
        existing = self._session.execute(
            select(PhysicalInvocationRecord)
            .where(
                PhysicalInvocationRecord.run_id == run_id,
                PhysicalInvocationRecord.tenant_id == tenant_id,
                PhysicalInvocationRecord.tool_call_id == tool_call_id,
            )
            .with_for_update()
        ).scalar_one_or_none()
        if existing is not None:
            if (
                existing.job_id != job_id
                or existing.tool_name != tool_name
                or existing.tool_version != tool_version
                or existing.request_fingerprint != request_fingerprint
            ):
                raise InvocationConflict()
            return InvocationReservation(
                decision="reconcile" if existing.status == "reserved" else "replay",
                invocation=_snapshot(existing),
            )
        if budget.reserved_calls >= budget.max_physical_calls:
            raise PhysicalBudgetExceeded()
        budget.reserved_calls += 1
        record = PhysicalInvocationRecord(
            invocation_id=uuid.uuid4(),
            tenant_id=tenant_id,
            run_id=run_id,
            job_id=job_id,
            tool_call_id=tool_call_id,
            tool_name=tool_name,
            tool_version=tool_version,
            request_fingerprint=request_fingerprint,
            status="reserved",
            reservation_holder_id=holder_id,
            reservation_fencing_token=fencing_token,
            result_ref=None,
            result_digest=None,
            error_code=None,
            audit_receipt_id=audit_receipt_id,
            completion_holder_id=None,
            completion_fencing_token=None,
            completion_audit_receipt_id=None,
            completed_at=None,
        )
        self._session.add(record)
        self._session.flush()
        return InvocationReservation(decision="execute", invocation=_snapshot(record))

    def record_outcome(
        self,
        *,
        tenant_id: str,
        run_id: uuid.UUID,
        job_id: uuid.UUID,
        holder_id: str,
        fencing_token: int,
        tool_call_id: str,
        request_fingerprint: str,
        outcome: InvocationHandlerOutcome,
        audit_receipt_id: str,
    ) -> InvocationSnapshot:
        self._require_transaction()
        if (
            not tenant_id
            or not holder_id
            or not audit_receipt_id
            or fencing_token <= 0
            or TOOL_CALL_PATTERN.fullmatch(tool_call_id) is None
            or DIGEST_PATTERN.fullmatch(request_fingerprint) is None
        ):
            raise ValueError("physical invocation completion is invalid")
        JobsRepository(self._session).assert_fence(
            tenant_id=tenant_id,
            job_id=job_id,
            holder_id=holder_id,
            fencing_token=fencing_token,
        )
        record = self._session.execute(
            select(PhysicalInvocationRecord)
            .where(
                PhysicalInvocationRecord.run_id == run_id,
                PhysicalInvocationRecord.tenant_id == tenant_id,
                PhysicalInvocationRecord.tool_call_id == tool_call_id,
            )
            .with_for_update()
        ).scalar_one_or_none()
        if record is None:
            raise InvocationNotFound()
        if record.job_id != job_id or record.request_fingerprint != request_fingerprint:
            raise InvocationConflict()
        if record.status != "reserved":
            same_outcome = (
                record.status == outcome.status
                and record.result_ref == outcome.result_ref
                and record.result_digest == outcome.result_digest
                and record.error_code == outcome.error_code
            )
            if not same_outcome:
                raise InvocationConflict()
            return _snapshot(record)
        record.status = outcome.status
        record.result_ref = outcome.result_ref
        record.result_digest = outcome.result_digest
        record.error_code = outcome.error_code
        record.completion_holder_id = holder_id
        record.completion_fencing_token = fencing_token
        record.completion_audit_receipt_id = audit_receipt_id
        record.completed_at = func.statement_timestamp()
        self._session.flush()
        return _snapshot(record)


class PhysicalInvocationLedger:
    """Commit reservation before calling a handler; persist only bounded receipts."""

    def __init__(self, session_factory: sessionmaker[Session]) -> None:
        self._session_factory = session_factory

    @staticmethod
    def _set_tenant(session: Session, tenant_id: str) -> None:
        session.execute(select(func.set_config("app.tenant_id", tenant_id, True)))

    def reserve(self, **kwargs: object) -> InvocationReservation:
        tenant_id = str(kwargs.get("tenant_id", ""))
        with self._session_factory.begin() as session:
            self._set_tenant(session, tenant_id)
            return InvocationsRepository(session).reserve(**kwargs)  # type: ignore[arg-type]

    def record_outcome(self, **kwargs: object) -> InvocationSnapshot:
        tenant_id = str(kwargs.get("tenant_id", ""))
        with self._session_factory.begin() as session:
            self._set_tenant(session, tenant_id)
            return InvocationsRepository(session).record_outcome(  # type: ignore[arg-type]
                **kwargs
            )

    def invoke(
        self,
        *,
        tenant_id: str,
        run_id: uuid.UUID,
        job_id: uuid.UUID,
        holder_id: str,
        fencing_token: int,
        tool_call_id: str,
        tool_name: str,
        tool_version: str,
        request_fingerprint: str,
        max_physical_calls: int,
        reservation_audit_receipt_id: str,
        completion_audit_receipt_id: str,
        handler: Callable[[], InvocationHandlerOutcome],
        failure_injection_hook: Callable[[str], None] | None = None,
    ) -> InvocationExecution:
        reservation = self.reserve(
            tenant_id=tenant_id,
            run_id=run_id,
            job_id=job_id,
            holder_id=holder_id,
            fencing_token=fencing_token,
            tool_call_id=tool_call_id,
            tool_name=tool_name,
            tool_version=tool_version,
            request_fingerprint=request_fingerprint,
            max_physical_calls=max_physical_calls,
            audit_receipt_id=reservation_audit_receipt_id,
        )
        if reservation.decision != "execute":
            return InvocationExecution(
                decision=reservation.decision,
                invocation=reservation.invocation,
                handler_called=False,
            )
        if failure_injection_hook is not None:
            failure_injection_hook("after_reservation")
        outcome = handler()
        if not isinstance(outcome, InvocationHandlerOutcome):
            raise TypeError("physical invocation handler returned an invalid outcome")
        if failure_injection_hook is not None:
            failure_injection_hook("after_handler_before_persist")
        persisted = self.record_outcome(
            tenant_id=tenant_id,
            run_id=run_id,
            job_id=job_id,
            holder_id=holder_id,
            fencing_token=fencing_token,
            tool_call_id=tool_call_id,
            request_fingerprint=request_fingerprint,
            outcome=outcome,
            audit_receipt_id=completion_audit_receipt_id,
        )
        return InvocationExecution(
            decision="execute", invocation=persisted, handler_called=True
        )
