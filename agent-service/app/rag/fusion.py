"""Deterministic reciprocal-rank fusion bound to one Knowledge manifest."""

from __future__ import annotations

import re
import uuid
from dataclasses import dataclass
from fractions import Fraction
from typing import Literal, Sequence

from app.rag.search import SearchHit


DIGEST_PATTERN = re.compile(r"^[0-9a-f]{64}$")


class RetrievalFusionConflict(RuntimeError):
    code = "knowledge.retrieval_fusion_conflict"

    def __init__(self) -> None:
        super().__init__(self.code)


@dataclass(frozen=True, slots=True)
class RetrievalManifest:
    manifest_id: uuid.UUID
    manifest_digest: str
    embedding_model_id: uuid.UUID
    dictionary_version: str

    def __post_init__(self) -> None:
        if (
            DIGEST_PATTERN.fullmatch(self.manifest_digest) is None
            or not self.dictionary_version
            or len(self.dictionary_version) > 64
        ):
            raise ValueError("retrieval manifest boundary is invalid")


@dataclass(frozen=True, slots=True)
class FusedSearchHit:
    manifest_digest: str
    chunk_id: uuid.UUID
    source_id: uuid.UUID
    version_id: uuid.UUID
    chunk_digest: str
    rrf_score: Fraction
    rank: int
    vector_rank: int | None
    lexical_rank: int | None
    vector_score: float | None
    lexical_score: float | None


@dataclass(slots=True)
class _AccumulatedHit:
    chunk_id: uuid.UUID
    source_id: uuid.UUID
    version_id: uuid.UUID
    chunk_digest: str
    rrf_score: Fraction = Fraction(0, 1)
    vector_rank: int | None = None
    lexical_rank: int | None = None
    vector_score: float | None = None
    lexical_score: float | None = None


class ReciprocalRankFusion:
    def __init__(
        self,
        *,
        rank_constant: int = 60,
        vector_weight: int = 1,
        lexical_weight: int = 1,
    ) -> None:
        if rank_constant < 1 or vector_weight < 1 or lexical_weight < 1:
            raise ValueError("RRF configuration must be positive")
        self._rank_constant = rank_constant
        self._vector_weight = vector_weight
        self._lexical_weight = lexical_weight

    def fuse(
        self,
        *,
        manifest: RetrievalManifest,
        vector_hits: Sequence[SearchHit],
        lexical_hits: Sequence[SearchHit],
        limit: int = 20,
    ) -> tuple[FusedSearchHit, ...]:
        if not 1 <= limit <= 200:
            raise ValueError("fusion limit must be between 1 and 200")
        identities: dict[uuid.UUID, tuple[uuid.UUID, uuid.UUID, str]] = {}
        accumulated: dict[uuid.UUID, _AccumulatedHit] = {}
        self._accumulate_channel(
            hits=vector_hits,
            channel="vector",
            weight=self._vector_weight,
            identities=identities,
            accumulated=accumulated,
        )
        self._accumulate_channel(
            hits=lexical_hits,
            channel="lexical",
            weight=self._lexical_weight,
            identities=identities,
            accumulated=accumulated,
        )
        ordered = sorted(
            accumulated.values(),
            key=lambda item: (
                -item.rrf_score,
                min(
                    value
                    for value in (item.vector_rank, item.lexical_rank)
                    if value is not None
                ),
                item.chunk_digest,
                str(item.chunk_id),
            ),
        )[:limit]
        return tuple(
            FusedSearchHit(
                manifest_digest=manifest.manifest_digest,
                chunk_id=item.chunk_id,
                source_id=item.source_id,
                version_id=item.version_id,
                chunk_digest=item.chunk_digest,
                rrf_score=item.rrf_score,
                rank=rank,
                vector_rank=item.vector_rank,
                lexical_rank=item.lexical_rank,
                vector_score=item.vector_score,
                lexical_score=item.lexical_score,
            )
            for rank, item in enumerate(ordered, start=1)
        )

    def _accumulate_channel(
        self,
        *,
        hits: Sequence[SearchHit],
        channel: Literal["vector", "lexical"],
        weight: int,
        identities: dict[uuid.UUID, tuple[uuid.UUID, uuid.UUID, str]],
        accumulated: dict[uuid.UUID, _AccumulatedHit],
    ) -> None:
        seen: set[uuid.UUID] = set()
        for rank, hit in enumerate(hits, start=1):
            if hit.chunk_id in seen or DIGEST_PATTERN.fullmatch(hit.chunk_digest) is None:
                raise RetrievalFusionConflict()
            seen.add(hit.chunk_id)
            identity = (hit.source_id, hit.version_id, hit.chunk_digest)
            if hit.chunk_id in identities and identities[hit.chunk_id] != identity:
                raise RetrievalFusionConflict()
            identities[hit.chunk_id] = identity
            if hit.chunk_id not in accumulated:
                accumulated[hit.chunk_id] = _AccumulatedHit(
                    chunk_id=hit.chunk_id,
                    source_id=hit.source_id,
                    version_id=hit.version_id,
                    chunk_digest=hit.chunk_digest,
                )
            item = accumulated[hit.chunk_id]
            item.rrf_score += Fraction(weight, self._rank_constant + rank)
            if channel == "vector":
                item.vector_rank = rank
                item.vector_score = hit.score
            else:
                item.lexical_rank = rank
                item.lexical_score = hit.score
