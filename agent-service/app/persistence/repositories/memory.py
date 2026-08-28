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
    DeleteMemoryCommand,
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
        self._tombstones: dict[UUID, tuple[int, str]] = {}
        self._surface_status: dict[UUID, dict[str, bool]] = {}

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
            self._surface_status[memory_id] = {
                "record": False, "candidate": False, "index": False, "cache": False,
                "export": False, "eval_trace": False, "restore_ledger": False,
            }
            return receipt

    @staticmethod
    def delete_request_digest(command: DeleteMemoryCommand) -> str:
        return hashlib.sha256(json.dumps(command.model_dump(mode="json"), sort_keys=True, separators=(",", ":")).encode()).hexdigest()

    def delete_atomic(self, *, command: DeleteMemoryCommand, context: AuthorizationContext, now: datetime) -> MemoryCommandReceipt:
        digest = self.delete_request_digest(command)
        attempt_key = (context.tenant_id, context.principal_id, command.idempotency_key)
        with self._lock:
            prior = self._attempts.get(attempt_key)
            if prior is not None:
                if prior.request_digest != digest:
                    raise MemoryConflict("memory.idempotency_collision")
                return prior.receipt.model_copy(update={"outcome": "replayed", "replayed": True})
            match = next(
                ((slot, record) for slot, record in self._records.items() if record.memory_id == command.memory_id and record.tenant_id == context.tenant_id and record.principal_id == context.principal_id),
                None,
            )
            if match is None:
                raise MemoryNotFound("memory.record_not_found")
            slot, current = match
            if current.version != command.expected_version:
                raise MemoryConflict("memory.cas_conflict")
            generation = current.deletion_generation + 1
            deleted = current.model_copy(update={"state": MemoryState.DELETED, "version": current.version + 1, "deletion_generation": generation})
            event = MemoryOutboxEvent(
                event_id=uuid4(), tenant_id=context.tenant_id, principal_id=context.principal_id,
                aggregate_id=current.memory_id, event_type="memory.consent_revoked" if command.reason_code == "consent_withdrawal" else "memory.deleted",
                version=deleted.version, created_at=now,
            )
            receipt = MemoryCommandReceipt(
                command_id=command.command_id, idempotency_key=command.idempotency_key, request_digest=digest,
                outcome="deleted", memory_id=current.memory_id, version=deleted.version,
                outbox_event_id=event.event_id, replayed=False,
            )
            self._records[slot] = deleted
            for candidate_id, candidate in tuple(self._candidates.items()):
                if candidate.tenant_id == context.tenant_id and candidate.principal_id == context.principal_id and candidate.fact.purpose == current.fact.purpose and candidate.fact.memory_type == current.fact.memory_type:
                    self._candidates[candidate_id] = candidate.model_copy(update={"state": "deleted"})
            self._conflicts.pop(slot, None)
            self._tombstones[current.memory_id] = (generation, command.reason_code)
            self._surface_status[current.memory_id] = {name: True for name in ("record", "candidate", "index", "cache", "export", "eval_trace", "restore_ledger")}
            self._outbox.append(event)
            self._attempts[attempt_key] = _Attempt(digest, receipt)
            return receipt

    def active_records_for(self, *, tenant_id: str, principal_id: str, purpose: str) -> tuple[MemoryRecord, ...]:
        with self._lock:
            return tuple(record for record in self._records.values() if record.tenant_id == tenant_id and record.principal_id == principal_id and record.fact.purpose == purpose and record.state is MemoryState.ACTIVE and record.memory_id not in self._tombstones)

    def surface_status(self, memory_id: UUID) -> dict[str, bool]:
        with self._lock:
            return dict(self._surface_status.get(memory_id, {}))

    def restore_record(self, backup_record: MemoryRecord) -> MemoryRecord | None:
        """Tombstones win before a restored alias may become readable."""
        with self._lock:
            if backup_record.memory_id in self._tombstones:
                self._surface_status[backup_record.memory_id]["restore_ledger"] = True
                return None
            slot = (backup_record.tenant_id, backup_record.principal_id, backup_record.fact.purpose, backup_record.fact.memory_type)
            self._records[slot] = backup_record
            return backup_record

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
