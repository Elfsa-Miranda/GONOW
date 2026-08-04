from datetime import UTC, datetime, timedelta
from uuid import uuid4

import pytest
from pydantic import ValidationError

from app.memory.contracts import AuthorizationContext, ConfirmMemoryCommand, ConsentGrant, ConsentState, MemoryFact, MemoryPurpose, Provenance, SourceType
from app.memory.service import StructuredMemoryService
from app.persistence.repositories.memory import InMemoryMemoryRepository, MemoryConflict


NOW = datetime(2026, 8, 5, tzinfo=UTC)


def setup() -> tuple[StructuredMemoryService, InMemoryMemoryRepository, AuthorizationContext, ConsentGrant]:
    repository = InMemoryMemoryRepository()
    context = AuthorizationContext(tenant_id="tenant-a", principal_id="user-a", purpose=MemoryPurpose.ITINERARY_PERSONALIZATION, identity_verified=True, server_authorized=True)
    consent = ConsentGrant(state=ConsentState.GRANTED, purpose=MemoryPurpose.ITINERARY_PERSONALIZATION, version=3, valid_until=NOW + timedelta(days=30))
    return StructuredMemoryService(repository), repository, context, consent


def propose(service: StructuredMemoryService, context: AuthorizationContext, consent: ConsentGrant):
    return service.propose_candidate(fact=MemoryFact(memory_type="travel_pace", value="balanced"), provenance=Provenance(source_type=SourceType.USER_DECLARED, source_ref="ui:memory-form", source_digest="b" * 64, recorded_at=NOW), consent=consent, context=context, now=NOW)


def command(candidate_id, **changes: object) -> ConfirmMemoryCommand:
    values = dict(command_id=uuid4(), candidate_id=candidate_id, idempotency_key="memory-command-1", expected_version=0, confirmed_by_user=True, retention_until=NOW + timedelta(days=30))
    values.update(changes)
    return ConfirmMemoryCommand(**values)


def test_confirm_writes_record_receipt_and_outbox_atomically() -> None:
    service, repository, context, consent = setup()
    candidate = propose(service, context, consent)
    receipt = service.confirm_candidate(command=command(candidate.candidate_id), consent=consent, context=context, now=NOW)
    record = repository.record_for(tenant_id="tenant-a", principal_id="user-a", purpose="itinerary.personalization", memory_type="travel_pace")
    assert receipt.outcome == "applied" and receipt.version == 1
    assert record is not None and record.consent_version == 3
    assert len(repository.outbox_events) == 1 and repository.outbox_events[0].event_id == receipt.outbox_event_id


def test_identical_idempotent_replay_has_no_second_effect() -> None:
    service, repository, context, consent = setup()
    candidate = propose(service, context, consent)
    cmd = command(candidate.candidate_id)
    first = service.confirm_candidate(command=cmd, consent=consent, context=context, now=NOW)
    replay = repository.confirm_atomic(command=cmd, candidate=candidate, consent=consent, context=context, now=NOW)
    assert first.memory_id == replay.memory_id and replay.replayed
    assert len(repository.outbox_events) == 1


def test_same_idempotency_key_different_body_conflicts_without_effect() -> None:
    service, repository, context, consent = setup()
    candidate = propose(service, context, consent)
    first = command(candidate.candidate_id)
    service.confirm_candidate(command=first, consent=consent, context=context, now=NOW)
    changed = first.model_copy(update={"command_id": uuid4(), "retention_until": NOW + timedelta(days=31)})
    with pytest.raises(MemoryConflict, match="idempotency_collision"):
        repository.confirm_atomic(command=changed, candidate=candidate, consent=consent, context=context, now=NOW)
    assert len(repository.outbox_events) == 1


def test_stale_cas_has_zero_effect() -> None:
    service, repository, context, consent = setup()
    candidate = propose(service, context, consent)
    with pytest.raises(MemoryConflict, match="cas_conflict"):
        service.confirm_candidate(command=command(candidate.candidate_id, expected_version=1), consent=consent, context=context, now=NOW)
    assert repository.record_for(tenant_id="tenant-a", principal_id="user-a", purpose="itinerary.personalization", memory_type="travel_pace") is None
    assert repository.outbox_events == ()


def test_cross_principal_confirmation_is_denied() -> None:
    service, repository, context, consent = setup()
    candidate = propose(service, context, consent)
    intruder = context.model_copy(update={"principal_id": "user-b"})
    with pytest.raises(PermissionError, match="candidate_authority_mismatch"):
        service.confirm_candidate(command=command(candidate.candidate_id), consent=consent, context=intruder, now=NOW)
    assert repository.outbox_events == ()


def test_confirmation_must_be_literal_true_and_retention_is_bounded() -> None:
    service, repository, context, consent = setup()
    candidate = propose(service, context, consent)
    with pytest.raises(ValidationError):
        command(candidate.candidate_id, confirmed_by_user=False)
    with pytest.raises(ValueError, match="retention_out_of_bounds"):
        service.confirm_candidate(command=command(candidate.candidate_id, retention_until=NOW + timedelta(days=366)), consent=consent, context=context, now=NOW)
    assert repository.outbox_events == ()
