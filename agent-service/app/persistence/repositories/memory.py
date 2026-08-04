"""Atomic repository contract and deterministic in-memory reference implementation."""

from __future__ import annotations

import hashlib
import json
from dataclasses import dataclass
from datetime import datetime
from threading import RLock
from uuid import UUID, uuid4

from app.memory.contracts import (
    AuthorizationContext,
    ConfirmMemoryCommand,
    ConsentGrant,
    MemoryCandidate,
    MemoryCommandReceipt,
    MemoryConflictView,
    MemoryOutboxEvent,
    MemoryRecord,
    MemoryState,
)


class MemoryConflict(RuntimeError):
    """CAS or idempotency collision with zero partial effects."""


class MemoryNotFound(LookupError):
    pass


@dataclass(frozen=True)
class _Attempt:
    request_digest: str
    receipt: MemoryCommandReceipt


class InMemoryMemoryRepository:
    """Thread-safe fake mirroring one database transaction for local contract tests."""

    def __init__(self) -> None:
        self._lock = RLock()
        self._candidates: dict[UUID, MemoryCandidate] = {}
        self._records: dict[tuple[str, str, str, str], MemoryRecord] = {}
        self._attempts: dict[tuple[str, str, str], _Attempt] = {}
        self._outbox: list[MemoryOutboxEvent] = []
        self._conflicts: dict[tuple[str, str, str, str], MemoryConflictView] = {}

    def save_candidate(self, candidate: MemoryCandidate) -> None:
        with self._lock:
            self._candidates[candidate.candidate_id] = candidate

    def get_candidate(self, candidate_id: UUID) -> MemoryCandidate:
        with self._lock:
            try:
                return self._candidates[candidate_id]
            except KeyError as exc:
                raise MemoryNotFound("memory.candidate_not_found") from exc

    @staticmethod
    def request_digest(command: ConfirmMemoryCommand, candidate: MemoryCandidate, consent: ConsentGrant) -> str:
        canonical = json.dumps(
            {"command": command.model_dump(mode="json"), "candidate": candidate.model_dump(mode="json"), "consent_version": consent.version},
            sort_keys=True, separators=(",", ":"),
        ).encode()
        return hashlib.sha256(canonical).hexdigest()

    def confirm_atomic(
        self, *, command: ConfirmMemoryCommand, candidate: MemoryCandidate, consent: ConsentGrant,
        context: AuthorizationContext, now: datetime,
    ) -> MemoryCommandReceipt:
        digest = self.request_digest(command, candidate, consent)
        attempt_key = (context.tenant_id, context.principal_id, command.idempotency_key)
        slot = (context.tenant_id, context.principal_id, candidate.fact.purpose, candidate.fact.memory_type)
        with self._lock:
            prior_attempt = self._attempts.get(attempt_key)
            if prior_attempt is not None:
                if prior_attempt.request_digest != digest:
                    raise MemoryConflict("memory.idempotency_collision")
                return prior_attempt.receipt.model_copy(update={"outcome": "replayed", "replayed": True})

            current = self._records.get(slot)
            current_version = current.version if current is not None else 0
            if current_version != command.expected_version:
                raise MemoryConflict("memory.cas_conflict")

            memory_id = current.memory_id if current is not None else uuid4()
            next_version = current_version + 1
            if current is not None and current.fact.value != candidate.fact.value:
                conflicted = current.model_copy(update={"state": MemoryState.CONFLICTED, "version": next_version})
                conflict_view = MemoryConflictView(
                    memory_id=memory_id, tenant_id=context.tenant_id, principal_id=context.principal_id,
                    purpose=candidate.fact.purpose, memory_type=candidate.fact.memory_type,
                    current_value=current.fact.value, competing_value=candidate.fact.value,
                    current_provenance=current.provenance, competing_provenance=candidate.provenance,
                )
                event = MemoryOutboxEvent(
                    event_id=uuid4(), tenant_id=context.tenant_id, principal_id=context.principal_id,
                    aggregate_id=memory_id, event_type="memory.conflicted", version=next_version, created_at=now,
                )
                receipt = MemoryCommandReceipt(
                    command_id=command.command_id, idempotency_key=command.idempotency_key,
                    request_digest=digest, outcome="conflicted", memory_id=memory_id, version=next_version,
                    outbox_event_id=event.event_id, replayed=False,
                )
                self._records[slot] = conflicted
                self._conflicts[slot] = conflict_view
                self._outbox.append(event)
                self._attempts[attempt_key] = _Attempt(digest, receipt)
                return receipt
            record = MemoryRecord(
                memory_id=memory_id, tenant_id=context.tenant_id, principal_id=context.principal_id,
                fact=candidate.fact, provenance=candidate.provenance, consent_version=consent.version,
                version=next_version, state=MemoryState.ACTIVE, retention_until=command.retention_until,
            )
            event = MemoryOutboxEvent(
                event_id=uuid4(), tenant_id=context.tenant_id, principal_id=context.principal_id,
                aggregate_id=memory_id, event_type="memory.updated" if current is not None else "memory.confirmed",
                version=next_version, created_at=now,
            )
            receipt = MemoryCommandReceipt(
                command_id=command.command_id, idempotency_key=command.idempotency_key,
                request_digest=digest, outcome="applied", memory_id=memory_id, version=next_version,
                outbox_event_id=event.event_id, replayed=False,
            )
            self._records[slot] = record
            self._candidates[candidate.candidate_id] = candidate.model_copy(update={"state": "confirmed"})
            self._outbox.append(event)
            self._attempts[attempt_key] = _Attempt(digest, receipt)
            return receipt

    def record_for(self, *, tenant_id: str, principal_id: str, purpose: str, memory_type: str) -> MemoryRecord | None:
        with self._lock:
            return self._records.get((tenant_id, principal_id, purpose, memory_type))

    def conflict_for(self, *, tenant_id: str, principal_id: str, purpose: str, memory_type: str) -> MemoryConflictView | None:
        with self._lock:
            return self._conflicts.get((tenant_id, principal_id, purpose, memory_type))

    @property
    def outbox_events(self) -> tuple[MemoryOutboxEvent, ...]:
        with self._lock:
            return tuple(self._outbox)
