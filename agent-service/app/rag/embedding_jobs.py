"""Deterministic, bounded embedding-job plans.

P11-003 schedules content-addressed jobs only.  Vector creation and index storage
belong to the later pgvector task, so this module has no provider or network client.
"""

from __future__ import annotations

import hashlib
import json
import re
from dataclasses import dataclass

from app.rag.chunker import ChunkDraft


MODEL_REF_PATTERN = re.compile(r"^embedding://[a-z0-9][a-z0-9._/-]{0,190}$")


class EmbeddingPlanError(ValueError):
    def __init__(self, code: str) -> None:
        self.code = code
        super().__init__(code)


@dataclass(frozen=True, slots=True)
class EmbeddingBatch:
    ordinal: int
    chunk_digests: tuple[str, ...]
    idempotency_key: str


@dataclass(frozen=True, slots=True)
class EmbeddingJobPlan:
    model_ref: str
    max_attempts: int
    batches: tuple[EmbeddingBatch, ...]
    plan_digest: str


class EmbeddingJobPlanner:
    """Create stable batches and retry bounds without embedding document text."""

    PLAN_VERSION = "1"

    def __init__(self, *, batch_size: int = 32, max_attempts: int = 3) -> None:
        if not 1 <= batch_size <= 128:
            raise ValueError("embedding batch_size must be between 1 and 128")
        if not 1 <= max_attempts <= 5:
            raise ValueError("embedding max_attempts must be between 1 and 5")
        self.batch_size = batch_size
        self.max_attempts = max_attempts

    def plan(
        self,
        *,
        tenant_id: str,
        source_key: str,
        version_number: int,
        model_ref: str,
        chunks: tuple[ChunkDraft, ...],
    ) -> EmbeddingJobPlan:
        if not tenant_id or not source_key or version_number < 1:
            raise EmbeddingPlanError("ingestion.embedding.invalid_identity")
        if MODEL_REF_PATTERN.fullmatch(model_ref) is None:
            raise EmbeddingPlanError("ingestion.embedding.invalid_model_ref")
        if not chunks:
            raise EmbeddingPlanError("ingestion.embedding.no_chunks")

        identity_digest = hashlib.sha256(
            f"{tenant_id}\x00{source_key}\x00{version_number}".encode("utf-8")
        ).hexdigest()
        batches: list[EmbeddingBatch] = []
        for start in range(0, len(chunks), self.batch_size):
            batch_chunks = chunks[start : start + self.batch_size]
            ordinal = len(batches)
            chunk_digests = tuple(chunk.chunk_digest for chunk in batch_chunks)
            key_material = {
                "chunk_digests": chunk_digests,
                "identity_digest": identity_digest,
                "model_ref": model_ref,
                "ordinal": ordinal,
                "plan_version": self.PLAN_VERSION,
            }
            idempotency_key = hashlib.sha256(
                json.dumps(
                    key_material, sort_keys=True, separators=(",", ":")
                ).encode("utf-8")
            ).hexdigest()
            batches.append(
                EmbeddingBatch(
                    ordinal=ordinal,
                    chunk_digests=chunk_digests,
                    idempotency_key=idempotency_key,
                )
            )

        plan_material = {
            "batch_keys": [batch.idempotency_key for batch in batches],
            "batch_size": self.batch_size,
            "max_attempts": self.max_attempts,
            "model_ref": model_ref,
            "plan_version": self.PLAN_VERSION,
        }
        plan_digest = hashlib.sha256(
            json.dumps(plan_material, sort_keys=True, separators=(",", ":")).encode(
                "utf-8"
            )
        ).hexdigest()
        return EmbeddingJobPlan(
            model_ref=model_ref,
            max_attempts=self.max_attempts,
            batches=tuple(batches),
            plan_digest=plan_digest,
        )
