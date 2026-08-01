"""Five-state Evidence Gate with fail-closed, stable degradation reasons."""

from __future__ import annotations

from datetime import UTC, datetime, timedelta
from typing import Literal

from pydantic import BaseModel, ConfigDict, Field, model_validator


EvidenceStatus = Literal[
    "verified_current", "unverified", "stale", "conflicted", "invalid"
]
EvidenceReason = Literal[
    "evidence.repository_unavailable",
    "evidence.unverified",
    "evidence.stale",
    "evidence.conflicted",
    "evidence.payload_invalid",
]


class EvidenceObservation(BaseModel):
    model_config = ConfigDict(extra="forbid", frozen=True)

    evidence_id: str = Field(pattern=r"^ev_[a-z0-9_]{1,96}$")
    transport_succeeded: bool
    repository_available: bool
    payload_valid: bool
    independently_verified: bool
    observed_at: datetime | None = None
    max_age_seconds: int = Field(default=300, ge=1, le=86_400)
    conflicting_evidence_ids: tuple[str, ...] = ()

    @model_validator(mode="after")
    def require_aware_time(self) -> EvidenceObservation:
        if self.observed_at is not None and self.observed_at.tzinfo is None:
            raise ValueError("evidence.observed_at_timezone_required")
        return self


class EvidenceDecision(BaseModel):
    model_config = ConfigDict(extra="forbid", frozen=True)

    evidence_id: str
    status: EvidenceStatus
    supports_current_claim: bool
    reason_code: EvidenceReason | None


class EvidenceGate:
    """Classify evidence without treating transport success as truth."""

    def classify(
        self, observation: EvidenceObservation, *, now: datetime
    ) -> EvidenceDecision:
        if now.tzinfo is None:
            raise ValueError("evidence.now_timezone_required")
        normalized_now = now.astimezone(UTC)

        if not observation.repository_available:
            return self._decision(
                observation, "unverified", "evidence.repository_unavailable"
            )
        if not observation.payload_valid:
            return self._decision(observation, "invalid", "evidence.payload_invalid")
        if observation.conflicting_evidence_ids:
            return self._decision(observation, "conflicted", "evidence.conflicted")
        if not observation.independently_verified or observation.observed_at is None:
            return self._decision(observation, "unverified", "evidence.unverified")
        expires_at = observation.observed_at.astimezone(UTC) + timedelta(
            seconds=observation.max_age_seconds
        )
        if expires_at < normalized_now:
            return self._decision(observation, "stale", "evidence.stale")
        return EvidenceDecision(
            evidence_id=observation.evidence_id,
            status="verified_current",
            supports_current_claim=True,
            reason_code=None,
        )

    @staticmethod
    def _decision(
        observation: EvidenceObservation,
        status: Literal["unverified", "stale", "conflicted", "invalid"],
        reason_code: EvidenceReason,
    ) -> EvidenceDecision:
        return EvidenceDecision(
            evidence_id=observation.evidence_id,
            status=status,
            supports_current_claim=False,
            reason_code=reason_code,
        )
