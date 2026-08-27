"""Deterministic extractive Context recovery with authorized handles."""

from __future__ import annotations

import hashlib
import json
import re
from collections.abc import Callable
from dataclasses import dataclass

from app.rag.single_agent import SingleAgentKnowledgeEvidence
from app.runtime.context_planner import deterministic_token_count


class ContextRecoveryError(ValueError):
    def __init__(self, code: str) -> None:
        self.code = code
        super().__init__(code)


@dataclass(frozen=True, slots=True)
class SourceSpan:
    start: int
    end: int
    ordinal: int
    text: str


@dataclass(frozen=True, slots=True)
class CompressionRecord:
    source_ref: str
    source_sha256: str
    claim_id: str
    spans: tuple[SourceSpan, ...]
    extracted_text: str
    query_terms: tuple[str, ...]
    original_characters: int
    final_characters: int
    original_tokens: int
    final_tokens: int
    policy_id: str = "exact-sentence-spans-v1"


@dataclass(frozen=True, slots=True)
class ContextHandle:
    handle_id: str
    source_ref: str
    sha256: str
    kind: str
    token_estimate: int
    claim_ids: tuple[str, ...]


@dataclass(frozen=True, slots=True)
class EvidenceRecoveryDecision:
    included: tuple[SingleAgentKnowledgeEvidence, ...]
    handles: tuple[ContextHandle, ...]
    compression_records: tuple[CompressionRecord, ...]
    deduplicated_evidence_ids: tuple[str, ...]
    superseded_evidence_ids: tuple[str, ...]
    transform_log: tuple[dict[str, str], ...]
    digest: str


def _sentence_spans(text: str) -> tuple[SourceSpan, ...]:
    spans: list[SourceSpan] = []
    start = 0
    ordinal = 0
    for match in re.finditer(r"(?<=[.!?。！？])\s+|\n+", text):
        end = match.start()
        if end > start:
            spans.append(SourceSpan(start, end, ordinal, text[start:end]))
            ordinal += 1
        start = match.end()
    if start < len(text):
        spans.append(SourceSpan(start, len(text), ordinal, text[start:]))
    return tuple(item for item in spans if item.text)


def _extract(
    evidence: SingleAgentKnowledgeEvidence,
    *,
    query_terms: tuple[str, ...],
    character_limit: int,
) -> tuple[SingleAgentKnowledgeEvidence, CompressionRecord]:
    normalized_terms = tuple(sorted({term.casefold() for term in query_terms if term}))
    spans = _sentence_spans(evidence.text)
    ranked = sorted(
        spans,
        key=lambda span: (
            -sum(span.text.casefold().count(term) for term in normalized_terms),
            span.ordinal,
        ),
    )
    selected: list[SourceSpan] = []
    used = 0
    for span in ranked:
        separator = 1 if selected else 0
        if used + separator + len(span.text) <= character_limit:
            selected.append(span)
            used += separator + len(span.text)
    if not selected and spans and len(spans[0].text) <= character_limit:
        selected.append(spans[0])
    ordered = tuple(sorted(selected, key=lambda item: item.ordinal))
    extracted = "\n".join(item.text for item in ordered)
    if not extracted:
        raise ContextRecoveryError("context.compression_unavailable")
    compacted = evidence.model_copy(update={"text": extracted})
    return compacted, CompressionRecord(
        source_ref=evidence.source_ref,
        source_sha256=evidence.sha256,
        claim_id=evidence.claim_id,
        spans=ordered,
        extracted_text=extracted,
        query_terms=normalized_terms,
        original_characters=len(evidence.text),
        final_characters=len(extracted),
        original_tokens=deterministic_token_count(evidence.text),
        final_tokens=deterministic_token_count(extracted),
    )


def _handle(evidence: SingleAgentKnowledgeEvidence) -> ContextHandle:
    identity = hashlib.sha256(
        f"{evidence.source_ref}:{evidence.sha256}:{evidence.claim_id}".encode("utf-8")
    ).hexdigest()
    return ContextHandle(
        handle_id=f"context-handle://sha256/{identity}",
        source_ref=evidence.source_ref,
        sha256=evidence.sha256,
        kind="evidence",
        token_estimate=deterministic_token_count(evidence.text),
        claim_ids=(evidence.claim_id,),
    )


def compact_authorized_evidence(
    evidence: tuple[SingleAgentKnowledgeEvidence, ...],
    *,
    query_terms: tuple[str, ...],
    max_total_characters: int,
    supersession: tuple[tuple[str, str], ...] = (),
) -> EvidenceRecoveryDecision:
    if max_total_characters < 1:
        raise ContextRecoveryError("context.recovery_budget_invalid")
    by_id = {item.evidence_id: item for item in evidence}
    superseded_ids = tuple(sorted(item[0] for item in supersession))
    replacement_ids = tuple(item[1] for item in supersession)
    if (
        len(by_id) != len(evidence)
        or len(superseded_ids) != len(set(superseded_ids))
        or any(
            old_id == replacement_id
            or old_id not in by_id
            or replacement_id not in by_id
            for old_id, replacement_id in supersession
        )
        or set(superseded_ids) & set(replacement_ids)
    ):
        raise ContextRecoveryError("context.supersession_invalid")
    representatives: dict[str, SingleAgentKnowledgeEvidence] = {}
    deduplicated: list[str] = []
    transforms: list[dict[str, str]] = [
        {"artifact_id": old_id, "action": "superseded"}
        for old_id in superseded_ids
    ]
    for item in sorted(evidence, key=lambda value: (value.source_ref, value.claim_id)):
        if item.evidence_id in superseded_ids:
            continue
        if item.sha256 in representatives:
            deduplicated.append(item.evidence_id)
            transforms.append(
                {"artifact_id": item.evidence_id, "action": "deduplicated"}
            )
        else:
            representatives[item.sha256] = item

    compacted: list[tuple[SingleAgentKnowledgeEvidence, CompressionRecord]] = []
    for item in representatives.values():
        try:
            recovered = _extract(
                item,
                query_terms=query_terms,
                character_limit=max_total_characters,
            )
        except ContextRecoveryError:
            continue
        compacted.append(recovered)

    included: list[SingleAgentKnowledgeEvidence] = []
    records: list[CompressionRecord] = []
    handles: list[ContextHandle] = []
    used = 0
    compacted_by_claim = {item.claim_id: (item, record) for item, record in compacted}
    for source in representatives.values():
        recovered = compacted_by_claim.get(source.claim_id)
        if recovered is None:
            handles.append(_handle(source))
            transforms.append(
                {"artifact_id": source.evidence_id, "action": "omitted_with_handle"}
            )
            continue
        item, record = recovered
        if used + len(item.text) <= max_total_characters:
            included.append(item)
            records.append(record)
            used += len(item.text)
            transforms.append(
                {"artifact_id": item.evidence_id, "action": "extractive_compaction"}
            )
        else:
            handles.append(_handle(source))
            transforms.append(
                {"artifact_id": source.evidence_id, "action": "omitted_with_handle"}
            )
    payload = {
        "deduplicated_evidence_ids": sorted(deduplicated),
        "handles": [item.handle_id for item in handles],
        "included": [item.claim_id for item in included],
        "records": [
            {
                "claim_id": item.claim_id,
                "spans": [[span.start, span.end] for span in item.spans],
            }
            for item in records
        ],
        "superseded_evidence_ids": list(superseded_ids),
    }
    digest = hashlib.sha256(
        json.dumps(payload, sort_keys=True, separators=(",", ":")).encode("utf-8")
    ).hexdigest()
    return EvidenceRecoveryDecision(
        included=tuple(included),
        handles=tuple(handles),
        compression_records=tuple(records),
        deduplicated_evidence_ids=tuple(sorted(deduplicated)),
        superseded_evidence_ids=superseded_ids,
        transform_log=tuple(transforms),
        digest=digest,
    )


EvidenceResolver = Callable[[str], SingleAgentKnowledgeEvidence]
EvidenceAuthorizer = Callable[[SingleAgentKnowledgeEvidence], bool]


def rehydrate_context_handle(
    handle: ContextHandle,
    *,
    resolver: EvidenceResolver,
    authorize: EvidenceAuthorizer,
) -> SingleAgentKnowledgeEvidence:
    evidence = resolver(handle.source_ref)
    if not authorize(evidence):
        raise ContextRecoveryError("context.rehydration_denied")
    if (
        evidence.source_ref != handle.source_ref
        or evidence.sha256 != handle.sha256
        or (evidence.claim_id,) != handle.claim_ids
    ):
        raise ContextRecoveryError("context.rehydration_stale")
    return evidence
