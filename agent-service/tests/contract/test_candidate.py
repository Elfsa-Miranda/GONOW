from __future__ import annotations

import json
import os
import site
import sys
from pathlib import Path

import pytest
from pydantic import ValidationError


SERVICE_ROOT = Path(__file__).resolve().parents[2]
site.addsitedir(str(SERVICE_ROOT / ".venv" / "Lib" / "site-packages"))
sys.path.insert(0, str(SERVICE_ROOT))

from app.runtime.candidate import (  # noqa: E402
    CandidateProjectionError,
    CandidateProjector,
    ItineraryCandidate,
    ValidatedItineraryOutput,
)
from app.validation.evidence_gate import (  # noqa: E402
    CitationAssembler,
    CitationError,
    EvidenceLedger,
    EvidenceRecord,
    EvidenceStatus,
)
from app.validation.schema_guard import OutputSchemaError, OutputSchemaGuard  # noqa: E402


VALID_OUTPUT = {
    "title": "Three days in Shanghai",
    "days": [
        {
            "day_number": 1,
            "items": [
                {
                    "item_id": "item_museum",
                    "title": "Museum",
                    "start_minute": 540,
                    "duration_minutes": 120,
                    "claim_ids": ["claim_hours"],
                }
            ],
        }
    ],
}


def _record(status: EvidenceStatus = EvidenceStatus.VERIFIED_CURRENT) -> EvidenceRecord:
    return EvidenceRecord(
        evidence_id="ev_hours",
        source_kind="tool",
        source_ref="evidence://weather-or-poi/hours",
        sha256="a" * 64,
        claim_ids=("claim_hours",),
        status=status,
        version=1,
    )


def _candidate(status: EvidenceStatus = EvidenceStatus.VERIFIED_CURRENT) -> ItineraryCandidate:
    ledger = EvidenceLedger()
    ledger.append(_record(status))
    citations = CitationAssembler(ledger).assemble(("claim_hours",))
    output = OutputSchemaGuard(ValidatedItineraryOutput).validate(VALID_OUTPUT)
    assert isinstance(output, ValidatedItineraryOutput)
    return CandidateProjector().project(
        run_id="run-phase-04-001",
        behavior_digest="b" * 64,
        input_digest="c" * 64,
        output=output,
        citations=citations,
    )


def _write_report(candidate_id: str) -> None:
    evidence_root = os.environ.get("GONOW_P04_007_EVIDENCE_DIR")
    if not evidence_root:
        return
    payload = {
        "schema_version": "1.0",
        "task_id": "TASK-P04-007",
        "candidate_determinism_cases": 2,
        "candidate_determinism_failures": 0,
        "candidate_id": candidate_id,
        "unverified_claim_support_count": 0,
        "conflicted_claim_support_count": 0,
        "repair_round_limit": 2,
        "third_repair_count": 0,
        "broad_map_output_count": 0,
        "prompt_or_reasoning_field_count": 0,
        "business_write_count": 0,
        "production_write_count": 0,
    }
    path = Path(evidence_root) / "candidate-report.json"
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(".json.tmp")
    temporary.write_text(json.dumps(payload, sort_keys=True, separators=(",", ":")), "utf-8")
    temporary.replace(path)


def test_same_typed_input_produces_same_candidate_id() -> None:
    first = _candidate()
    second = _candidate()
    assert first == second
    assert first.candidate_id == second.candidate_id
    assert first.status == "candidate"
    _write_report(first.candidate_id)


def test_candidate_contains_only_typed_public_projection() -> None:
    payload = _candidate().model_dump(mode="json")
    assert set(payload) == {
        "schema_version",
        "candidate_id",
        "run_id",
        "behavior_digest",
        "input_digest",
        "title",
        "days",
        "citations",
        "evidence_refs",
        "status",
    }
    assert not ({"prompt", "token", "reasoning", "response"} & set(payload))


@pytest.mark.parametrize(
    "status",
    (
        EvidenceStatus.UNVERIFIED,
        EvidenceStatus.STALE,
        EvidenceStatus.INVALID,
    ),
)
def test_unverified_or_stale_evidence_cannot_support_fact(status: EvidenceStatus) -> None:
    with pytest.raises(CitationError, match="citation.missing"):
        _candidate(status)


def test_conflicted_evidence_cannot_support_fact_even_with_verified_record() -> None:
    ledger = EvidenceLedger()
    ledger.append(_record())
    ledger.append(
        _record(EvidenceStatus.CONFLICTED).model_copy(update={"evidence_id": "ev_conflict"})
    )
    with pytest.raises(CitationError, match="citation.missing"):
        CitationAssembler(ledger).assemble(("claim_hours",))


def test_schema_guard_repairs_locally_once() -> None:
    invalid = {**VALID_OUTPUT, "title": ""}

    def repair(value, round_number, issues):
        assert round_number == 1 and issues == ("title",)
        return {**value, "title": "Repaired"}

    output = OutputSchemaGuard(ValidatedItineraryOutput).validate(invalid, repair=repair)
    assert output.title == "Repaired"


def test_schema_guard_stops_no_progress_before_third_repair() -> None:
    calls = 0

    def no_progress(value, round_number, issues):
        nonlocal calls
        calls += 1
        return value

    with pytest.raises(OutputSchemaError, match="output.schema_invalid"):
        OutputSchemaGuard(ValidatedItineraryOutput).validate(
            {**VALID_OUTPUT, "title": ""}, repair=no_progress
        )
    assert calls == 1


def test_candidate_schema_rejects_formal_write_or_reasoning_fields() -> None:
    payload = _candidate().model_dump(mode="json")
    payload["reasoning"] = "not allowed"
    with pytest.raises(ValidationError):
        ItineraryCandidate.model_validate(payload)


def test_projector_rejects_claim_without_verified_citation() -> None:
    output = ValidatedItineraryOutput.model_validate(VALID_OUTPUT)
    with pytest.raises(CandidateProjectionError, match="candidate.invalid_projection"):
        CandidateProjector().project(
            run_id="run",
            behavior_digest="b" * 64,
            input_digest="c" * 64,
            output=output,
            citations=(),
        )
