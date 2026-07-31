"""Transactional repositories for Thread, Run, and idempotency records."""

from __future__ import annotations

import re
import uuid
from dataclasses import dataclass
from typing import Any

from sqlalchemy import func, select, update
from sqlalchemy.dialects.postgresql import insert
from sqlalchemy.orm import Session

from app.persistence.models.runtime import (
    IdempotencyRecord,
    RunRecord,
    RunState,
    ThreadRecord,
)


SHA256_PATTERN = re.compile(r"^[0-9a-f]{64}$")

ALLOWED_TRANSITIONS: dict[RunState, frozenset[RunState]] = {
    RunState.CREATED: frozenset({RunState.QUEUED}),
    RunState.QUEUED: frozenset(
        {RunState.RUNNING, RunState.CANCELLING, RunState.BLOCKED, RunState.FAILED}
    ),
    RunState.RUNNING: frozenset(
        {
            RunState.WAITING_INPUT,
            RunState.RECOVERING,
            RunState.CANCELLING,
            RunState.SUCCEEDED,
            RunState.BLOCKED,
            RunState.FAILED,
        }
    ),
    RunState.WAITING_INPUT: frozenset(
        {RunState.RESUMING, RunState.CANCELLING, RunState.BLOCKED, RunState.FAILED}
    ),
    RunState.RESUMING: frozenset(
        {
            RunState.RUNNING,
            RunState.CANCELLING,
            RunState.SUCCEEDED,
            RunState.BLOCKED,
            RunState.FAILED,
        }
    ),
    RunState.RECOVERING: frozenset(
        {
            RunState.RUNNING,
            RunState.CANCELLING,
            RunState.SUCCEEDED,
            RunState.BLOCKED,
            RunState.FAILED,
        }
    ),
    RunState.CANCELLING: frozenset({RunState.CANCELLED}),
    RunState.SUCCEEDED: frozenset(),
    RunState.BLOCKED: frozenset(),
    RunState.FAILED: frozenset(),
    RunState.CANCELLED: frozenset(),
}


class TransactionRequired(RuntimeError):
    code = "runtime.transaction_required"

    def __init__(self) -> None:
        super().__init__(self.code)


class RuntimeRecordNotFound(RuntimeError):
    code = "runtime.not_found"

    def __init__(self) -> None:
        super().__init__(self.code)


class IdempotencyConflict(RuntimeError):
    code = "idempotency.conflict"

    def __init__(self) -> None:
        super().__init__(self.code)


class RunStateConflict(RuntimeError):
    code = "run.state_conflict"

    def __init__(self) -> None:
        super().__init__(self.code)


@dataclass(frozen=True, slots=True)
class RunCreateResult:
    run_id: uuid.UUID
    state: RunState
    replayed: bool


class RunsRepository:
    """A session-bound repository; callers own the surrounding transaction."""

    def __init__(self, session: Session) -> None:
        self._session = session

    def _require_transaction(self) -> None:
        if not self._session.in_transaction():
            raise TransactionRequired()

    def create_thread(
        self,
        *,
        tenant_id: str,
        owner_principal_id: str,
        thread_id: uuid.UUID | None = None,
    ) -> ThreadRecord:
        self._require_transaction()
        if not tenant_id or not owner_principal_id:
            raise ValueError("tenant_id and owner_principal_id are required")
        record = ThreadRecord(
            thread_id=thread_id or uuid.uuid4(),
            tenant_id=tenant_id,
            owner_principal_id=owner_principal_id,
        )
        self._session.add(record)
        self._session.flush()
        return record

    def create_or_replay_run(
        self,
        *,
        tenant_id: str,
        principal_id: str,
        thread_id: uuid.UUID,
        request_scope: str,
        idempotency_key: str,
        request_hash: str,
        manifest_digest: str,
        manifest: dict[str, Any],
        run_id: uuid.UUID | None = None,
    ) -> RunCreateResult:
        self._require_transaction()
        if not all((tenant_id, principal_id, request_scope, idempotency_key)):
            raise ValueError("tenant, principal, scope, and idempotency key are required")
        if SHA256_PATTERN.fullmatch(request_hash) is None:
            raise ValueError("request_hash must be lowercase SHA-256")
        if SHA256_PATTERN.fullmatch(manifest_digest) is None:
            raise ValueError("manifest_digest must be lowercase SHA-256")

        thread_exists = self._session.execute(
            select(ThreadRecord.thread_id).where(
                ThreadRecord.thread_id == thread_id,
                ThreadRecord.tenant_id == tenant_id,
            )
        ).scalar_one_or_none()
        if thread_exists is None:
            raise RuntimeRecordNotFound()

        candidate_run_id = run_id or uuid.uuid4()
        reservation = (
            insert(IdempotencyRecord)
            .values(
                idempotency_id=uuid.uuid4(),
                tenant_id=tenant_id,
                principal_id=principal_id,
                request_scope=request_scope,
                idempotency_key=idempotency_key,
                request_hash=request_hash,
                run_id=candidate_run_id,
            )
            .on_conflict_do_nothing(constraint="uq_idempotency_request_key")
            .returning(IdempotencyRecord.run_id)
        )
        reserved_run_id = self._session.execute(reservation).scalar_one_or_none()
        if reserved_run_id is None:
            existing = self._session.execute(
                select(IdempotencyRecord).where(
                    IdempotencyRecord.tenant_id == tenant_id,
                    IdempotencyRecord.principal_id == principal_id,
                    IdempotencyRecord.request_scope == request_scope,
                    IdempotencyRecord.idempotency_key == idempotency_key,
                )
            ).scalar_one()
            if existing.request_hash != request_hash:
                raise IdempotencyConflict()
            state = self._session.execute(
                select(RunRecord.state).where(
                    RunRecord.run_id == existing.run_id,
                    RunRecord.tenant_id == tenant_id,
                )
            ).scalar_one()
            return RunCreateResult(
                run_id=existing.run_id,
                state=RunState(state),
                replayed=True,
            )

        record = RunRecord(
            run_id=reserved_run_id,
            thread_id=thread_id,
            tenant_id=tenant_id,
            principal_id=principal_id,
            state=RunState.CREATED.value,
            manifest_digest=manifest_digest,
            manifest=manifest,
            next_event_seq=1,
            version=0,
        )
        self._session.add(record)
        self._session.flush()
        record.state = RunState.QUEUED.value
        record.version = 1
        record.updated_at = func.statement_timestamp()
        self._session.flush()
        return RunCreateResult(
            run_id=record.run_id,
            state=RunState.QUEUED,
            replayed=False,
        )

    def transition_state(
        self,
        *,
        tenant_id: str,
        run_id: uuid.UUID,
        expected_state: RunState,
        expected_version: int,
        target_state: RunState,
    ) -> RunRecord:
        self._require_transaction()
        if target_state not in ALLOWED_TRANSITIONS[expected_state]:
            raise RunStateConflict()
        statement = (
            update(RunRecord)
            .where(
                RunRecord.run_id == run_id,
                RunRecord.tenant_id == tenant_id,
                RunRecord.state == expected_state.value,
                RunRecord.version == expected_version,
            )
            .values(
                state=target_state.value,
                version=RunRecord.version + 1,
                updated_at=func.statement_timestamp(),
            )
            .returning(RunRecord)
        )
        record = self._session.execute(statement).scalar_one_or_none()
        if record is None:
            raise RunStateConflict()
        return record
