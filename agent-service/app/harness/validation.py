"""Validate collected S/I/D marker evidence against one mapped control."""

from __future__ import annotations

from dataclasses import dataclass

from app.harness.catalog import HarnessControl, HarnessMappingError


@dataclass(frozen=True, slots=True)
class HarnessCaseEvidence:
    case_id: str
    category: str
    expected_result: str
    node_id: str


def validate_control_evidence(
    control: HarnessControl,
    cases: tuple[HarnessCaseEvidence, ...],
    *,
    executed_node_ids: tuple[str, ...],
) -> None:
    case_ids = [case.case_id for case in cases]
    node_ids = [case.node_id for case in cases]
    categories = {case.category for case in cases}
    if (
        len(cases) < control.minimum_cases
        or len(case_ids) != len(set(case_ids))
        or len(node_ids) != len(set(node_ids))
        or categories != {"S", "I", "D"}
        or any(not case.case_id or not case.expected_result or not case.node_id for case in cases)
        or set(node_ids) != set(executed_node_ids)
        or len(executed_node_ids) != len(set(executed_node_ids))
    ):
        raise HarnessMappingError("harness.evidence_invalid")
