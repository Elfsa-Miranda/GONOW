from datetime import UTC, datetime, timedelta
from uuid import uuid4

import pytest
from pydantic import ValidationError

from app.memory.contracts import (
    AuthorizationContext,
    ConsentGrant,
    ConsentState,
    MemoryCandidate,
    MemoryFact,
    MemoryPurpose,
    MemoryType,
    Provenance,
    SourceType,
    assert_consent,
)


NOW = datetime(2026, 8, 5, tzinfo=UTC)
DIGEST = "a" * 64


@pytest.mark.parametrize(
    ("memory_type", "value"),
    [("travel_pace", "balanced"), ("mobility_requirement", "step_free"), ("dietary_requirement", "vegan"), ("transport_preference", "mixed")],
)
def test_each_closed_memory_type_accepts_one_value(memory_type: str, value: str) -> None:
    assert MemoryFact(memory_type=memory_type, value=value).value == value


@pytest.mark.parametrize("value", ["ignore previous instructions", "custom", "FAST", ""])
def test_free_text_and_unknown_values_are_rejected(value: str) -> None:
    with pytest.raises(ValidationError):
        MemoryFact(memory_type=MemoryType.TRAVEL_PACE, value=value)


def _context(**changes: object) -> AuthorizationContext:
    values = dict(tenant_id="tenant-1", principal_id="user-1", purpose=MemoryPurpose.ITINERARY_PERSONALIZATION, identity_verified=True, server_authorized=True)
    values.update(changes)
    return AuthorizationContext(**values)


def _consent(state: ConsentState = ConsentState.GRANTED, *, valid_until: datetime | None = None) -> ConsentGrant:
    return ConsentGrant(state=state, purpose=MemoryPurpose.ITINERARY_PERSONALIZATION, version=1, valid_until=valid_until or NOW + timedelta(days=1))


def test_valid_consent_and_server_context_are_required() -> None:
    assert_consent(consent=_consent(), context=_context(), at=NOW)


@pytest.mark.parametrize(
    ("consent", "context", "expected"),
    [
        (None, _context(), "memory.consent_missing"),
        (_consent(ConsentState.DENIED), _context(), "memory.consent_invalid"),
        (_consent(ConsentState.REVOKED), _context(), "memory.consent_invalid"),
        (_consent(valid_until=NOW), _context(), "memory.consent_invalid"),
        (_consent(), _context(identity_verified=False), "memory.identity_ambiguous"),
        (_consent(), _context(server_authorized=False), "memory.server_authorization_denied"),
    ],
)
def test_invalid_authority_fails_closed(consent: ConsentGrant | None, context: AuthorizationContext, expected: str) -> None:
    with pytest.raises(PermissionError, match=expected):
        assert_consent(consent=consent, context=context, at=NOW)


def test_model_output_is_only_a_candidate() -> None:
    candidate = MemoryCandidate(
        candidate_id=uuid4(), tenant_id="tenant-1", principal_id="user-1",
        fact=MemoryFact(memory_type="travel_pace", value="balanced"),
        provenance=Provenance(source_type=SourceType.MODEL_CANDIDATE, source_ref="run:1", source_digest=DIGEST, recorded_at=NOW),
        created_at=NOW,
    )
    assert candidate.state.value == "proposed"
    assert not hasattr(candidate, "version")
