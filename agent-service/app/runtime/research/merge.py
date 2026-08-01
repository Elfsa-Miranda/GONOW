"""Deterministic merge policy for bounded, read-only research bundles."""

from __future__ import annotations

import hashlib
import json
from collections import defaultdict
from collections.abc import Iterable
from uuid import UUID

from pydantic import BaseModel, ConfigDict, Field

from app.runtime.research.contracts import (
    EvidenceAssessment,
    EvidenceBundle,
    MergeDecision,
    MergeOutcome,
    ResearchFinding,
    ResearchReference,
)


_ASSESSMENT_RANK = {
    EvidenceAssessment.VERIFIED: 0,
    EvidenceAssessment.WARNING: 1,
    EvidenceAssessment.UNVERIFIED: 2,
}


class ResearchMergeError(ValueError):
    def __init__(self, code: str = "research_merge.invalid_bundles") -> None:
        self.code = code
        super().__init__(code)


class SelectedFinding(BaseModel):
    model_config = ConfigDict(extra="forbid", frozen=True)

    finding_code: str
    assessment: EvidenceAssessment
    source_bundle_id: UUID
    evidence_refs: tuple[ResearchReference, ...]


class ConflictEvidence(BaseModel):
    model_config = ConfigDict(extra="forbid", frozen=True)

    finding_code: str
    bundle_ids: tuple[UUID, ...] = Field(min_length=2, max_length=2)
    assessments: tuple[EvidenceAssessment, ...] = Field(min_length=1, max_length=3)
    evidence_refs: tuple[ResearchReference, ...] = Field(min_length=1)


class ResearchMergeResult(BaseModel):
    model_config = ConfigDict(extra="forbid", frozen=True)

    merge_digest: str = Field(pattern=r"^[0-9a-f]{64}$")
    decision: MergeDecision
    selections: tuple[SelectedFinding, ...]
    conflicts: tuple[ConflictEvidence, ...]


class DeterministicResearchMerger:
    """Normalize, rank, tie-break and retain conflicting evidence without an LLM."""

    def merge(self, bundles: Iterable[EvidenceBundle]) -> ResearchMergeResult:
        normalized_bundles = tuple(sorted(bundles, key=lambda bundle: bundle.bundle_id.hex))
        self._validate(normalized_bundles)
        merge_digest = self._digest(normalized_bundles)
        grouped: dict[str, list[tuple[EvidenceBundle, ResearchFinding]]] = defaultdict(list)
        for bundle in normalized_bundles:
            for finding in bundle.findings:
                grouped[finding.finding_code].append((bundle, finding))

        selections: list[SelectedFinding] = []
        conflicts: list[ConflictEvidence] = []
        for finding_code in sorted(grouped):
            candidates = sorted(
                grouped[finding_code],
                key=lambda item: (
                    _ASSESSMENT_RANK[item[1].assessment],
                    item[0].bundle_id.hex,
                ),
            )
            selected_bundle, selected_finding = candidates[0]
            selections.append(
                SelectedFinding(
                    finding_code=finding_code,
                    assessment=selected_finding.assessment,
                    source_bundle_id=selected_bundle.bundle_id,
                    evidence_refs=self._unique_references(selected_finding.evidence_refs),
                )
            )
            assessments = tuple(
                sorted(
                    {finding.assessment for _, finding in candidates},
                    key=_ASSESSMENT_RANK.__getitem__,
                )
            )
            distinct_evidence = {
                (reference.uri, reference.sha256)
                for _, finding in candidates
                for reference in finding.evidence_refs
            }
            if len(assessments) > 1 or len(distinct_evidence) > len(
                selected_finding.evidence_refs
            ):
                conflicts.append(
                    ConflictEvidence(
                        finding_code=finding_code,
                        bundle_ids=tuple(bundle.bundle_id for bundle, _ in candidates),
                        assessments=assessments,
                        evidence_refs=self._unique_references(
                            reference
                            for _, finding in candidates
                            for reference in finding.evidence_refs
                        ),
                    )
                )

        if selections:
            outcome = MergeOutcome.MERGED
            candidate_ref = ResearchReference(
                kind="candidate",
                uri=f"candidate://research/{merge_digest}",
                sha256=merge_digest,
            )
            selected_codes = tuple(selection.finding_code for selection in selections)
        else:
            outcome = MergeOutcome.INSUFFICIENT_EVIDENCE
            candidate_ref = None
            selected_codes = ()
        rationale_codes = ["merge.deterministic_rank"]
        if conflicts:
            rationale_codes.append("merge.conflicts_retained")
        decision = MergeDecision(
            decision_id=UUID(hex=merge_digest[:32]),
            run_id=normalized_bundles[0].run_id,
            bundle_ids=tuple(bundle.bundle_id for bundle in normalized_bundles),
            outcome=outcome,
            selected_finding_codes=selected_codes,
            rationale_codes=tuple(rationale_codes),
            candidate_ref=candidate_ref,
        )
        return ResearchMergeResult(
            merge_digest=merge_digest,
            decision=decision,
            selections=tuple(selections),
            conflicts=tuple(conflicts),
        )

    @staticmethod
    def _validate(bundles: tuple[EvidenceBundle, ...]) -> None:
        if not 1 <= len(bundles) <= 2:
            raise ResearchMergeError()
        if len({bundle.bundle_id for bundle in bundles}) != len(bundles):
            raise ResearchMergeError("research_merge.duplicate_bundle")
        if len({bundle.branch_id for bundle in bundles}) != len(bundles):
            raise ResearchMergeError("research_merge.duplicate_branch")
        if len({bundle.run_id for bundle in bundles}) != 1:
            raise ResearchMergeError("research_merge.run_mismatch")

    @staticmethod
    def _digest(bundles: tuple[EvidenceBundle, ...]) -> str:
        payload = []
        for bundle in bundles:
            raw = bundle.model_dump(mode="json")
            raw["findings"] = sorted(
                raw["findings"],
                key=lambda finding: (
                    finding["finding_code"],
                    finding["assessment"],
                    json.dumps(
                        finding["evidence_refs"],
                        sort_keys=True,
                        separators=(",", ":"),
                    ),
                ),
            )
            for finding in raw["findings"]:
                finding["evidence_refs"] = sorted(
                    finding["evidence_refs"],
                    key=lambda reference: (reference["uri"], reference["sha256"]),
                )
            payload.append(raw)
        canonical = json.dumps(
            payload, sort_keys=True, separators=(",", ":"), ensure_ascii=False
        ).encode("utf-8")
        return hashlib.sha256(canonical).hexdigest()

    @staticmethod
    def _unique_references(
        references: Iterable[ResearchReference],
    ) -> tuple[ResearchReference, ...]:
        unique = {(reference.uri, reference.sha256): reference for reference in references}
        return tuple(unique[key] for key in sorted(unique))
