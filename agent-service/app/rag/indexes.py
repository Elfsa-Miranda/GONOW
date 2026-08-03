"""Versioned vector and lexical index writes with immutable replay semantics."""

from __future__ import annotations

import hashlib
import json
import math
import re
import unicodedata
import uuid
from dataclasses import dataclass
from typing import Sequence

from sqlalchemy import text
from sqlalchemy.orm import Session

from app.persistence.repositories.runs import TransactionRequired


EMBEDDING_DIMENSIONS = 1024
EMBEDDING_DISTANCE = "cosine"
DICTIONARY_VERSION = "gonow-zh-simple-v1"
MODEL_REF_PATTERN = re.compile(r"^embedding://[a-z0-9][a-z0-9._/-]{0,190}$")
DICTIONARY_VERSION_PATTERN = re.compile(r"^[a-z][a-z0-9._-]{0,63}$")
LEXEME_PATTERN = re.compile(
    r"[\u3400-\u4dbf\u4e00-\u9fff]+|[A-Za-z0-9]+(?:['._-][A-Za-z0-9]+)*",
    re.UNICODE,
)


class KnowledgeIndexConflict(RuntimeError):
    code = "knowledge.index_immutable_conflict"

    def __init__(self) -> None:
        super().__init__(self.code)


@dataclass(frozen=True, slots=True)
class EmbeddingModelSpec:
    embedding_model_id: uuid.UUID
    model_ref: str
    config_digest: str
    dimensions: int = EMBEDDING_DIMENSIONS
    distance_metric: str = EMBEDDING_DISTANCE
    status: str = "active"

    def validate(self) -> None:
        if MODEL_REF_PATTERN.fullmatch(self.model_ref) is None:
            raise ValueError("embedding model_ref is invalid")
        if self.dimensions != EMBEDDING_DIMENSIONS:
            raise ValueError("embedding dimension family is not certified")
        if self.distance_metric != EMBEDDING_DISTANCE:
            raise ValueError("embedding distance metric is not certified")
        if re.fullmatch(r"[0-9a-f]{64}", self.config_digest) is None:
            raise ValueError("embedding config_digest is invalid")
        if self.status not in {"active", "canary", "retired"}:
            raise ValueError("embedding model status is invalid")


@dataclass(frozen=True, slots=True)
class IndexWriteResult:
    embedding_created: bool
    lexical_created: bool
    embedding_digest: str
    segmented_digest: str


def segment_for_fts(text_value: str) -> str:
    """Emit stable CJK unigram/bigram and lowercase Latin lexemes for simple FTS."""

    normalized = unicodedata.normalize("NFC", text_value).lower()
    lexemes: list[str] = []
    for match in LEXEME_PATTERN.finditer(normalized):
        token = match.group(0)
        if "\u3400" <= token[0] <= "\u9fff":
            characters = list(token)
            lexemes.extend(characters)
            lexemes.extend(
                characters[index] + characters[index + 1]
                for index in range(len(characters) - 1)
            )
        else:
            lexemes.append(token)
    if not lexemes:
        raise ValueError("lexical text has no supported tokens")
    return " ".join(lexemes)


def normalize_embedding(values: Sequence[float]) -> tuple[tuple[float, ...], str, str]:
    if len(values) != EMBEDDING_DIMENSIONS:
        raise ValueError("embedding dimension does not match d1024 family")
    converted = tuple(float(value) for value in values)
    if any(not math.isfinite(value) for value in converted):
        raise ValueError("embedding contains a non-finite value")
    norm = math.sqrt(sum(value * value for value in converted))
    if norm <= 0:
        raise ValueError("cosine embedding must be non-zero")
    normalized = tuple(value / norm for value in converted)
    vector_literal = "[" + ",".join(format(value, ".9g") for value in normalized) + "]"
    digest = hashlib.sha256(vector_literal.encode("ascii")).hexdigest()
    return normalized, vector_literal, digest


class KnowledgeIndexRepository:
    def __init__(self, session: Session) -> None:
        self._session = session

    def _require_transaction(self) -> None:
        if not self._session.in_transaction():
            raise TransactionRequired()

    def register_model(
        self,
        *,
        tenant_id: str,
        spec: EmbeddingModelSpec,
        audit_receipt_id: str,
    ) -> bool:
        self._require_transaction()
        spec.validate()
        if not tenant_id or not audit_receipt_id:
            raise ValueError("tenant and audit receipt are required")
        inserted = self._session.execute(
            text(
                """
                INSERT INTO agent_knowledge.embedding_models (
                  embedding_model_id, tenant_id, model_ref, dimensions,
                  distance_metric, config_digest, status, audit_receipt_id
                ) VALUES (
                  :embedding_model_id, :tenant_id, :model_ref, :dimensions,
                  :distance_metric, :config_digest, :status, :audit_receipt_id
                )
                ON CONFLICT DO NOTHING
                RETURNING embedding_model_id
                """
            ),
            {
                "audit_receipt_id": audit_receipt_id,
                "config_digest": spec.config_digest,
                "dimensions": spec.dimensions,
                "distance_metric": spec.distance_metric,
                "embedding_model_id": spec.embedding_model_id,
                "model_ref": spec.model_ref,
                "status": spec.status,
                "tenant_id": tenant_id,
            },
        ).scalar_one_or_none()
        if inserted is not None:
            return True
        existing = self._session.execute(
            text(
                """
                SELECT embedding_model_id, model_ref, dimensions, distance_metric,
                       config_digest, status
                FROM agent_knowledge.embedding_models
                WHERE tenant_id = :tenant_id
                  AND (embedding_model_id = :embedding_model_id
                       OR (model_ref = :model_ref AND config_digest = :config_digest))
                FOR UPDATE
                """
            ),
            {
                "config_digest": spec.config_digest,
                "embedding_model_id": spec.embedding_model_id,
                "model_ref": spec.model_ref,
                "tenant_id": tenant_id,
            },
        ).mappings().one_or_none()
        expected = (
            spec.embedding_model_id,
            spec.model_ref,
            spec.dimensions,
            spec.distance_metric,
            spec.config_digest,
            spec.status,
        )
        actual = None if existing is None else tuple(existing.values())
        if actual != expected:
            raise KnowledgeIndexConflict()
        return False

    def index_chunk(
        self,
        *,
        tenant_id: str,
        chunk_id: uuid.UUID,
        embedding_model_id: uuid.UUID,
        embedding: Sequence[float],
        text_content: str,
        dictionary_version: str = DICTIONARY_VERSION,
    ) -> IndexWriteResult:
        self._require_transaction()
        if not tenant_id:
            raise ValueError("tenant_id is required")
        if DICTIONARY_VERSION_PATTERN.fullmatch(dictionary_version) is None:
            raise ValueError("dictionary_version is invalid")
        _, vector_literal, embedding_digest = normalize_embedding(embedding)
        segmented_text = segment_for_fts(text_content)
        segmented_digest = hashlib.sha256(segmented_text.encode("utf-8")).hexdigest()

        inserted_embedding = self._session.execute(
            text(
                """
                INSERT INTO agent_knowledge.chunk_embeddings_v1_d1024 (
                  chunk_id, tenant_id, embedding_model_id, embedding, embedding_digest
                ) VALUES (
                  :chunk_id, :tenant_id, :embedding_model_id,
                  CAST(:embedding AS vector), :embedding_digest
                )
                ON CONFLICT DO NOTHING
                RETURNING chunk_id
                """
            ),
            {
                "chunk_id": chunk_id,
                "embedding": vector_literal,
                "embedding_digest": embedding_digest,
                "embedding_model_id": embedding_model_id,
                "tenant_id": tenant_id,
            },
        ).scalar_one_or_none()
        if inserted_embedding is None:
            existing_digest = self._session.execute(
                text(
                    """
                    SELECT embedding_digest
                    FROM agent_knowledge.chunk_embeddings_v1_d1024
                    WHERE tenant_id = :tenant_id
                      AND chunk_id = :chunk_id
                      AND embedding_model_id = :embedding_model_id
                    FOR UPDATE
                    """
                ),
                {
                    "chunk_id": chunk_id,
                    "embedding_model_id": embedding_model_id,
                    "tenant_id": tenant_id,
                },
            ).scalar_one_or_none()
            if existing_digest != embedding_digest:
                raise KnowledgeIndexConflict()

        inserted_lexical = self._session.execute(
            text(
                """
                INSERT INTO agent_knowledge.chunk_lexical (
                  chunk_id, tenant_id, dictionary_version,
                  segmented_text, segmented_digest
                ) VALUES (
                  :chunk_id, :tenant_id, :dictionary_version,
                  :segmented_text, :segmented_digest
                )
                ON CONFLICT DO NOTHING
                RETURNING chunk_id
                """
            ),
            {
                "chunk_id": chunk_id,
                "dictionary_version": dictionary_version,
                "segmented_digest": segmented_digest,
                "segmented_text": segmented_text,
                "tenant_id": tenant_id,
            },
        ).scalar_one_or_none()
        if inserted_lexical is None:
            existing_digest = self._session.execute(
                text(
                    """
                    SELECT segmented_digest
                    FROM agent_knowledge.chunk_lexical
                    WHERE tenant_id = :tenant_id
                      AND chunk_id = :chunk_id
                      AND dictionary_version = :dictionary_version
                    FOR UPDATE
                    """
                ),
                {
                    "chunk_id": chunk_id,
                    "dictionary_version": dictionary_version,
                    "tenant_id": tenant_id,
                },
            ).scalar_one_or_none()
            if existing_digest != segmented_digest:
                raise KnowledgeIndexConflict()

        return IndexWriteResult(
            embedding_created=inserted_embedding is not None,
            lexical_created=inserted_lexical is not None,
            embedding_digest=embedding_digest,
            segmented_digest=segmented_digest,
        )

    def corpus_digest(
        self,
        *,
        tenant_id: str,
        embedding_model_id: uuid.UUID,
        dictionary_version: str = DICTIONARY_VERSION,
    ) -> str:
        if not tenant_id:
            raise ValueError("tenant_id is required")
        rows = self._session.execute(
            text(
                """
                SELECT c.chunk_digest, m.model_ref, e.embedding_digest,
                       l.dictionary_version, l.segmented_digest
                FROM agent_knowledge.chunks AS c
                JOIN agent_knowledge.chunk_embeddings_v1_d1024 AS e
                  ON e.tenant_id = c.tenant_id AND e.chunk_id = c.chunk_id
                JOIN agent_knowledge.embedding_models AS m
                  ON m.tenant_id = e.tenant_id
                 AND m.embedding_model_id = e.embedding_model_id
                JOIN agent_knowledge.chunk_lexical AS l
                  ON l.tenant_id = c.tenant_id AND l.chunk_id = c.chunk_id
                WHERE c.tenant_id = :tenant_id
                  AND e.embedding_model_id = :embedding_model_id
                  AND l.dictionary_version = :dictionary_version
                ORDER BY c.chunk_digest
                """
            ),
            {
                "dictionary_version": dictionary_version,
                "embedding_model_id": embedding_model_id,
                "tenant_id": tenant_id,
            },
        ).mappings()
        material = [dict(row) for row in rows]
        return hashlib.sha256(
            json.dumps(material, sort_keys=True, separators=(",", ":")).encode("utf-8")
        ).hexdigest()

    def refresh_planner_statistics(self) -> None:
        """Refresh only the fixed Knowledge index tables after a bounded build."""

        self._require_transaction()
        self._session.execute(text("ANALYZE agent_knowledge.chunks"))
        self._session.execute(
            text("ANALYZE agent_knowledge.chunk_embeddings_v1_d1024")
        )
        self._session.execute(text("ANALYZE agent_knowledge.chunk_lexical"))
