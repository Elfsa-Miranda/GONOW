from __future__ import annotations

import site
import sys
from pathlib import Path

import pytest
from pydantic import ValidationError


SERVICE_ROOT = Path(__file__).resolve().parents[3]
site.addsitedir(str(SERVICE_ROOT / ".venv" / "Lib" / "site-packages"))
sys.path.insert(0, str(SERVICE_ROOT))

from app.runtime.candidate import (  # noqa: E402
    CandidateProjectionError,
    CandidateProjector,
    ItineraryCandidate,
    ValidatedItineraryOutput,
)
from app.validation.evidence_gate import Citation  # noqa: E402


def _output() -> ValidatedItineraryOutput:
    return ValidatedItineraryOutput.model_validate(
        {
            "title": "Trip",
            "days": [
                {
                    "day_number": 1,
                    "items": [
                        {
                            "item_id": "item_one",
                            "title": "Place",
                            "start_minute": 60,
                            "duration_minutes": 30,
                            "claim_ids": ["claim_one"],
                        }
                    ],
                }
            ],
        }
    )


def _citation() -> Citation:
    return Citation(
        claim_id="claim_one",
        evidence_id="ev_one",
        source_ref="evidence://one",
        sha256="a" * 64,
    )


def _project():
    return CandidateProjector().project(
        run_id="run",
        behavior_digest="b" * 64,
        input_digest="c" * 64,
        output=_output(),
        citations=(_citation(),),
    )


def test_26_candidate_projector_s_is_idempotent() -> None:
    assert _project() == _project()


def test_26_candidate_projector_i_excludes_internal_fields() -> None:
    payload = _project().model_dump(mode="json")
    payload["prompt"] = "forbidden"
    with pytest.raises(ValidationError):
        ItineraryCandidate.model_validate(payload)


def test_26_candidate_projector_i_rejects_missing_evidence() -> None:
    with pytest.raises(CandidateProjectionError, match="candidate.invalid_projection"):
        CandidateProjector().project(
            run_id="run",
            behavior_digest="b" * 64,
            input_digest="c" * 64,
            output=_output(),
            citations=(),
        )


def test_26_candidate_projector_d_schema_failure_fails_closed() -> None:
    with pytest.raises(CandidateProjectionError, match="candidate.invalid_projection"):
        CandidateProjector(schema_available=False).project(
            run_id="run",
            behavior_digest="b" * 64,
            input_digest="c" * 64,
            output=_output(),
            citations=(_citation(),),
        )
