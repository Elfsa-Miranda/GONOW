"""Authenticated, idempotent Run/Job creation transaction."""

from __future__ import annotations

from collections.abc import Callable
from dataclasses import dataclass
from datetime import UTC, datetime, timedelta
import hashlib
from typing import Any, Protocol
from uuid import UUID

from sqlalchemy import func, select
from sqlalchemy.orm import Session, sessionmaker

from app.auth.context import AuthorizationPolicy, RequestContext
from app.persistence.repositories.events import EventsRepository
from app.persistence.repositories.job_inputs import JobInputsRepository
from app.persistence.repositories.jobs import JobsRepository
from app.persistence.repositories.runs import (
    IdempotencyConflict,
    RunCreateResult,
    RunsRepository,
)
from app.runtime.behavior_manifest import canonicalize_jcs
from app.runtime.behavior_package import RunBehaviorPin


RUN_START_ACTION = "run.create"
RUN_START_SCOPE = "itinerary_planning"
JOB_TYPE = "itinerary_planning"


class RunBehaviorPinProvider(Protocol):
    def pin(self) -> RunBehaviorPin: ...


class RunStartRejected(RuntimeError):
    code = "run.start_rejected"

    def __init__(self) -> None:
        super().__init__(self.code)


@dataclass(frozen=True, slots=True)
class RunStartResult:
    run_id: UUID
    thread_id: UUID
    state: str
    version: int
    replayed: bool
    behavior_digest: str


Clock = Callable[[], datetime]


def _utc_now() -> datetime:
    return datetime.now(UTC)


def _audit_receipt(context: RequestContext, request_hash: str) -> str:
    return hashlib.sha256(
        (
            "gonow:run-start:"
            + context.tenant_id
            + ":"
            + context.principal_id
            + ":"
            + context.trace_id
            + ":"
            + request_hash
        ).encode("utf-8")
    ).hexdigest()


class RunStartService:
    def __init__(
        self,
        session_factory: sessionmaker[Session],
        *,
        behavior_pin: RunBehaviorPinProvider,
        policy: AuthorizationPolicy | None = None,
        clock: Clock = _utc_now,
        input_retention: timedelta = timedelta(days=30),
    ) -> None:
        if input_retention < timedelta(hours=1) or input_retention > timedelta(days=90):
            raise ValueError("run input retention must be between one hour and 90 days")
        self._session_factory = session_factory
        self._behavior_pin = behavior_pin
        self._policy = policy or AuthorizationPolicy()
        self._clock = clock
        self._input_retention = input_retention

    def start(
        self,
        *,
        context: RequestContext,
        thread_id: UUID,
        idempotency_key: str,
        structured_input: dict[str, Any],
    ) -> RunStartResult:
        self._policy.authorize(
            context,
            action=RUN_START_ACTION,
            resource_tenant_id=context.tenant_id,
            requested_fields={"structured_input"},
            allowed_fields={"structured_input"},
            approval_valid=True,
        )
        now = self._clock()
        if now.tzinfo is None or now.utcoffset() is None:
            raise RunStartRejected()
        canonical = canonicalize_jcs(structured_input)
        request_hash = hashlib.sha256(canonical).hexdigest()
        input_ref = f"job-input://sha256/{request_hash}"
        try:
            pin = self._behavior_pin.pin()
            with self._session_factory.begin() as session:
                session.execute(
                    select(func.set_config("app.tenant_id", context.tenant_id, True))
                )
                runs = RunsRepository(session)
                runs.get_or_create_thread(
                    tenant_id=context.tenant_id,
                    owner_principal_id=context.principal_id,
                    thread_id=thread_id,
                )
                JobInputsRepository(session).put(
                    tenant_id=context.tenant_id,
                    input_ref=input_ref,
                    input_sha256=request_hash,
                    payload=structured_input,
                    expires_at=now + self._input_retention,
                )
                created: RunCreateResult = runs.create_or_replay_run(
                    tenant_id=context.tenant_id,
                    principal_id=context.principal_id,
                    thread_id=thread_id,
                    request_scope=RUN_START_SCOPE,
                    idempotency_key=idempotency_key,
                    request_hash=request_hash,
                    manifest_digest=pin.behavior_digest,
                    manifest=pin.manifest_copy(),
                )
                if not created.replayed:
                    receipt = _audit_receipt(context, request_hash)
                    JobsRepository(session).create_job(
                        tenant_id=context.tenant_id,
                        run_id=created.run_id,
                        job_type=JOB_TYPE,
                        input_ref=input_ref,
                        audit_receipt_id=receipt,
                    )
                    EventsRepository(session).append(
                        tenant_id=context.tenant_id,
                        run_id=created.run_id,
                        event_type="run.created",
                        payload={
                            "state": created.state.value,
                            "behavior_digest": pin.behavior_digest,
                        },
                        audit_receipt_id=receipt,
                    )
            return RunStartResult(
                run_id=created.run_id,
                thread_id=thread_id,
                state=created.state.value,
                version=created.version,
                replayed=created.replayed,
                behavior_digest=created.manifest_digest,
            )
        except IdempotencyConflict:
            raise
        except RunStartRejected:
            raise
        except Exception as error:
            raise RunStartRejected() from error
