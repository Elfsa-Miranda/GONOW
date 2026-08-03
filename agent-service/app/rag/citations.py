"""Traceable citations for authorized, manifest-bound Knowledge evidence."""

from __future__ import annotations

import hashlib
import uuid
from dataclasses import dataclass
from typing import Any, Sequence

from app.rag.fusion import RetrievalFusionConflict, RetrievalManifest
from app.rag.rerank import RerankedEvidence


@dataclass(frozen=True, slots=True)
class KnowledgeCitation:
    citation_id: str
    citation_number: int
    manifest_id: uuid.UUID
    manifest_digest: str
    source_id: uuid.UUID
    version_id: uuid.UUID
    chunk_id: uuid.UUID
    chunk_digest: str
    source_ref: str
    source_class: str
    license_identifier: str


@dataclass(frozen=True, slots=True)
class CitedKnowledgeEvidence:
    citation: KnowledgeCitation
    text_content: str
    metadata_payload: dict[str, Any]


class KnowledgeCitationAssembler:
    def assemble(
        self,
        *,
        manifest: RetrievalManifest,
        ranked_evidence: Sequence[RerankedEvidence],
    ) -> tuple[CitedKnowledgeEvidence, ...]:
        if [item.rank for item in ranked_evidence] != list(
            range(1, len(ranked_evidence) + 1)
        ):
            raise RetrievalFusionConflict()
        citations: list[CitedKnowledgeEvidence] = []
        seen: set[uuid.UUID] = set()
        for number, item in enumerate(ranked_evidence, start=1):
            fused = item.fused_hit
            chunk = item.materialized
            if (
                fused.manifest_digest != manifest.manifest_digest
                or fused.chunk_id in seen
                or chunk.chunk_id != fused.chunk_id
                or chunk.source_id != fused.source_id
                or chunk.version_id != fused.version_id
                or chunk.chunk_digest != fused.chunk_digest
            ):
                raise RetrievalFusionConflict()
            seen.add(fused.chunk_id)
            identity = "|".join(
                (
                    str(manifest.manifest_id),
                    manifest.manifest_digest,
                    str(chunk.source_id),
                    str(chunk.version_id),
                    str(chunk.chunk_id),
                    chunk.chunk_digest,
                )
            )
            citation = KnowledgeCitation(
                citation_id=hashlib.sha256(identity.encode("ascii")).hexdigest(),
                citation_number=number,
                manifest_id=manifest.manifest_id,
                manifest_digest=manifest.manifest_digest,
                source_id=chunk.source_id,
                version_id=chunk.version_id,
                chunk_id=chunk.chunk_id,
                chunk_digest=chunk.chunk_digest,
                source_ref=(
                    f"knowledge-source://{chunk.source_id}/versions/"
                    f"{chunk.version_id}#chunks/{chunk.chunk_id}"
                ),
                source_class=chunk.source_class,
                license_identifier=chunk.license_identifier,
            )
            citations.append(
                CitedKnowledgeEvidence(
                    citation=citation,
                    text_content=chunk.text_content,
                    metadata_payload=dict(chunk.metadata_payload),
                )
            )
        return tuple(citations)
