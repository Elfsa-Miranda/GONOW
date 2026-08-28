"""Final authorization recheck before retrieved Knowledge text is materialized."""

from __future__ import annotations

import json
import uuid
from dataclasses import dataclass
from typing import Any, Sequence

from sqlalchemy import text
from sqlalchemy.orm import Session

from app.rag.filters import (
    SOURCE_ACCESS_PREDICATE_SQL,
    RetrievalContext,
    assert_session_tenant,
    authorization_bindings,
)


@dataclass(frozen=True, slots=True)
class MaterializedKnowledgeChunk:
    chunk_id: uuid.UUID
    source_id: uuid.UUID
    version_id: uuid.UUID
    chunk_digest: str
    text_content: str
    metadata_payload: dict[str, Any]
    source_class: str
    license_identifier: str
    purpose: str


class KnowledgeMaterializer:
    """Performs a fresh, non-cached ACL and version check in READ COMMITTED."""

    def __init__(self, session: Session) -> None:
        self._session = session

    def materialize(
        self,
        *,
        context: RetrievalContext,
        candidate_chunk_ids: Sequence[uuid.UUID],
    ) -> tuple[MaterializedKnowledgeChunk, ...]:
        assert_session_tenant(self._session, context)
        isolation = self._session.execute(
            text("SELECT current_setting('transaction_isolation')")
        ).scalar_one()
        if isolation != "read committed":
            raise RuntimeError("knowledge.materialization_requires_read_committed")
        ordered_ids = tuple(dict.fromkeys(candidate_chunk_ids))
        if len(ordered_ids) > 200 or any(
            not isinstance(chunk_id, uuid.UUID) for chunk_id in ordered_ids
        ):
            raise ValueError("candidate chunk boundary is invalid")
        if not ordered_ids:
            return ()

        bindings = authorization_bindings(context)
        bindings["chunk_ids_json"] = json.dumps(
            [str(value) for value in ordered_ids],
            ensure_ascii=True,
            separators=(",", ":"),
        )
        rows = self._session.execute(
            text(
                f"""
                WITH requested AS (
                  SELECT value::uuid AS chunk_id, ordinal
                  FROM jsonb_array_elements_text(
                    CAST(:chunk_ids_json AS jsonb)
                  ) WITH ORDINALITY AS item(value, ordinal)
                )
                SELECT c.chunk_id, c.source_id, c.version_id, c.chunk_digest,
                       c.text_content, c.metadata_payload, s.source_class,
                       s.license_identifier, s.purpose
                FROM requested AS requested_chunk
                JOIN agent_knowledge.chunks AS c
                  ON c.chunk_id = requested_chunk.chunk_id
                JOIN agent_knowledge.source_versions AS v
                  ON v.tenant_id = c.tenant_id AND v.version_id = c.version_id
                  AND v.source_id = c.source_id
                JOIN agent_knowledge.sources AS s
                  ON s.tenant_id = c.tenant_id AND s.source_id = c.source_id
                WHERE {SOURCE_ACCESS_PREDICATE_SQL}
                ORDER BY requested_chunk.ordinal
                """
            ),
            bindings,
        ).mappings()
        return tuple(
            MaterializedKnowledgeChunk(
                chunk_id=row["chunk_id"],
                source_id=row["source_id"],
                version_id=row["version_id"],
                chunk_digest=row["chunk_digest"],
                text_content=row["text_content"],
                metadata_payload=dict(row["metadata_payload"]),
                source_class=row["source_class"],
                license_identifier=row["license_identifier"],
                purpose=row["purpose"],
            )
            for row in rows
        )
