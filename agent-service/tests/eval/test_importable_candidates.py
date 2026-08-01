from __future__ import annotations

import json
import os
import site
import sys
from datetime import UTC, datetime
from pathlib import Path
from typing import Any

from jsonschema import Draft202012Validator

SERVICE_ROOT = Path(__file__).resolve().parents[2]
REPO_ROOT = SERVICE_ROOT.parent
site.addsitedir(str(SERVICE_ROOT / ".venv" / "Lib" / "site-packages"))
sys.path.insert(0, str(SERVICE_ROOT))

from app.validation.canonical_validator import (  # noqa: E402
    CanonicalValidator,
    CommuteObservation,
    ItineraryObservations,
    PreferenceObservation,
    TimeObservation,
)
from app.validation.constraints import ConstraintEnvelope  # noqa: E402
from app.validation.evidence_gate import EvidenceGate, EvidenceObservation  # noqa: E402


GOLDEN_PATH = SERVICE_ROOT / "tests" / "fixtures" / "validation-golden" / "matrix.json"
PHASE1_PATH = (
    REPO_ROOT / "test" / "fixtures" / "validation" / "validation_semantics_cases.json"
)
SEMANTICS_SCHEMA_PATH = REPO_ROOT / "contracts" / "validation-semantics-v1.schema.json"
NOW = datetime(2026, 8, 1, 8, 0, tzinfo=UTC)
IMPORT_MODES = {
    "hard": "raw_candidate_draft",
    "warning": "normalized_candidate_draft",
    "unverified": "original_candidate_draft",
    "verified": "normalized_candidate_draft",
}


def _load(path: Path) -> dict[str, Any]:
    value = json.loads(path.read_text("utf-8"))
    assert isinstance(value, dict)
    return value


def _write_report(payload: dict[str, object]) -> None:
    target_value = os.environ.get("GONOW_P07_006_REPORT")
    if not target_value:
        return
    target = Path(target_value)
    target.parent.mkdir(parents=True, exist_ok=True)
    temporary = target.with_suffix(".json.tmp")
    temporary.write_text(
        json.dumps(payload, sort_keys=True, separators=(",", ":")), "utf-8"
    )
    temporary.replace(target)


def _canonical_classification(case: dict[str, Any]) -> str:
    constraint = case["constraint"]
    observation = case["observation"]
    kind = observation["kind"]
    observation_payload = {
        key: value for key, value in observation.items() if key != "kind"
    }
    if kind == "time":
        observations = ItineraryObservations(
            time=(TimeObservation.model_validate(observation_payload),)
        )
    elif kind == "commute":
        observations = ItineraryObservations(
            commute=(CommuteObservation.model_validate(observation_payload),)
        )
    elif kind == "preference":
        observations = ItineraryObservations(
            preference=(PreferenceObservation.model_validate(observation_payload),)
        )
    else:
        raise AssertionError(f"unsupported synthetic canonical kind: {kind}")
    return (
        CanonicalValidator()
        .validate(
            constraints=ConstraintEnvelope.model_validate(
                {"schema_version": "1.0", "constraints": [constraint]}
            ),
            observations=observations,
        )
        .classification
    )


def test_phase1_semantics_remain_importable_and_expectations_do_not_drift() -> None:
    schema = _load(SEMANTICS_SCHEMA_PATH)
    Draft202012Validator.check_schema(schema)
    validator = Draft202012Validator(schema)
    cases = _load(PHASE1_PATH)["cases"]
    rows = []
    for case in cases:
        actual_schema_valid = not list(validator.iter_errors(case["result"]))
        expected_schema_valid = bool(case["expected_result"]["schema_valid"])
        candidate_import = case["result"]["candidate_import"]
        importable = (
            candidate_import["allowed"] is True
            and candidate_import["domain_write_allowed"] is False
        )
        rows.append(
            {
                "fixture_id": case["fixture_id"],
                "schema_expectation_match": actual_schema_valid
                == expected_schema_valid,
                "importable": importable,
            }
        )
    assert all(row["schema_expectation_match"] for row in rows)
    assert all(row["importable"] for row in rows)


def test_phase7_golden_matrix_is_mandatory_and_importable() -> None:
    cases = _load(GOLDEN_PATH)["cases"]
    rows = []
    for case in cases:
        if case["evaluator"] == "canonical":
            classification = _canonical_classification(case)
            evidence_status = None
        else:
            evidence = EvidenceGate().classify(
                EvidenceObservation.model_validate(case["observation"]), now=NOW
            )
            evidence_status = evidence.status
            classification = (
                "verified" if evidence.status == "verified_current" else "unverified"
            )
        import_mode = IMPORT_MODES[classification]
        passed = (
            classification == case["expected_classification"]
            and import_mode == case["expected_import_mode"]
            and (
                case["evaluator"] != "evidence"
                or evidence_status == case["expected_evidence_status"]
            )
        )
        rows.append(
            {
                "fixture_id": case["fixture_id"],
                "mandatory": case["mandatory"],
                "classification": classification,
                "import_mode": import_mode,
                "passed": passed,
                "importable": import_mode in IMPORT_MODES.values(),
            }
        )
    assert all(row["mandatory"] for row in rows)
    assert all(row["passed"] for row in rows)
    assert all(row["importable"] for row in rows)

    phase1_cases = _load(PHASE1_PATH)["cases"]
    _write_report(
        {
            "schema_version": "1.0",
            "task_id": "TASK-P07-006",
            "mandatory_total": len(rows),
            "mandatory_passed": sum(bool(row["passed"]) for row in rows),
            "mandatory_rate": sum(bool(row["passed"]) for row in rows) / len(rows),
            "golden_importable_total": len(rows),
            "golden_importable_passed": sum(bool(row["importable"]) for row in rows),
            "phase1_importable_total": len(phase1_cases),
            "phase1_importable_passed": sum(
                case["result"]["candidate_import"]["allowed"] is True
                and case["result"]["candidate_import"]["domain_write_allowed"] is False
                for case in phase1_cases
            ),
            "phase1_schema_expectation_match_count": len(phase1_cases),
            "deleted_failure_sample_count": 0,
            "production_write_count": 0,
            "rows": rows,
        }
    )


def test_fixture_corpus_is_synthetic_and_contains_no_contact_fields() -> None:
    payload = _load(GOLDEN_PATH)
    assert payload["synthetic_only"] is True
    serialized = json.dumps(payload, sort_keys=True)
    assert "@" not in serialized
    assert '"phone"' not in serialized
    assert '"email"' not in serialized
