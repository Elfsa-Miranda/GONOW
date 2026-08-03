from __future__ import annotations

import site
import sys
import uuid
from dataclasses import replace
from pathlib import Path

import pytest


SERVICE_ROOT = Path(__file__).resolve().parents[3]
site.addsitedir(str(SERVICE_ROOT / ".venv" / "Lib" / "site-packages"))
sys.path.insert(0, str(SERVICE_ROOT))

from app.rag.citations import KnowledgeCitationAssembler  # noqa: E402
from app.rag.fusion import (  # noqa: E402
    ReciprocalRankFusion,
    RetrievalFusionConflict,
    RetrievalManifest,
)
from app.rag.materialize import MaterializedKnowledgeChunk  # noqa: E402
from app.rag.rerank import DeterministicEvidenceReranker  # noqa: E402
from app.rag.search import SearchHit  # noqa: E402


MANIFEST = RetrievalManifest(
    manifest_id=uuid.UUID("00000000-0000-4000-8000-000000001106"),
    manifest_digest="f" * 64,
    embedding_model_id=uuid.UUID("00000000-0000-4000-8000-000000001024"),
    dictionary_version="gonow-zh-simple-v1",
)
CHUNK_A = uuid.UUID("00000000-0000-4000-8000-00000000000a")
CHUNK_B = uuid.UUID("00000000-0000-4000-8000-00000000000b")
SOURCE_A = uuid.UUID("10000000-0000-4000-8000-00000000000a")
SOURCE_B = uuid.UUID("10000000-0000-4000-8000-00000000000b")
VERSION_A = uuid.UUID("20000000-0000-4000-8000-00000000000a")
VERSION_B = uuid.UUID("20000000-0000-4000-8000-00000000000b")


def _hit(
    chunk_id: uuid.UUID,
    source_id: uuid.UUID,
    version_id: uuid.UUID,
    digest_character: str,
    score: float,
) -> SearchHit:
    return SearchHit(
        chunk_id=chunk_id,
        source_id=source_id,
        version_id=version_id,
        chunk_digest=digest_character * 64,
        score=score,
    )


def _chunk(hit: SearchHit, text_content: str) -> MaterializedKnowledgeChunk:
    return MaterializedKnowledgeChunk(
        chunk_id=hit.chunk_id,
        source_id=hit.source_id,
        version_id=hit.version_id,
        chunk_digest=hit.chunk_digest,
        text_content=text_content,
        metadata_payload={"language": "zh-CN"},
        source_class="tenant_private_curated",
        license_identifier="tenant-owned",
        purpose="travel_knowledge_retrieval",
    )


def _pipeline():
    a = _hit(CHUNK_A, SOURCE_A, VERSION_A, "a", 0.9)
    b = _hit(CHUNK_B, SOURCE_B, VERSION_B, "b", 0.8)
    fused = ReciprocalRankFusion().fuse(
        manifest=MANIFEST,
        vector_hits=(a, b),
        lexical_hits=(b, a),
    )
    chunks = (
        _chunk(a, "故宫预约需要实名信息"),
        _chunk(b, "博物馆展览提供公共导览"),
    )
    reranked = DeterministicEvidenceReranker().rerank(
        query_text="故宫预约",
        fused_hits=fused,
        materialized_chunks=chunks,
    )
    cited = KnowledgeCitationAssembler().assemble(
        manifest=MANIFEST,
        ranked_evidence=reranked,
    )
    return a, b, fused, reranked, cited


def test_same_manifest_produces_same_deterministic_order() -> None:
    first = _pipeline()
    second = _pipeline()
    assert [item.chunk_id for item in first[2]] == [item.chunk_id for item in second[2]]
    assert [item.fused_hit.chunk_id for item in first[3]] == [
        item.fused_hit.chunk_id for item in second[3]
    ]
    assert [item.citation.citation_id for item in first[4]] == [
        item.citation.citation_id for item in second[4]
    ]


def test_deterministic_tie_uses_digest_then_chunk_id() -> None:
    a = _hit(CHUNK_A, SOURCE_A, VERSION_A, "a", 0.1)
    b = _hit(CHUNK_B, SOURCE_B, VERSION_B, "b", 0.9)
    fused = ReciprocalRankFusion().fuse(
        manifest=MANIFEST,
        vector_hits=(a, b),
        lexical_hits=(b, a),
    )
    assert [item.chunk_id for item in fused] == [CHUNK_A, CHUNK_B]
    assert fused[0].rrf_score == fused[1].rrf_score


def test_rerank_is_local_bounded_and_evidence_only() -> None:
    _, _, fused, reranked, _ = _pipeline()
    assert reranked[0].materialized.chunk_id == CHUNK_A
    assert reranked[0].overlap_ratio > reranked[1].overlap_ratio
    assert {item.materialized.chunk_id for item in reranked} == {
        item.chunk_id for item in fused
    }


def test_citation_is_traceable_to_manifest_source_version_and_chunk() -> None:
    _, _, _, _, cited = _pipeline()
    citation = cited[0].citation
    assert citation.manifest_id == MANIFEST.manifest_id
    assert citation.manifest_digest == MANIFEST.manifest_digest
    assert str(citation.source_id) in citation.source_ref
    assert str(citation.version_id) in citation.source_ref
    assert str(citation.chunk_id) in citation.source_ref
    assert len(citation.citation_id) == 64


def test_manifest_or_materialized_identity_conflict_fails_closed() -> None:
    a, _, fused, reranked, _ = _pipeline()
    bad_manifest = replace(MANIFEST, manifest_digest="e" * 64)
    with pytest.raises(RetrievalFusionConflict, match="retrieval_fusion_conflict"):
        KnowledgeCitationAssembler().assemble(
            manifest=bad_manifest,
            ranked_evidence=reranked,
        )
    bad_chunk = replace(_chunk(a, "故宫预约"), chunk_digest="c" * 64)
    with pytest.raises(RetrievalFusionConflict, match="retrieval_fusion_conflict"):
        DeterministicEvidenceReranker().rerank(
            query_text="故宫预约",
            fused_hits=fused,
            materialized_chunks=(bad_chunk, reranked[1].materialized),
        )


def test_duplicate_channel_hit_is_rejected_before_fusion() -> None:
    a = _hit(CHUNK_A, SOURCE_A, VERSION_A, "a", 0.9)
    with pytest.raises(RetrievalFusionConflict, match="retrieval_fusion_conflict"):
        ReciprocalRankFusion().fuse(
            manifest=MANIFEST,
            vector_hits=(a, a),
            lexical_hits=(),
        )


def test_empty_authorized_evidence_emits_no_citation_or_fact() -> None:
    fused = ReciprocalRankFusion().fuse(
        manifest=MANIFEST,
        vector_hits=(),
        lexical_hits=(),
    )
    reranked = DeterministicEvidenceReranker().rerank(
        query_text="故宫",
        fused_hits=fused,
        materialized_chunks=(),
    )
    assert not KnowledgeCitationAssembler().assemble(
        manifest=MANIFEST,
        ranked_evidence=reranked,
    )
