from __future__ import annotations

import json
from pathlib import Path
from uuid import UUID

import pytest

from app.runtime.research.contracts import (
    EvidenceBundle,
    MergeDecision,
    ResearchBranchId,
    ResearchContractError,
    ResearchContractKind,
    ResearchRequest,
    parse_research_contract,
)


RUN_ID = "11111111-1111-4111-8111-111111111111"
REQUEST_ID = "22222222-2222-4222-8222-222222222222"
BUNDLE_ID = "33333333-3333-4333-8333-333333333333"
DECISION_ID = "44444444-4444-4444-8444-444444444444"
DIGEST = "a" * 64


def _reference(kind: str, name: str) -> dict[str, str]:
    return {"kind": kind, "uri": f"evidence://{name}", "sha256": DIGEST}


def _request() -> dict[str, object]:
    return {
        "schema_version": "1.0",
        "contract_kind": "research_request",
        "request_id": REQUEST_ID,
        "run_id": RUN_ID,
        "branch_id": "branch_a",
        "objective_ref": _reference("objective", "objective-1"),
        "requirement_refs": [_reference("requirement", "requirement-1")],
        "permission": "read_only",
        "allowed_operations": ["evidence.search", "evidence.retrieve"],
        "output_contract": "evidence_bundle_v1",
    }


def _bundle() -> dict[str, object]:
    return {
        "schema_version": "1.0",
        "contract_kind": "evidence_bundle",
        "bundle_id": BUNDLE_ID,
        "request_id": REQUEST_ID,
        "run_id": RUN_ID,
        "branch_id": "branch_a",
        "findings": [
            {
                "finding_code": "route.weather_supported",
                "assessment": "verified",
                "evidence_refs": [_reference("source", "source-1")],
            }
        ],
        "completion": "complete",
        "domain_write_authorized": False,
    }


def _decision() -> dict[str, object]:
    return {
        "schema_version": "1.0",
        "contract_kind": "merge_decision",
        "decision_id": DECISION_ID,
        "run_id": RUN_ID,
        "bundle_ids": [BUNDLE_ID],
        "outcome": "merged",
        "selected_finding_codes": ["route.weather_supported"],
        "rationale_codes": ["merge.evidence_sufficient"],
        "candidate_ref": _reference("candidate", "candidate-1"),
        "domain_write_authorized": False,
    }


def test_request_bundle_and_merge_decision_are_typed_and_read_only() -> None:
    request = parse_research_contract(
        _request(), expected_kind=ResearchContractKind.REQUEST
    )
    bundle = parse_research_contract(
        _bundle(), expected_kind=ResearchContractKind.BUNDLE
    )
    decision = parse_research_contract(
        _decision(), expected_kind=ResearchContractKind.DECISION
    )

    assert isinstance(request, ResearchRequest)
    assert request.branch_id is ResearchBranchId.A
    assert isinstance(bundle, EvidenceBundle)
    assert bundle.domain_write_authorized is False
    assert isinstance(decision, MergeDecision)
    assert decision.bundle_ids == (UUID(BUNDLE_ID),)
    assert decision.domain_write_authorized is False


@pytest.mark.parametrize(
    ("field", "value"),
    [
        ("permission", "read_write"),
        ("allowed_operations", ["evidence.search", "domain.write"]),
    ],
)
def test_request_rejects_write_attempts(field: str, value: object) -> None:
    payload = _request()
    payload[field] = value

    with pytest.raises(ResearchContractError) as captured:
        parse_research_contract(payload)

    assert captured.value.code == "research_contract.write_forbidden"


def test_bundle_and_decision_cannot_grant_write_authority() -> None:
    for payload in (_bundle(), _decision()):
        payload["domain_write_authorized"] = True
        with pytest.raises(ResearchContractError) as captured:
            parse_research_contract(payload)
        assert captured.value.code == "research_contract.write_forbidden"


@pytest.mark.parametrize(
    ("field", "value", "error_code"),
    [
        ("schema_version", "2.0", "research_contract.unknown_version"),
        ("contract_kind", "free_agent_message", "research_contract.unknown_kind"),
    ],
)
def test_unknown_contract_versions_and_kinds_fail_closed(
    field: str, value: object, error_code: str
) -> None:
    payload = _request()
    payload[field] = value

    with pytest.raises(ResearchContractError) as captured:
        parse_research_contract(payload)

    assert captured.value.code == error_code


@pytest.mark.parametrize("forbidden_field", ["prompt", "secret", "reasoning"])
def test_opaque_or_sensitive_fields_are_rejected(forbidden_field: str) -> None:
    payload = _bundle()
    payload[forbidden_field] = "not-persistable"

    with pytest.raises(ResearchContractError) as captured:
        parse_research_contract(payload)

    assert captured.value.code == "research_contract.invalid"


def test_repository_schema_is_closed_and_version_discriminated() -> None:
    schema_path = Path(__file__).parents[3] / "contracts" / "research-branch-v1.schema.json"
    schema = json.loads(schema_path.read_text(encoding="utf-8"))

    assert schema["$schema"] == "https://json-schema.org/draft/2020-12/schema"
    assert len(schema["oneOf"]) == 3
    assert set(schema["$defs"]) >= {
        "researchRequest",
        "evidenceBundle",
        "mergeDecision",
    }
    for name in ("researchRequest", "evidenceBundle", "mergeDecision"):
        contract = schema["$defs"][name]
        assert contract["additionalProperties"] is False
        assert contract["properties"]["schema_version"] == {"const": "1.0"}
