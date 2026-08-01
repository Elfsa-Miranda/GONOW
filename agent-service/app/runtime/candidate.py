"""Deterministic projection of validated itinerary output into a typed Candidate."""

from __future__ import annotations

import hashlib
import json

from pydantic import BaseModel, ConfigDict, Field

from app.validation.evidence_gate import Citation


SHA256_PATTERN = r"^[0-9a-f]{64}$"


class CandidateProjectionError(ValueError):
    def __init__(self, code: str = "candidate.invalid_projection") -> None:
        self.code = code
        super().__init__(code)


class ItineraryItem(BaseModel):
    model_config = ConfigDict(extra="forbid", frozen=True)

    item_id: str = Field(pattern=r"^item_[a-z0-9_-]{1,80}$")
    title: str = Field(min_length=1, max_length=160)
    start_minute: int = Field(ge=0, lt=1_440)
    duration_minutes: int = Field(gt=0, le=1_440)
    claim_ids: tuple[str, ...] = ()


class ItineraryDay(BaseModel):
    model_config = ConfigDict(extra="forbid", frozen=True)

    day_number: int = Field(ge=1, le=31)
    items: tuple[ItineraryItem, ...] = Field(min_length=1, max_length=30)


class ValidatedItineraryOutput(BaseModel):
    model_config = ConfigDict(extra="forbid", frozen=True)

    title: str = Field(min_length=1, max_length=160)
    days: tuple[ItineraryDay, ...] = Field(min_length=1, max_length=31)


class ItineraryCandidate(BaseModel):
    model_config = ConfigDict(extra="forbid", frozen=True)

    schema_version: str = "1.0"
    candidate_id: str = Field(pattern=r"^cand_[0-9a-f]{32}$")
    run_id: str
    behavior_digest: str = Field(pattern=SHA256_PATTERN)
    input_digest: str = Field(pattern=SHA256_PATTERN)
    title: str
    days: tuple[ItineraryDay, ...]
    citations: tuple[Citation, ...]
    evidence_refs: tuple[str, ...]
    status: str = "candidate"


class CandidateProjector:
    def __init__(self, *, schema_available: bool = True) -> None:
        self._schema_available = schema_available

    def project(
        self,
        *,
        run_id: str,
        behavior_digest: str,
        input_digest: str,
        output: ValidatedItineraryOutput,
        citations: tuple[Citation, ...],
    ) -> ItineraryCandidate:
        if not self._schema_available:
            raise CandidateProjectionError()
        claim_ids = {
            claim_id
            for day in output.days
            for item in day.items
            for claim_id in item.claim_ids
        }
        cited_claim_ids = {citation.claim_id for citation in citations}
        if claim_ids != cited_claim_ids:
            raise CandidateProjectionError()
        evidence_refs = tuple(sorted({citation.source_ref for citation in citations}))
        payload = {
            "run_id": run_id,
            "behavior_digest": behavior_digest,
            "input_digest": input_digest,
            "output": output.model_dump(mode="json"),
            "citations": [citation.model_dump(mode="json") for citation in citations],
        }
        canonical = json.dumps(
            payload, sort_keys=True, separators=(",", ":"), ensure_ascii=False
        ).encode("utf-8")
        candidate_id = f"cand_{hashlib.sha256(canonical).hexdigest()[:32]}"
        try:
            return ItineraryCandidate(
                candidate_id=candidate_id,
                run_id=run_id,
                behavior_digest=behavior_digest,
                input_digest=input_digest,
                title=output.title,
                days=output.days,
                citations=citations,
                evidence_refs=evidence_refs,
            )
        except (TypeError, ValueError) as error:
            raise CandidateProjectionError() from error
