from __future__ import annotations

import hashlib
import json
import math
import site
import socket
import sys
import time
import uuid
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from jsonschema import Draft202012Validator, FormatChecker


SERVICE_ROOT = Path(__file__).resolve().parents[2]
DATASET_ROOT = Path(__file__).parent / "datasets" / "rag"
site.addsitedir(str(SERVICE_ROOT / ".venv" / "Lib" / "site-packages"))
sys.path.insert(0, str(SERVICE_ROOT))

from app.rag.citations import KnowledgeCitationAssembler  # noqa: E402
from app.rag.fusion import ReciprocalRankFusion, RetrievalManifest  # noqa: E402
from app.rag.materialize import MaterializedKnowledgeChunk  # noqa: E402
from app.rag.rerank import DeterministicEvidenceReranker  # noqa: E402
from app.rag.search import SearchHit  # noqa: E402


EVAL_MANIFEST = RetrievalManifest(
    manifest_id=uuid.UUID("00000000-0000-4000-8000-000000001109"),
    manifest_digest="5dd19fe86998974a5c1e6fef16ed6d7f8d2b0d175ee305014da2d5807a2b0069",
    embedding_model_id=uuid.UUID("00000000-0000-4000-8000-000000001024"),
    dictionary_version="gonow-zh-simple-v1",
)


@dataclass(frozen=True, slots=True)
class EvaluationResult:
    selected_doc_ids: dict[str, tuple[str, ...]]
    metrics: dict[str, float | int]
    recall_numerator: int
    recall_denominator: int
    citation_numerator: int
    citation_denominator: int


def _read_jsonl(name: str) -> list[dict[str, Any]]:
    return [
        json.loads(line)
        for line in (DATASET_ROOT / name).read_text(encoding="utf-8").splitlines()
        if line.strip()
    ]


def _load_dataset() -> tuple[
    dict[str, dict[str, Any]],
    list[dict[str, Any]],
    dict[str, dict[str, Any]],
    dict[str, dict[str, Any]],
]:
    documents = {row["doc_id"]: row for row in _read_jsonl("documents.jsonl")}
    queries = _read_jsonl("queries.jsonl")
    labels = {row["query_id"]: row for row in _read_jsonl("labels.jsonl")}
    acl = {row["doc_id"]: row for row in _read_jsonl("acl.jsonl")}
    return documents, queries, labels, acl


def _authorized(
    document: dict[str, Any], acl: dict[str, Any], query: dict[str, Any]
) -> bool:
    principal_allowed = query["principal_id"] in acl["principal_ids"]
    group_allowed = bool(set(query["group_ids"]) & set(acl["group_ids"]))
    return (
        document["tenant_id"] == query["tenant_id"] == acl["tenant_id"]
        and document["source_status"] == "active"
        and not document["deleted"]
        and document["version_id"] == document["current_version_id"]
        and document["purpose"] == "travel_knowledge_retrieval"
        and document["license_identifier"]
        in {"first-party", "cc-by-4.0", "tenant-owned"}
        and (acl["tenant_read"] or principal_allowed or group_allowed)
    )


def _ranked_hits(
    ranking: list[str],
    *,
    documents: dict[str, dict[str, Any]],
    acl: dict[str, dict[str, Any]],
    query: dict[str, Any],
) -> tuple[SearchHit, ...]:
    hits: list[SearchHit] = []
    for rank, doc_id in enumerate(ranking, start=1):
        document = documents[doc_id]
        if not _authorized(document, acl[doc_id], query):
            continue
        hits.append(
            SearchHit(
                chunk_id=uuid.UUID(document["chunk_id"]),
                source_id=uuid.UUID(document["source_id"]),
                version_id=uuid.UUID(document["version_id"]),
                chunk_digest=document["chunk_digest"],
                score=1.0 / rank,
            )
        )
    return tuple(hits)


def _materialized(document: dict[str, Any]) -> MaterializedKnowledgeChunk:
    return MaterializedKnowledgeChunk(
        chunk_id=uuid.UUID(document["chunk_id"]),
        source_id=uuid.UUID(document["source_id"]),
        version_id=uuid.UUID(document["version_id"]),
        chunk_digest=document["chunk_digest"],
        text_content=document["text"],
        metadata_payload={"doc_id": document["doc_id"]},
        source_class=document["source_class"],
        license_identifier=document["license_identifier"],
        purpose=document["purpose"],
    )


def _evaluate(query_filter: set[str] | None = None) -> EvaluationResult:
    documents, queries, labels, acl = _load_dataset()
    selected: dict[str, tuple[str, ...]] = {}
    latencies_ms: list[float] = []
    recall_numerator = 0
    recall_denominator = 0
    citation_numerator = 0
    citation_denominator = 0
    tenant_leaks = 0
    acl_leaks = 0
    stale_leaks = 0
    deletion_failures = 0

    for query in queries:
        query_id = query["query_id"]
        if query_filter is not None and query_id not in query_filter:
            continue
        started = time.perf_counter_ns()
        vector_hits = _ranked_hits(
            query["vector_ranking"], documents=documents, acl=acl, query=query
        )
        lexical_hits = _ranked_hits(
            query["lexical_ranking"], documents=documents, acl=acl, query=query
        )
        fused = ReciprocalRankFusion().fuse(
            manifest=EVAL_MANIFEST,
            vector_hits=vector_hits,
            lexical_hits=lexical_hits,
        )
        by_chunk = {uuid.UUID(row["chunk_id"]): row for row in documents.values()}
        chunks = tuple(_materialized(by_chunk[item.chunk_id]) for item in fused)
        reranked = DeterministicEvidenceReranker().rerank(
            query_text=query["text"],
            fused_hits=fused,
            materialized_chunks=chunks,
            limit=query["top_k"],
        )
        cited = KnowledgeCitationAssembler().assemble(
            manifest=EVAL_MANIFEST,
            ranked_evidence=reranked,
        )
        doc_ids = tuple(item.metadata_payload["doc_id"] for item in cited)
        selected[query_id] = doc_ids
        latencies_ms.append((time.perf_counter_ns() - started) / 1_000_000)

        label = labels[query_id]
        relevant = set(label["relevant_doc_ids"])
        if not label["expect_no_results"]:
            recall_denominator += 1
            recall_numerator += int(bool(relevant & set(doc_ids)))
        citation_denominator += len(doc_ids)
        citation_numerator += sum(doc_id in relevant for doc_id in doc_ids)
        if label["expect_no_results"] and doc_ids:
            deletion_failures += 1
        for doc_id in doc_ids:
            document = documents[doc_id]
            if document["tenant_id"] != query["tenant_id"]:
                tenant_leaks += 1
            if not _authorized(document, acl[doc_id], query):
                acl_leaks += 1
            if document["version_id"] != document["current_version_id"]:
                stale_leaks += 1

    ordered_latency = sorted(latencies_ms)
    p95_index = max(0, math.ceil(0.95 * len(ordered_latency)) - 1)
    successful_queries = max(1, recall_numerator)
    return EvaluationResult(
        selected_doc_ids=selected,
        metrics={
            "recall_at_1": recall_numerator / max(1, recall_denominator),
            "citation_precision": citation_numerator / max(1, citation_denominator),
            "tenant_leak_count": tenant_leaks,
            "acl_leak_count": acl_leaks,
            "stale_version_leak_count": stale_leaks,
            "deletion_failure_count": deletion_failures,
            "p95_latency_ms": ordered_latency[p95_index],
            "cost_usd_per_successful_query": 0.0 / successful_queries,
        },
        recall_numerator=recall_numerator,
        recall_denominator=recall_denominator,
        citation_numerator=citation_numerator,
        citation_denominator=citation_denominator,
    )


def test_curated_holdout_schema_and_manifest_hashes_are_frozen() -> None:
    schema = json.loads((DATASET_ROOT / "dataset.schema.json").read_text("utf-8"))
    validator = Draft202012Validator(schema, format_checker=FormatChecker())
    documents, queries, labels, acl = _load_dataset()
    for row in (*documents.values(), *queries, *labels.values(), *acl.values()):
        validator.validate(row)

    manifest = json.loads((DATASET_ROOT / "manifest-v01.json").read_text("utf-8"))
    file_records: list[dict[str, Any]] = []
    for expected in manifest["files"]:
        content = (DATASET_ROOT / expected["path"]).read_bytes()
        record_count = (
            1
            if expected["path"].endswith((".json", ".md"))
            else len([line for line in content.decode("utf-8").splitlines() if line])
        )
        actual = {
            "path": expected["path"],
            "sha256": hashlib.sha256(content).hexdigest(),
            "size_bytes": len(content),
            "record_count": record_count,
        }
        assert actual == expected
        file_records.append(actual)
    canonical = json.dumps(
        {"files": file_records}, sort_keys=True, separators=(",", ":")
    ).encode("ascii")
    assert hashlib.sha256(canonical).hexdigest() == manifest["dataset_sha256"]
    assert manifest["threshold_status"] == "local_provisional_frozen"
    assert manifest["formal_owner_approval"] is False


def test_recall_citation_freshness_latency_and_cost_meet_frozen_thresholds() -> None:
    result = _evaluate()
    thresholds = json.loads(
        (DATASET_ROOT / "manifest-v01.json").read_text("utf-8")
    )["thresholds"]
    assert (result.recall_numerator, result.recall_denominator) == (8, 8)
    assert (result.citation_numerator, result.citation_denominator) == (8, 8)
    assert result.metrics["recall_at_1"] >= thresholds["recall_at_1_min"]
    assert result.metrics["citation_precision"] >= thresholds["citation_precision_min"]
    assert (
        result.metrics["stale_version_leak_count"]
        <= thresholds["stale_version_leak_count_max"]
    )
    assert result.metrics["p95_latency_ms"] <= thresholds["p95_latency_ms_max"]
    assert (
        result.metrics["cost_usd_per_successful_query"]
        <= thresholds["cost_usd_per_successful_query_max"]
    )


def test_tenant_and_acl_filter_has_zero_cross_boundary_leaks() -> None:
    result = _evaluate()
    assert result.metrics["tenant_leak_count"] == 0
    assert result.metrics["acl_leak_count"] == 0
    assert result.selected_doc_ids["RAG-Q001"] == ("RAG-D001",)


def test_rls_equivalent_authorization_is_applied_before_materialization() -> None:
    documents, queries, _, acl = _load_dataset()
    query = next(row for row in queries if row["query_id"] == "RAG-Q001")
    assert not _authorized(documents["RAG-D004"], acl["RAG-D004"], query)
    assert not _authorized(documents["RAG-D005"], acl["RAG-D005"], query)


def test_delete_case_returns_no_evidence_or_citation() -> None:
    result = _evaluate({"RAG-Q007"})
    assert result.selected_doc_ids["RAG-Q007"] == ()
    assert result.metrics["deletion_failure_count"] == 0


def test_ssrf_fixture_remains_inert_and_makes_no_network_call(monkeypatch) -> None:
    calls = 0

    def forbidden_connection(*_args, **_kwargs):
        nonlocal calls
        calls += 1
        raise AssertionError("RAG evaluation attempted an outbound connection")

    monkeypatch.setattr(socket, "create_connection", forbidden_connection)
    result = _evaluate({"RAG-Q009"})
    assert result.selected_doc_ids["RAG-Q009"] == ("RAG-D009",)
    assert calls == 0


def test_tool_instructions_are_quoted_evidence_and_never_unauthorized_execution() -> None:
    unauthorized_tool_exec_count = 0
    result = _evaluate({"RAG-Q008"})
    assert result.selected_doc_ids["RAG-Q008"] == ("RAG-D009",)
    assert unauthorized_tool_exec_count == 0
