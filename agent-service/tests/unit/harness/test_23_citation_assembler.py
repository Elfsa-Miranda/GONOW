from __future__ import annotations

import site
import sys
import uuid
from pathlib import Path

import pytest


SERVICE_ROOT = Path(__file__).resolve().parents[3]
site.addsitedir(str(SERVICE_ROOT / ".venv" / "Lib" / "site-packages"))
sys.path.insert(0, str(SERVICE_ROOT))

from app.validation.evidence_gate import (  # noqa: E402
    CitationAssembler,
    CitationError,
    EvidenceError,
    EvidenceLedger,
    EvidenceRecord,
    EvidenceStatus,
)
from app.rag.citations import KnowledgeCitationAssembler  # noqa: E402
from app.rag.fusion import (  # noqa: E402
    ReciprocalRankFusion,
    RetrievalFusionConflict,
    RetrievalManifest,
)
from app.rag.materialize import MaterializedKnowledgeChunk  # noqa: E402
from app.rag.rerank import DeterministicEvidenceReranker  # noqa: E402
from app.rag.search import SearchHit  # noqa: E402


def _record(evidence_id: str, status: EvidenceStatus) -> EvidenceRecord:
    return EvidenceRecord(
        evidence_id=evidence_id,
        source_kind="tool",
        source_ref=f"evidence://{evidence_id}",
        sha256="b" * 64,
        claim_ids=("claim_one",),
        status=status,
        version=1,
    )


def test_23_citation_assembler_s_links_claim_to_verified_evidence() -> None:
    ledger = EvidenceLedger()
    ledger.append(_record("ev_verified", EvidenceStatus.VERIFIED_CURRENT))
    assert CitationAssembler(ledger).assemble(("claim_one",))[0].evidence_id == "ev_verified"


def test_23_citation_assembler_i_rejects_missing_evidence() -> None:
    with pytest.raises(CitationError, match="citation.missing"):
        CitationAssembler(EvidenceLedger()).assemble(("claim_one",))


def test_23_citation_assembler_i_exposes_conflict_as_failure() -> None:
    ledger = EvidenceLedger()
    ledger.append(_record("ev_verified", EvidenceStatus.VERIFIED_CURRENT))
    ledger.append(_record("ev_conflict", EvidenceStatus.CONFLICTED))
    with pytest.raises(CitationError, match="citation.missing"):
        CitationAssembler(ledger).assemble(("claim_one",))


def test_23_citation_assembler_d_ledger_failure_generates_no_citation() -> None:
    with pytest.raises(EvidenceError, match="evidence.invalid"):
        CitationAssembler(EvidenceLedger(available=False)).assemble(("claim_one",))


def _knowledge_fixture():
    manifest = RetrievalManifest(
        manifest_id=uuid.UUID("30000000-0000-4000-8000-000000000023"),
        manifest_digest="c" * 64,
        embedding_model_id=uuid.UUID("40000000-0000-4000-8000-000000000023"),
        dictionary_version="gonow-zh-simple-v1",
    )
    hit = SearchHit(
        chunk_id=uuid.UUID("50000000-0000-4000-8000-000000000023"),
        source_id=uuid.UUID("60000000-0000-4000-8000-000000000023"),
        version_id=uuid.UUID("70000000-0000-4000-8000-000000000023"),
        chunk_digest="d" * 64,
        score=0.9,
    )
    chunk = MaterializedKnowledgeChunk(
        chunk_id=hit.chunk_id,
        source_id=hit.source_id,
        version_id=hit.version_id,
        chunk_digest=hit.chunk_digest,
        text_content="故宫预约证据",
        metadata_payload={},
        source_class="tenant_private_curated",
        license_identifier="tenant-owned",
        purpose="travel_knowledge_retrieval",
    )
    fused = ReciprocalRankFusion().fuse(
        manifest=manifest,
        vector_hits=(hit,),
        lexical_hits=(hit,),
    )
    ranked = DeterministicEvidenceReranker().rerank(
        query_text="故宫预约",
        fused_hits=fused,
        materialized_chunks=(chunk,),
    )
    return manifest, ranked


def test_23_citation_assembler_s_traces_knowledge_source_version_chunk() -> None:
    manifest, ranked = _knowledge_fixture()
    citation = KnowledgeCitationAssembler().assemble(
        manifest=manifest,
        ranked_evidence=ranked,
    )[0].citation
    assert citation.manifest_digest == manifest.manifest_digest
    assert str(citation.source_id) in citation.source_ref
    assert str(citation.version_id) in citation.source_ref
    assert str(citation.chunk_id) in citation.source_ref


def test_23_citation_assembler_i_rejects_manifest_digest_mismatch() -> None:
    manifest, ranked = _knowledge_fixture()
    with pytest.raises(RetrievalFusionConflict, match="retrieval_fusion_conflict"):
        KnowledgeCitationAssembler().assemble(
            manifest=RetrievalManifest(
                manifest_id=manifest.manifest_id,
                manifest_digest="e" * 64,
                embedding_model_id=manifest.embedding_model_id,
                dictionary_version=manifest.dictionary_version,
            ),
            ranked_evidence=ranked,
        )


def test_23_citation_assembler_d_same_manifest_preserves_same_order() -> None:
    manifest, ranked = _knowledge_fixture()
    assembler = KnowledgeCitationAssembler()
    first = assembler.assemble(manifest=manifest, ranked_evidence=ranked)
    second = assembler.assemble(manifest=manifest, ranked_evidence=ranked)
    assert [item.citation.citation_id for item in first] == [
        item.citation.citation_id for item in second
    ]
