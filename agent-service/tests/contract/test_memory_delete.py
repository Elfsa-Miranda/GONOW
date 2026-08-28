from datetime import UTC, datetime, timedelta
from uuid import uuid4

import pytest

from app.memory.contracts import AuthorizationContext, ConfirmMemoryCommand, ConsentGrant, ConsentState, DeleteMemoryCommand, MemoryFact, MemoryPurpose, Provenance, SourceType
from app.memory.service import StructuredMemoryService
from app.persistence.repositories.memory import InMemoryMemoryRepository


NOW = datetime(2026, 8, 5, tzinfo=UTC)


def ready_record():
    repo = InMemoryMemoryRepository(); service = StructuredMemoryService(repo)
    context = AuthorizationContext(tenant_id="tenant-a", principal_id="user-a", purpose=MemoryPurpose.ITINERARY_PERSONALIZATION, identity_verified=True, server_authorized=True)
    consent = ConsentGrant(state=ConsentState.GRANTED, purpose=MemoryPurpose.ITINERARY_PERSONALIZATION, version=1, valid_until=NOW + timedelta(days=30))
    candidate = service.propose_candidate(fact=MemoryFact(memory_type="dietary_requirement", value="vegan"), provenance=Provenance(source_type=SourceType.USER_DECLARED, source_ref="ui:memory-form", source_digest="c" * 64, recorded_at=NOW), consent=consent, context=context, now=NOW)
    receipt = service.confirm_candidate(command=ConfirmMemoryCommand(command_id=uuid4(), candidate_id=candidate.candidate_id, idempotency_key="confirm-1", expected_version=0, confirmed_by_user=True, retention_until=NOW + timedelta(days=30)), consent=consent, context=context, now=NOW)
    return service, repo, context, consent, receipt.memory_id


def delete_command(memory_id, **changes):
    values = dict(command_id=uuid4(), memory_id=memory_id, idempotency_key="delete-1", expected_version=1, confirmed_by_user=True, reason_code="user_delete")
    values.update(changes)
    return DeleteMemoryCommand(**values)


def test_ct015_delete_fans_out_to_every_declared_surface() -> None:
    service, repo, context, consent, memory_id = ready_record()
    receipt = service.delete_memory(command=delete_command(memory_id), context=context, now=NOW)
    assert receipt.outcome == "deleted"
    assert repo.surface_status(memory_id) == {name: True for name in ("record", "candidate", "index", "cache", "export", "eval_trace", "restore_ledger")}
    assert service.export_memories(consent=consent, context=context, now=NOW).records == ()


def test_consent_withdrawal_uses_same_irreversible_delete_path() -> None:
    service, repo, context, _, memory_id = ready_record()
    receipt = service.delete_memory(command=delete_command(memory_id, reason_code="consent_withdrawal"), context=context, now=NOW)
    assert receipt.outcome == "deleted"
    assert repo.outbox_events[-1].event_type == "memory.consent_revoked"


@pytest.mark.parametrize("context_change", [{"identity_verified": False}, {"server_authorized": False}, {"principal_id": "user-b"}])
def test_delete_denies_unknown_identity_server_or_wrong_principal(context_change) -> None:
    service, repo, context, _, memory_id = ready_record()
    denied = context.model_copy(update=context_change)
    with pytest.raises((PermissionError, LookupError)):
        service.delete_memory(command=delete_command(memory_id), context=denied, now=NOW)
    assert any(not deleted for deleted in repo.surface_status(memory_id).values())


def test_export_requires_current_consent() -> None:
    service, _, context, _, _ = ready_record()
    with pytest.raises(PermissionError):
        service.export_memories(consent=None, context=context, now=NOW)
