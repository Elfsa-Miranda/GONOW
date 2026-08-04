"""Authorized Structured Memory candidate and confirmation service."""

from __future__ import annotations

from datetime import UTC, datetime, timedelta
from uuid import uuid4

from app.memory.contracts import (
    AuthorizationContext,
    CandidateState,
    ConfirmMemoryCommand,
    ConsentGrant,
    MemoryCandidate,
    MemoryCommandReceipt,
    MemoryFact,
    Provenance,
    assert_consent,
)
from app.persistence.repositories.memory import InMemoryMemoryRepository


MAX_RETENTION = timedelta(days=365)


class StructuredMemoryService:
    def __init__(self, repository: InMemoryMemoryRepository) -> None:
        self._repository = repository

    def propose_candidate(
        self, *, fact: MemoryFact, provenance: Provenance, consent: ConsentGrant | None,
        context: AuthorizationContext, now: datetime | None = None,
    ) -> MemoryCandidate:
        at = now or datetime.now(UTC)
        assert_consent(consent=consent, context=context, at=at)
        candidate = MemoryCandidate(
            candidate_id=uuid4(), tenant_id=context.tenant_id, principal_id=context.principal_id,
            fact=fact, provenance=provenance, state=CandidateState.PROPOSED, created_at=at,
        )
        self._repository.save_candidate(candidate)
        return candidate

    def confirm_candidate(
        self, *, command: ConfirmMemoryCommand, consent: ConsentGrant | None,
        context: AuthorizationContext, now: datetime | None = None,
    ) -> MemoryCommandReceipt:
        at = now or datetime.now(UTC)
        assert_consent(consent=consent, context=context, at=at)
        candidate = self._repository.get_candidate(command.candidate_id)
        if candidate.tenant_id != context.tenant_id or candidate.principal_id != context.principal_id:
            raise PermissionError("memory.candidate_authority_mismatch")
        if candidate.state is not CandidateState.PROPOSED:
            raise PermissionError("memory.candidate_not_proposed")
        if command.retention_until <= at or command.retention_until > at + MAX_RETENTION:
            raise ValueError("memory.retention_out_of_bounds")
        return self._repository.confirm_atomic(command=command, candidate=candidate, consent=consent, context=context, now=at)
