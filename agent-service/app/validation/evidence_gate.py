"""Immutable evidence classification and verified-only citation assembly."""

from __future__ import annotations

from enum import StrEnum

from pydantic import BaseModel, ConfigDict, Field


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
