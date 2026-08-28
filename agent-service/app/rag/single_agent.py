"""Typed boundary from authorized RAG evidence into the single itinerary Agent."""

from __future__ import annotations

from typing import Any, Protocol

from pydantic import BaseModel, ConfigDict, Field

from app.rag.citations import CitedKnowledgeEvidence
from app.validation.evidence_gate import Citation


class SingleAgentKnowledgeEvidence(BaseModel):
    """One already-authorized knowledge chunk safe to quote as model context."""

    model_config = ConfigDict(extra="forbid", frozen=True)

    claim_id: str = Field(pattern=r"^knowledge_[0-9a-f]{16}$")
    evidence_id: str = Field(pattern=r"^ev_knowledge_[0-9a-f]{16}$")
    source_ref: str = Field(
        pattern=r"^evidence://knowledge/[0-9a-f]{64}/[0-9a-f-]{36}$",
        max_length=512,
    )
    sha256: str = Field(pattern=r"^[0-9a-f]{64}$")
    text: str = Field(min_length=1, max_length=4_000)
    source_class: str = Field(min_length=1, max_length=80)
    license_identifier: str = Field(min_length=1, max_length=80)

    @classmethod
    def from_cited(
        cls, evidence: CitedKnowledgeEvidence
    ) -> SingleAgentKnowledgeEvidence:
        citation = evidence.citation
        stable_suffix = citation.citation_id[:16]
        return cls(
            claim_id=f"knowledge_{stable_suffix}",
            evidence_id=f"ev_knowledge_{stable_suffix}",
            source_ref=(
                f"evidence://knowledge/{citation.manifest_digest}/{citation.chunk_id}"
            ),
            sha256=citation.chunk_digest,
            text=evidence.text_content,
            source_class=citation.source_class,
            license_identifier=citation.license_identifier,
        )

    def candidate_citation(self) -> Citation:
        return Citation(
            claim_id=self.claim_id,
            evidence_id=self.evidence_id,
            source_ref=self.source_ref,
            sha256=self.sha256,
        )


class SingleAgentKnowledgeProvider(Protocol):
    """Port whose implementation must perform tenant and principal ACL checks first."""

    def retrieve(
        self,
        *,
        tenant_id: str,
        structured_input: dict[str, Any],
    ) -> tuple[SingleAgentKnowledgeEvidence, ...]: ...


def select_used_citations(
    evidence: tuple[SingleAgentKnowledgeEvidence, ...],
    *,
    used_claim_ids: frozenset[str],
) -> tuple[Citation, ...]:
    available = {item.claim_id: item for item in evidence}
    if not used_claim_ids.issubset(available):
        raise ValueError("knowledge.unknown_claim")
    return tuple(
        available[claim_id].candidate_citation()
        for claim_id in sorted(used_claim_ids)
    )
