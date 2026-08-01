"""Strict AdoptCandidate command boundary.

The request model deliberately has no principal, tenant, role, raw row, or
force-overwrite field. Identity is derived from ``RequestContext`` and the
repository re-runs authorization immediately before the transactional write.
"""

from __future__ import annotations

import hashlib
import uuid
from datetime import date, datetime
from typing import Annotated, Callable, Literal, Protocol

from pydantic import BaseModel, ConfigDict, Field, StringConstraints, model_validator

from app.auth.context import AuthorizationPolicy, RequestContext
from app.runtime.behavior_manifest import canonicalize_jcs


SafeText = Annotated[
    str, StringConstraints(strip_whitespace=True, min_length=1, max_length=512)
]
ReferenceText = Annotated[
    str,
    StringConstraints(
        strip_whitespace=True, pattern=r"^[A-Za-z0-9][A-Za-z0-9_.:/-]{0,127}$"
    ),
]
NonceText = Annotated[str, StringConstraints(min_length=32, max_length=512)]


class StrictCommandModel(BaseModel):
    model_config = ConfigDict(extra="forbid", frozen=True, strict=True)


class CandidateActivity(StrictCommandModel):
    activity_id: uuid.UUID
    day_index: int = Field(ge=1, le=60)
    position: int = Field(ge=0, le=511)
    title: SafeText
    starts_at: datetime | None = None
    note: Annotated[str, StringConstraints(max_length=2_000)] | None = None
    evidence_ids: tuple[ReferenceText, ...] = Field(default=(), max_length=32)


class AdoptableItineraryCandidate(StrictCommandModel):
    candidate_id: uuid.UUID
    title: SafeText
    starts_on: date
    ends_on: date
    activities: tuple[CandidateActivity, ...] = Field(min_length=1, max_length=512)

    @model_validator(mode="after")
    def validate_candidate(self) -> "AdoptableItineraryCandidate":
        if self.ends_on < self.starts_on:
            raise ValueError("candidate.date_range_invalid")
        activity_ids = [activity.activity_id for activity in self.activities]
        if len(set(activity_ids)) != len(activity_ids):
            raise ValueError("candidate.activity_id_duplicate")
        positions = [
            (activity.day_index, activity.position) for activity in self.activities
        ]
        if len(set(positions)) != len(positions):
            raise ValueError("candidate.activity_position_duplicate")
        return self


class AdoptCandidateCommand(StrictCommandModel):
    schema_version: Literal["1.0"]
    command_id: uuid.UUID
    approval_id: uuid.UUID
    target_itinerary_id: uuid.UUID
    run_id: uuid.UUID
    expected_version: int = Field(ge=0)
    capability_nonce: NonceText
    candidate: AdoptableItineraryCandidate


class AdoptCandidateReceipt(StrictCommandModel):
    command_id: uuid.UUID
    approval_id: uuid.UUID
    candidate_id: uuid.UUID
    itinerary_id: uuid.UUID
    result_version: int = Field(ge=1)
    candidate_hash: Annotated[str, StringConstraints(pattern=r"^[0-9a-f]{64}$")]
    command_hash: Annotated[str, StringConstraints(pattern=r"^[0-9a-f]{64}$")]
    event_id: uuid.UUID
    outbox_id: uuid.UUID
    audit_receipt_id: ReferenceText
    replayed: bool


class AdoptCandidateRepository(Protocol):
    def adopt_candidate(
        self,
        *,
        context: RequestContext,
        command: AdoptCandidateCommand,
        candidate_hash: str,
        command_hash: str,
        candidate_snapshot: dict[str, object],
        activity_snapshots: tuple[dict[str, object], ...],
        commit_authorize: Callable[[], None],
    ) -> AdoptCandidateReceipt: ...


def _sha256(value: object) -> str:
    return hashlib.sha256(canonicalize_jcs(value)).hexdigest()


def candidate_snapshot(command: AdoptCandidateCommand) -> dict[str, object]:
    return command.candidate.model_dump(mode="json")


def candidate_hash(command: AdoptCandidateCommand) -> str:
    return _sha256(candidate_snapshot(command))


def command_hash(command: AdoptCandidateCommand, *, candidate_digest: str) -> str:
    return _sha256(
        {
            "action": "itinerary.adopt",
            "schema_version": command.schema_version,
            "run_id": str(command.run_id),
            "candidate_id": str(command.candidate.candidate_id),
            "candidate_hash": candidate_digest,
            "target_itinerary_id": str(command.target_itinerary_id),
            "expected_version": command.expected_version,
        }
    )


def activity_snapshots(command: AdoptCandidateCommand) -> tuple[dict[str, object], ...]:
    return tuple(
        activity.model_dump(mode="json") for activity in command.candidate.activities
    )


class ItineraryAdoptHandler:
    """Authorize, hash, and delegate one transactional Domain Command."""

    _ALLOWED_FIELDS = frozenset({"title", "starts_on", "ends_on", "activities"})

    def __init__(
        self,
        repository: AdoptCandidateRepository,
        policy: AuthorizationPolicy | None = None,
    ) -> None:
        self._repository = repository
        self._policy = policy or AuthorizationPolicy()

    def execute(
        self,
        *,
        context: RequestContext,
        command: AdoptCandidateCommand,
    ) -> AdoptCandidateReceipt:
        def authorize() -> None:
            self._policy.authorize(
                context,
                action="itinerary.adopt",
                resource_tenant_id=context.tenant_id,
                requested_fields=set(self._ALLOWED_FIELDS),
                allowed_fields=set(self._ALLOWED_FIELDS),
                approval_valid=True,
            )

        authorize()
        snapshot = candidate_snapshot(command)
        digest = _sha256(snapshot)
        fingerprint = command_hash(command, candidate_digest=digest)
        return self._repository.adopt_candidate(
            context=context,
            command=command,
            candidate_hash=digest,
            command_hash=fingerprint,
            candidate_snapshot=snapshot,
            activity_snapshots=activity_snapshots(command),
            commit_authorize=authorize,
        )
