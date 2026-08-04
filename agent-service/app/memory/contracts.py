"""Strict contracts for explicit user-visible Memory.

No free-form content is accepted. A model may construct a candidate, but only the
command service can create a formal record after user confirmation.
"""

from __future__ import annotations

from datetime import UTC, datetime
from enum import StrEnum
from typing import Annotated, Literal
from uuid import UUID

from pydantic import BaseModel, ConfigDict, Field, StringConstraints, model_validator


SafeIdentifier = Annotated[str, StringConstraints(min_length=1, max_length=256, pattern=r"^[A-Za-z0-9][A-Za-z0-9_.:@/-]*$")]
Sha256 = Annotated[str, StringConstraints(pattern=r"^[0-9a-f]{64}$")]


class MemoryPurpose(StrEnum):
    ITINERARY_PERSONALIZATION = "itinerary.personalization"


class MemoryType(StrEnum):
    TRAVEL_PACE = "travel_pace"
    MOBILITY_REQUIREMENT = "mobility_requirement"
    DIETARY_REQUIREMENT = "dietary_requirement"
    TRANSPORT_PREFERENCE = "transport_preference"


class ConsentState(StrEnum):
    GRANTED = "granted"
    DENIED = "denied"
    REVOKED = "revoked"
    EXPIRED = "expired"


class MemoryState(StrEnum):
    ACTIVE = "active"
    CONFLICTED = "conflicted"
    SUPERSEDED = "superseded"
    REVOKED = "revoked"
    DELETED = "deleted"
    QUARANTINED = "quarantined"


class CandidateState(StrEnum):
    PROPOSED = "proposed"
    CONFIRMED = "confirmed"
    REJECTED = "rejected"
    DELETED = "deleted"


class SourceType(StrEnum):
    USER_DECLARED = "user_declared"
    MODEL_CANDIDATE = "model_candidate"


MEMORY_VALUES: dict[MemoryType, frozenset[str]] = {
    MemoryType.TRAVEL_PACE: frozenset({"relaxed", "balanced", "fast"}),
    MemoryType.MOBILITY_REQUIREMENT: frozenset({"none", "step_free", "limited_walking"}),
    MemoryType.DIETARY_REQUIREMENT: frozenset({"none", "vegetarian", "vegan", "halal", "kosher", "gluten_free"}),
    MemoryType.TRANSPORT_PREFERENCE: frozenset({"public_transit", "walking", "taxi", "mixed"}),
}


class StrictModel(BaseModel):
    model_config = ConfigDict(extra="forbid", frozen=True, str_strip_whitespace=True)


class MemoryFact(StrictModel):
    memory_type: MemoryType
    value: Annotated[str, StringConstraints(min_length=1, max_length=32, pattern=r"^[a-z_]+$")]
    purpose: Literal[MemoryPurpose.ITINERARY_PERSONALIZATION] = MemoryPurpose.ITINERARY_PERSONALIZATION

    @model_validator(mode="after")
    def validate_closed_enum(self) -> "MemoryFact":
        if self.value not in MEMORY_VALUES[self.memory_type]:
            raise ValueError("memory.value_not_allowed")
        return self


class Provenance(StrictModel):
    source_type: SourceType
    source_ref: SafeIdentifier
    source_digest: Sha256
    recorded_at: datetime


class ConsentGrant(StrictModel):
    state: ConsentState
    purpose: Literal[MemoryPurpose.ITINERARY_PERSONALIZATION]
    version: Annotated[int, Field(ge=1)]
    valid_until: datetime

    def permits(self, *, at: datetime, purpose: MemoryPurpose) -> bool:
        normalized_at = at if at.tzinfo is not None else at.replace(tzinfo=UTC)
        normalized_expiry = self.valid_until if self.valid_until.tzinfo is not None else self.valid_until.replace(tzinfo=UTC)
        return self.state is ConsentState.GRANTED and self.purpose == purpose and normalized_expiry > normalized_at


class MemoryCandidate(StrictModel):
    candidate_id: UUID
    tenant_id: SafeIdentifier
    principal_id: SafeIdentifier
    fact: MemoryFact
    provenance: Provenance
    state: CandidateState = CandidateState.PROPOSED
    created_at: datetime


class MemoryRecord(StrictModel):
    memory_id: UUID
    tenant_id: SafeIdentifier
    principal_id: SafeIdentifier
    fact: MemoryFact
    provenance: Provenance
    consent_version: Annotated[int, Field(ge=1)]
    version: Annotated[int, Field(ge=1)]
    state: MemoryState
    retention_until: datetime
    deletion_generation: Annotated[int, Field(ge=0)] = 0


class AuthorizationContext(StrictModel):
    tenant_id: SafeIdentifier
    principal_id: SafeIdentifier
    purpose: Literal[MemoryPurpose.ITINERARY_PERSONALIZATION]
    identity_verified: bool
    server_authorized: bool


def assert_consent(*, consent: ConsentGrant | None, context: AuthorizationContext, at: datetime) -> None:
    if not context.identity_verified:
        raise PermissionError("memory.identity_ambiguous")
    if not context.server_authorized:
        raise PermissionError("memory.server_authorization_denied")
    if consent is None:
        raise PermissionError("memory.consent_missing")
    if not consent.permits(at=at, purpose=MemoryPurpose(context.purpose)):
        raise PermissionError("memory.consent_invalid")
