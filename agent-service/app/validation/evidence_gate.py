"""Five-state Evidence Gate with fail-closed, stable degradation reasons."""

from __future__ import annotations

from datetime import UTC, datetime, timedelta
from enum import StrEnum
from typing import Literal

from pydantic import BaseModel, ConfigDict, Field, model_validator


SHA256_PATTERN = r"^[0-9a-f]{64}$"


class EvidenceError(ValueError):
    def __init__(self, code: str = "evidence.invalid") -> None:
        self.code = code
        super().__init__(code)


class CitationError(ValueError):
    def __init__(self, code: str = "citation.missing") -> None:
        self.code = code
        super().__init__(code)


class EvidenceStatus(StrEnum):
    VERIFIED_CURRENT = "verified_current"
    UNVERIFIED = "unverified"
    STALE = "stale"
    CONFLICTED = "conflicted"
    INVALID = "invalid"


EvidenceReason = Literal[
    "evidence.repository_unavailable",
    "evidence.unverified",
    "evidence.stale",
    "evidence.conflicted",
    "evidence.payload_invalid",
]


class EvidenceRecord(BaseModel):
    model_config = ConfigDict(extra="forbid", frozen=True)

    evidence_id: str = Field(pattern=r"^ev_[a-z0-9_-]{1,80}$")
    source_kind: str = Field(pattern=r"^(tool|model|validator)$")
    source_ref: str = Field(pattern=r"^evidence://[^\s]{1,480}$", max_length=512)
    sha256: str = Field(pattern=SHA256_PATTERN)
    claim_ids: tuple[str, ...] = Field(min_length=1)
    status: EvidenceStatus
    version: int = Field(ge=1)


class Citation(BaseModel):
    model_config = ConfigDict(extra="forbid", frozen=True)

    claim_id: str
    evidence_id: str
    source_ref: str
    sha256: str = Field(pattern=SHA256_PATTERN)


class EvidenceLedger:
    """Append immutable records; repository failure closes all factual claims."""

    def __init__(self, *, available: bool = True) -> None:
        self._available = available
        self._records: dict[str, EvidenceRecord] = {}

    def append(self, record: EvidenceRecord) -> EvidenceRecord:
        if not self._available:
            raise EvidenceError()
        existing = self._records.get(record.evidence_id)
        if existing is not None and existing != record:
            raise EvidenceError()
        self._records[record.evidence_id] = record
        return record

    def records_for_claim(self, claim_id: str) -> tuple[EvidenceRecord, ...]:
        if not self._available:
            raise EvidenceError()
        return tuple(
            sorted(
                (
                    record
                    for record in self._records.values()
                    if claim_id in record.claim_ids
                ),
                key=lambda record: record.evidence_id,
            )
        )


class CitationAssembler:
    """Build citations only from one unconflicted, currently verified record."""

    def __init__(self, ledger: EvidenceLedger) -> None:
        self._ledger = ledger

    def assemble(self, claim_ids: tuple[str, ...]) -> tuple[Citation, ...]:
        citations: list[Citation] = []
        for claim_id in claim_ids:
            records = self._ledger.records_for_claim(claim_id)
            verified = tuple(
                record
                for record in records
                if record.status is EvidenceStatus.VERIFIED_CURRENT
            )
            if len(verified) != 1 or any(
                record.status is EvidenceStatus.CONFLICTED for record in records
            ):
                raise CitationError()
            record = verified[0]
            citations.append(
                Citation(
                    claim_id=claim_id,
                    evidence_id=record.evidence_id,
                    source_ref=record.source_ref,
                    sha256=record.sha256,
                )
            )
        return tuple(citations)


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
                observation,
                EvidenceStatus.UNVERIFIED,
                "evidence.repository_unavailable",
            )
        if not observation.payload_valid:
            return self._decision(
                observation, EvidenceStatus.INVALID, "evidence.payload_invalid"
            )
        if observation.conflicting_evidence_ids:
            return self._decision(
                observation, EvidenceStatus.CONFLICTED, "evidence.conflicted"
            )
        if not observation.independently_verified or observation.observed_at is None:
            return self._decision(
                observation, EvidenceStatus.UNVERIFIED, "evidence.unverified"
            )
        expires_at = observation.observed_at.astimezone(UTC) + timedelta(
            seconds=observation.max_age_seconds
        )
        if expires_at < normalized_now:
            return self._decision(observation, EvidenceStatus.STALE, "evidence.stale")
        return EvidenceDecision(
            evidence_id=observation.evidence_id,
            status=EvidenceStatus.VERIFIED_CURRENT,
            supports_current_claim=True,
            reason_code=None,
        )

    @staticmethod
    def _decision(
        observation: EvidenceObservation,
        status: EvidenceStatus,
        reason_code: EvidenceReason,
    ) -> EvidenceDecision:
        return EvidenceDecision(
            evidence_id=observation.evidence_id,
            status=status,
            supports_current_claim=False,
            reason_code=reason_code,
        )
