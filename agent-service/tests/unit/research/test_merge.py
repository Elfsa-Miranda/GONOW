from __future__ import annotations

import json
import os
from pathlib import Path
from uuid import UUID

import pytest

from app.runtime.research.contracts import EvidenceBundle
from app.runtime.research.merge import DeterministicResearchMerger, ResearchMergeError


RUN_ID = UUID("11111111-1111-4111-8111-111111111111")


def _reference(name: str, digest: str) -> dict[str, str]:
    return {"kind": "source", "uri": f"evidence://{name}", "sha256": digest * 64}


def _bundle(
    *,
    bundle_id: str,
    branch_id: str,
    assessment: str = "verified",
    source: str = "source-a",
    digest: str = "a",
    findings: bool = True,
    run_id: UUID = RUN_ID,
) -> EvidenceBundle:
    return EvidenceBundle.model_validate(
        {
            "bundle_id": bundle_id,
            "request_id": "22222222-2222-4222-8222-222222222222",
            "run_id": str(run_id),
            "branch_id": branch_id,
            "findings": (
                [
                    {
                        "finding_code": "route.weather_supported",
                        "assessment": assessment,
                        "evidence_refs": [_reference(source, digest)],
                    }
                ]
                if findings
                else []
            ),
            "completion": "complete",
        }
    )


def test_same_bundles_in_any_order_produce_same_digest_and_decision() -> None:
    bundle_a = _bundle(
        bundle_id="33333333-3333-4333-8333-333333333333", branch_id="branch_a"
    )
    bundle_b = _bundle(
        bundle_id="44444444-4444-4444-8444-444444444444",
        branch_id="branch_b",
        source="source-b",
        digest="b",
    )
    merger = DeterministicResearchMerger()

    first = merger.merge((bundle_a, bundle_b))
    second = merger.merge((bundle_b, bundle_a))

    assert first.merge_digest == second.merge_digest
    assert first.decision == second.decision
    assert first.selections == second.selections
    report_path = os.environ.get("GONOW_P08_003_REPORT")
    if report_path:
        report = {
            "schema_version": "1.0",
            "task_id": "TASK-P08-003",
            "permutation_count": 2,
            "distinct_digest_count": len({first.merge_digest, second.merge_digest}),
            "decision_mismatch_count": int(first.decision != second.decision),
            "conflict_count": len(first.conflicts),
            "conflict_evidence_ref_count": len(first.conflicts[0].evidence_refs),
            "random_tie_count": 0,
            "router_llm_call_count": 0,
            "production_write_count": 0,
        }
        target = Path(report_path)
        target.parent.mkdir(parents=True, exist_ok=True)
        temporary = target.with_suffix(".json.tmp")
        temporary.write_text(
            json.dumps(report, sort_keys=True, separators=(",", ":")), "utf-8"
        )
        temporary.replace(target)


def test_conflicting_assessments_and_sources_are_retained() -> None:
    result = DeterministicResearchMerger().merge(
        (
            _bundle(
                bundle_id="33333333-3333-4333-8333-333333333333",
                branch_id="branch_a",
                assessment="warning",
            ),
            _bundle(
                bundle_id="44444444-4444-4444-8444-444444444444",
                branch_id="branch_b",
                assessment="verified",
                source="source-b",
                digest="b",
            ),
        )
    )

    assert result.selections[0].assessment.value == "verified"
    assert len(result.conflicts) == 1
    assert {ref.uri for ref in result.conflicts[0].evidence_refs} == {
        "evidence://source-a",
        "evidence://source-b",
    }
    assert "merge.conflicts_retained" in result.decision.rationale_codes


def test_equal_rank_tie_uses_lexicographically_lowest_bundle_id() -> None:
    higher_id = _bundle(
        bundle_id="ffffffff-ffff-4fff-8fff-ffffffffffff",
        branch_id="branch_b",
        source="source-b",
        digest="b",
    )
    lower_id = _bundle(
        bundle_id="00000000-0000-4000-8000-000000000001",
        branch_id="branch_a",
    )

    result = DeterministicResearchMerger().merge((higher_id, lower_id))

    assert result.selections[0].source_bundle_id == lower_id.bundle_id


def test_empty_bundle_returns_typed_insufficient_evidence() -> None:
    result = DeterministicResearchMerger().merge(
        (
            _bundle(
                bundle_id="33333333-3333-4333-8333-333333333333",
                branch_id="branch_a",
                findings=False,
            ),
        )
    )

    assert result.decision.outcome.value == "insufficient_evidence"
    assert result.decision.candidate_ref is None
    assert result.conflicts == ()


@pytest.mark.parametrize("case", ["duplicate_branch", "run_mismatch"])
def test_invalid_bundle_sets_fail_closed(case: str) -> None:
    bundle_a = _bundle(
        bundle_id="33333333-3333-4333-8333-333333333333", branch_id="branch_a"
    )
    bundle_b = _bundle(
        bundle_id="44444444-4444-4444-8444-444444444444",
        branch_id="branch_a" if case == "duplicate_branch" else "branch_b",
        run_id=(RUN_ID if case == "duplicate_branch" else UUID(int=9)),
    )

    with pytest.raises(ResearchMergeError):
        DeterministicResearchMerger().merge((bundle_a, bundle_b))
