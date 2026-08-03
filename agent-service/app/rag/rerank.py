"""Deterministic, local reranking of already authorized Knowledge evidence."""

from __future__ import annotations

from dataclasses import dataclass
from fractions import Fraction
from typing import Sequence

from app.rag.fusion import FusedSearchHit, RetrievalFusionConflict
from app.rag.indexes import segment_for_fts
from app.rag.materialize import MaterializedKnowledgeChunk


@dataclass(frozen=True, slots=True)
class RerankPolicy:
    policy_version: str = "deterministic-overlap-v1"
    lexical_overlap_weight: Fraction = Fraction(1, 100)

    def __post_init__(self) -> None:
        if (
            self.policy_version != "deterministic-overlap-v1"
            or self.lexical_overlap_weight < 0
            or self.lexical_overlap_weight > 1
        ):
            raise ValueError("rerank policy is not certified")


@dataclass(frozen=True, slots=True)
class RerankedEvidence:
    fused_hit: FusedSearchHit
    materialized: MaterializedKnowledgeChunk
    overlap_ratio: Fraction
    final_score: Fraction
    rank: int


class DeterministicEvidenceReranker:
    def __init__(self, policy: RerankPolicy | None = None) -> None:
        self._policy = policy or RerankPolicy()

    def rerank(
        self,
        *,
        query_text: str,
        fused_hits: Sequence[FusedSearchHit],
        materialized_chunks: Sequence[MaterializedKnowledgeChunk],
        limit: int = 20,
    ) -> tuple[RerankedEvidence, ...]:
        if not query_text.strip() or not 1 <= limit <= 200:
            raise ValueError("rerank boundary is invalid")
        materialized = {item.chunk_id: item for item in materialized_chunks}
        if len(materialized) != len(materialized_chunks):
            raise RetrievalFusionConflict()
        query_tokens = frozenset(segment_for_fts(query_text).split())
        if not query_tokens:
            raise ValueError("rerank query has no searchable terms")
        scored: list[tuple[FusedSearchHit, MaterializedKnowledgeChunk, Fraction, Fraction]] = []
        for fused in fused_hits:
            chunk = materialized.get(fused.chunk_id)
            if (
                chunk is None
                or chunk.source_id != fused.source_id
                or chunk.version_id != fused.version_id
                or chunk.chunk_digest != fused.chunk_digest
            ):
                raise RetrievalFusionConflict()
            content_tokens = frozenset(segment_for_fts(chunk.text_content).split())
            overlap = Fraction(len(query_tokens & content_tokens), len(query_tokens))
            final_score = (
                fused.rrf_score + self._policy.lexical_overlap_weight * overlap
            )
            scored.append((fused, chunk, overlap, final_score))
        scored.sort(
            key=lambda item: (
                -item[3],
                item[0].rank,
                item[0].chunk_digest,
                str(item[0].chunk_id),
            )
        )
        return tuple(
            RerankedEvidence(
                fused_hit=fused,
                materialized=chunk,
                overlap_ratio=overlap,
                final_score=score,
                rank=rank,
            )
            for rank, (fused, chunk, overlap, score) in enumerate(
                scored[:limit], start=1
            )
        )
