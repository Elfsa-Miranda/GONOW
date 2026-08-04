from datetime import UTC, datetime, timedelta

import pytest

from app.memory.contracts import AuthorizationContext, ConsentGrant, ConsentState, MemoryFact, MemoryPurpose, Provenance, SourceType
from app.memory.service import StructuredMemoryService
from app.persistence.repositories.memory import InMemoryMemoryRepository


NOW = datetime(2026, 8, 5, tzinfo=UTC)


def context(**changes: object) -> AuthorizationContext:
    values = dict(tenant_id="tenant-a", principal_id="user-a", purpose=MemoryPurpose.ITINERARY_PERSONALIZATION, identity_verified=True, server_authorized=True)
    values.update(changes)
    return AuthorizationContext(**values)


def consent(state: ConsentState = ConsentState.GRANTED, *, expiry: datetime | None = None) -> ConsentGrant:
    return ConsentGrant(state=state, purpose=MemoryPurpose.ITINERARY_PERSONALIZATION, version=2, valid_until=expiry or NOW + timedelta(days=30))


def provenance() -> Provenance:
    return Provenance(source_type=SourceType.USER_DECLARED, source_ref="ui:memory-form", source_digest="a" * 64, recorded_at=NOW)


@pytest.mark.parametrize("grant", [None, consent(ConsentState.DENIED), consent(ConsentState.REVOKED), consent(ConsentState.EXPIRED), consent(expiry=NOW)])
def test_ct009_negative_or_missing_consent_rejects_candidate_write(grant: ConsentGrant | None) -> None:
    service = StructuredMemoryService(InMemoryMemoryRepository())
    with pytest.raises(PermissionError):
        service.propose_candidate(fact=MemoryFact(memory_type="travel_pace", value="balanced"), provenance=provenance(), consent=grant, context=context(), now=NOW)


@pytest.mark.parametrize("ctx", [context(identity_verified=False), context(server_authorized=False)])
def test_unknown_identity_or_server_denial_rejects_candidate_write(ctx: AuthorizationContext) -> None:
    service = StructuredMemoryService(InMemoryMemoryRepository())
    with pytest.raises(PermissionError):
        service.propose_candidate(fact=MemoryFact(memory_type="travel_pace", value="balanced"), provenance=provenance(), consent=consent(), context=ctx, now=NOW)


def test_valid_consent_creates_candidate_not_formal_memory() -> None:
    repository = InMemoryMemoryRepository()
    service = StructuredMemoryService(repository)
    candidate = service.propose_candidate(fact=MemoryFact(memory_type="travel_pace", value="balanced"), provenance=provenance(), consent=consent(), context=context(), now=NOW)
    assert candidate.state.value == "proposed"
    assert repository.record_for(tenant_id="tenant-a", principal_id="user-a", purpose="itinerary.personalization", memory_type="travel_pace") is None
    assert repository.outbox_events == ()
