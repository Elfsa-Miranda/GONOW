"""Tenant, metadata, and ACL hard filters for Knowledge retrieval."""

from __future__ import annotations

import json
import uuid
from dataclasses import dataclass
from typing import Any, Sequence

from sqlalchemy import text
from sqlalchemy.orm import Session

from app.rag.indexes import DICTIONARY_VERSION, normalize_embedding, segment_for_fts
from app.rag.search import SearchHit


ALLOWED_PURPOSES = frozenset(
    {"candidate_explanation", "itinerary_planning", "travel_knowledge_retrieval"}
)
MAX_GROUPS = 128


class RagAccessDenied(RuntimeError):
    code = "knowledge.retrieval_access_denied"

    def __init__(self) -> None:
        super().__init__(self.code)


@dataclass(frozen=True, slots=True)
class RetrievalContext:
    tenant_id: str
    principal_id: str
    group_ids: tuple[str, ...] = ()
    purpose: str = "travel_knowledge_retrieval"

    def __post_init__(self) -> None:
        canonical_groups = tuple(sorted(set(self.group_ids)))
        if (
            not self.tenant_id
            or len(self.tenant_id) > 128
            or not self.principal_id
            or len(self.principal_id) > 256
            or self.purpose not in ALLOWED_PURPOSES
            or len(canonical_groups) > MAX_GROUPS
            or any(not value or len(value) > 256 for value in canonical_groups)
        ):
            raise RagAccessDenied()
        object.__setattr__(self, "group_ids", canonical_groups)


SOURCE_ACCESS_PREDICATE_SQL = """
    s.tenant_id = :tenant_id
    AND c.tenant_id = :tenant_id
    AND v.tenant_id = :tenant_id
    AND s.status = 'active'
    AND v.status = 'indexed'
    AND s.purpose = :purpose
    AND (
      (s.source_class = 'first_party_product_knowledge'
       AND s.license_identifier = 'gonow-first-party')
      OR
      (s.source_class = 'public_licensed_reference'
       AND s.license_identifier IN ('cc-by-4.0','cc0-1.0','public-domain-verified'))
      OR
      (s.source_class = 'tenant_private_curated'
       AND s.license_identifier IN ('tenant-owned','tenant-authorized'))
    )
    AND (
      s.source_class = 'public_licensed_reference'
      OR EXISTS (
        SELECT 1
        FROM agent_knowledge.acl_entries AS acl
        WHERE acl.tenant_id = :tenant_id
          AND acl.source_id = s.source_id
          AND acl.permission = 'read'
          AND acl.revoked_at IS NULL
          AND (
            (acl.subject_type = 'principal' AND acl.subject_id = :principal_id)
            OR
            (acl.subject_type = 'tenant' AND acl.subject_id = :tenant_id)
            OR
            (acl.subject_type = 'group' AND acl.subject_id IN (
              SELECT allowed_group.value
              FROM jsonb_array_elements_text(
                CAST(:group_ids_json AS jsonb)
              ) AS allowed_group(value)
            ))
          )
      )
    )
"""


def authorization_bindings(context: RetrievalContext) -> dict[str, Any]:
    return {
        "group_ids_json": json.dumps(
            context.group_ids,
            ensure_ascii=True,
            separators=(",", ":"),
        ),
        "principal_id": context.principal_id,
        "purpose": context.purpose,
        "tenant_id": context.tenant_id,
    }


def assert_session_tenant(session: Session, context: RetrievalContext) -> None:
    database_tenant = session.execute(
        text("SELECT agent_runtime.current_tenant_id()")
    ).scalar_one()
    if database_tenant != context.tenant_id:
        raise RagAccessDenied()


class AclFilteredKnowledgeSearch:
    """Searches only rows authorized before rank and limit are evaluated."""

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
        context: RetrievalContext,
        embedding_model_id: uuid.UUID,
        query_embedding: Sequence[float],
        limit: int = 20,
    ) -> tuple[SearchHit, ...]:
        assert_session_tenant(self._session, context)
        _, vector_literal, _ = normalize_embedding(query_embedding)
        bindings = authorization_bindings(context)
        bindings.update(
            {
                "candidate_limit": self._limit(limit),
                "embedding_model_id": embedding_model_id,
                "query_embedding": vector_literal,
            }
        )
        rows = self._session.execute(
            text(
                f"""
                SELECT c.chunk_id, c.source_id, c.version_id, c.chunk_digest,
                       1.0 - (e.embedding <=> CAST(:query_embedding AS vector)) AS score
                FROM agent_knowledge.chunk_embeddings_v1_d1024 AS e
                JOIN agent_knowledge.chunks AS c
                  ON c.tenant_id = e.tenant_id AND c.chunk_id = e.chunk_id
                JOIN agent_knowledge.source_versions AS v
                  ON v.tenant_id = c.tenant_id AND v.version_id = c.version_id
                  AND v.source_id = c.source_id
                JOIN agent_knowledge.sources AS s
                  ON s.tenant_id = c.tenant_id AND s.source_id = c.source_id
                WHERE e.tenant_id = :tenant_id
                  AND e.embedding_model_id = :embedding_model_id
                  AND {SOURCE_ACCESS_PREDICATE_SQL}
                ORDER BY e.embedding <=> CAST(:query_embedding AS vector),
                         c.chunk_digest
                LIMIT :candidate_limit
                """
            ),
            bindings,
        ).mappings()
        return self._hits(rows)

    def lexical_candidates(
        self,
        *,
        context: RetrievalContext,
        query_text: str,
        dictionary_version: str = DICTIONARY_VERSION,
        limit: int = 20,
    ) -> tuple[SearchHit, ...]:
        assert_session_tenant(self._session, context)
        bindings = authorization_bindings(context)
        bindings.update(
            {
                "candidate_limit": self._limit(limit),
                "dictionary_version": dictionary_version,
                "segmented_query": segment_for_fts(query_text),
            }
        )
        rows = self._session.execute(
            text(
                f"""
                WITH query AS (
                  SELECT plainto_tsquery('simple'::regconfig, :segmented_query) AS value
                )
                SELECT c.chunk_id, c.source_id, c.version_id, c.chunk_digest,
                       ts_rank_cd(l.search_vector, query.value) AS score
                FROM agent_knowledge.chunk_lexical AS l
                JOIN agent_knowledge.chunks AS c
                  ON c.tenant_id = l.tenant_id AND c.chunk_id = l.chunk_id
                JOIN agent_knowledge.source_versions AS v
                  ON v.tenant_id = c.tenant_id AND v.version_id = c.version_id
                  AND v.source_id = c.source_id
                JOIN agent_knowledge.sources AS s
                  ON s.tenant_id = c.tenant_id AND s.source_id = c.source_id
                CROSS JOIN query
                WHERE l.tenant_id = :tenant_id
                  AND l.dictionary_version = :dictionary_version
                  AND l.search_vector @@ query.value
                  AND {SOURCE_ACCESS_PREDICATE_SQL}
                ORDER BY score DESC, c.chunk_digest
                LIMIT :candidate_limit
                """
            ),
            bindings,
        ).mappings()
        return self._hits(rows)

    @staticmethod
    def _hits(rows: Any) -> tuple[SearchHit, ...]:
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
