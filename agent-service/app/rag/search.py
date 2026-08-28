"""Parameterized vector and FTS candidate retrieval for one certified index family."""

from __future__ import annotations

import json
import uuid
from dataclasses import dataclass
from typing import Sequence

from sqlalchemy import text
from sqlalchemy.orm import Session

from app.rag.indexes import DICTIONARY_VERSION, normalize_embedding, segment_for_fts


@dataclass(frozen=True, slots=True)
class SearchHit:
    chunk_id: uuid.UUID
    source_id: uuid.UUID
    version_id: uuid.UUID
    chunk_digest: str
    score: float


class KnowledgeSearch:
    def __init__(self, session: Session) -> None:
        self._session = session

    @staticmethod
    def _limit(value: int) -> int:
        if not 1 <= value <= 200:
            raise ValueError("search limit must be between 1 and 200")
        return value

    def vector_candidates(
        self,
        *,
        tenant_id: str,
        embedding_model_id: uuid.UUID,
        query_embedding: Sequence[float],
        limit: int = 20,
    ) -> tuple[SearchHit, ...]:
        if not tenant_id:
            raise ValueError("tenant_id is required")
        _, vector_literal, _ = normalize_embedding(query_embedding)
        rows = self._session.execute(
            text(
                """
                SELECT c.chunk_id, c.source_id, c.version_id, c.chunk_digest,
                       1.0 - (e.embedding <=> CAST(:query_embedding AS vector)) AS score
                FROM agent_knowledge.chunk_embeddings_v1_d1024 AS e
                JOIN agent_knowledge.chunks AS c
                  ON c.tenant_id = e.tenant_id AND c.chunk_id = e.chunk_id
                WHERE e.tenant_id = :tenant_id
                  AND e.embedding_model_id = :embedding_model_id
                ORDER BY e.embedding <=> CAST(:query_embedding AS vector),
                         c.chunk_digest
                LIMIT :candidate_limit
                """
            ),
            {
                "candidate_limit": self._limit(limit),
                "embedding_model_id": embedding_model_id,
                "query_embedding": vector_literal,
                "tenant_id": tenant_id,
            },
        ).mappings()
        return tuple(
            SearchHit(
                chunk_id=row["chunk_id"],
                source_id=row["source_id"],
                version_id=row["version_id"],
                chunk_digest=row["chunk_digest"],
                score=float(row["score"]),
            )
            for row in rows
        )

    def lexical_candidates(
        self,
        *,
        tenant_id: str,
        query_text: str,
        dictionary_version: str = DICTIONARY_VERSION,
        limit: int = 20,
    ) -> tuple[SearchHit, ...]:
        if not tenant_id:
            raise ValueError("tenant_id is required")
        segmented_query = segment_for_fts(query_text)
        rows = self._session.execute(
            text(
                """
                WITH query AS (
                  SELECT plainto_tsquery('simple'::regconfig, :segmented_query) AS value
                )
                SELECT c.chunk_id, c.source_id, c.version_id, c.chunk_digest,
                       ts_rank_cd(l.search_vector, query.value) AS score
                FROM agent_knowledge.chunk_lexical AS l
                JOIN agent_knowledge.chunks AS c
                  ON c.tenant_id = l.tenant_id AND c.chunk_id = l.chunk_id
                CROSS JOIN query
                WHERE l.tenant_id = :tenant_id
                  AND l.dictionary_version = :dictionary_version
                  AND l.search_vector @@ query.value
                ORDER BY score DESC, c.chunk_digest
                LIMIT :candidate_limit
                """
            ),
            {
                "candidate_limit": self._limit(limit),
                "dictionary_version": dictionary_version,
                "segmented_query": segmented_query,
                "tenant_id": tenant_id,
            },
        ).mappings()
        return tuple(
            SearchHit(
                chunk_id=row["chunk_id"],
                source_id=row["source_id"],
                version_id=row["version_id"],
                chunk_digest=row["chunk_digest"],
                score=float(row["score"]),
            )
            for row in rows
        )

    def explain_vector_plan(
        self,
        *,
        tenant_id: str,
        embedding_model_id: uuid.UUID,
        query_embedding: Sequence[float],
        limit: int = 20,
    ) -> str:
        _, vector_literal, _ = normalize_embedding(query_embedding)
        previous_seqscan = self._session.execute(
            text("SELECT current_setting('enable_seqscan')")
        ).scalar_one()
        try:
            self._session.execute(text("SET LOCAL enable_seqscan = off"))
            plan = self._session.execute(
                text(
                    """
                    EXPLAIN (FORMAT JSON)
                    SELECT c.chunk_id
                    FROM agent_knowledge.chunk_embeddings_v1_d1024 AS e
                    JOIN agent_knowledge.chunks AS c
                      ON c.tenant_id = e.tenant_id AND c.chunk_id = e.chunk_id
                    WHERE e.tenant_id = :tenant_id
                      AND e.embedding_model_id = :embedding_model_id
                    ORDER BY e.embedding <=> CAST(:query_embedding AS vector)
                    LIMIT :candidate_limit
                    """
                ),
                {
                    "candidate_limit": self._limit(limit),
                    "embedding_model_id": embedding_model_id,
                    "query_embedding": vector_literal,
                    "tenant_id": tenant_id,
                },
            ).scalar_one()
        finally:
            self._session.execute(
                text("SELECT set_config('enable_seqscan', :value, true)"),
                {"value": previous_seqscan},
            )
        return json.dumps(plan, sort_keys=True)

    def explain_lexical_plan(
        self,
        *,
        tenant_id: str,
        query_text: str,
        dictionary_version: str = DICTIONARY_VERSION,
        limit: int = 20,
    ) -> str:
        segmented_query = segment_for_fts(query_text)
        previous = self._session.execute(
            text(
                "SELECT current_setting('enable_seqscan'), "
                "current_setting('enable_indexscan')"
            )
        ).one()
        try:
            self._session.execute(text("SET LOCAL enable_seqscan = off"))
            # This is an index-eligibility probe, not the production retrieval path.
            # Suppress the competing tenant B-tree so EXPLAIN must prove GIN usability.
            self._session.execute(text("SET LOCAL enable_indexscan = off"))
            plan = self._session.execute(
                text(
                    """
                    EXPLAIN (FORMAT JSON)
                    WITH query AS (
                      SELECT plainto_tsquery('simple'::regconfig, :segmented_query) AS value
                    )
                    SELECT c.chunk_id
                    FROM agent_knowledge.chunk_lexical AS l
                    JOIN agent_knowledge.chunks AS c
                      ON c.tenant_id = l.tenant_id AND c.chunk_id = l.chunk_id
                    CROSS JOIN query
                    WHERE l.tenant_id = :tenant_id
                      AND l.dictionary_version = :dictionary_version
                      AND l.search_vector @@ query.value
                    ORDER BY ts_rank_cd(l.search_vector, query.value) DESC
                    LIMIT :candidate_limit
                    """
                ),
                {
                    "candidate_limit": self._limit(limit),
                    "dictionary_version": dictionary_version,
                    "segmented_query": segmented_query,
                    "tenant_id": tenant_id,
                },
            ).scalar_one()
        finally:
            self._session.execute(
                text(
                    "SELECT set_config('enable_seqscan', :seqscan, true), "
                    "set_config('enable_indexscan', :indexscan, true)"
                ),
                {"indexscan": previous[1], "seqscan": previous[0]},
            )
        return json.dumps(plan, sort_keys=True)
