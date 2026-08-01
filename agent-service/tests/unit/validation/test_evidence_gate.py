from __future__ import annotations

import json
import os
import site
import sys
from datetime import UTC, datetime, timedelta
from pathlib import Path

SERVICE_ROOT = Path(__file__).resolve().parents[3]
site.addsitedir(str(SERVICE_ROOT / ".venv" / "Lib" / "site-packages"))
sys.path.insert(0, str(SERVICE_ROOT))

from app.validation.evidence_gate import (  # noqa: E402
    CitationAssembler,
    EvidenceLedger,
    EvidenceRecord,
    EvidenceGate,
    EvidenceObservation,
    EvidenceStatus,
)


NOW = datetime(2026, 8, 1, 8, 0, tzinfo=UTC)
GATE = EvidenceGate()


def _observation(**overrides: object) -> EvidenceObservation:
    payload: dict[str, object] = {
        "evidence_id": "ev_matrix",
        "transport_succeeded": True,
        "repository_available": True,
        "payload_valid": True,
        "independently_verified": True,
        "observed_at": NOW - timedelta(seconds=30),
        "max_age_seconds": 300,
        "conflicting_evidence_ids": (),
    }
    payload.update(overrides)
    return EvidenceObservation.model_validate(payload)


def _write_report(payload: dict[str, object]) -> None:
    target_value = os.environ.get("GONOW_P07_004_REPORT")
    if not target_value:
        return
    target = Path(target_value)
    target.parent.mkdir(parents=True, exist_ok=True)
    temporary = target.with_suffix(".json.tmp")
    temporary.write_text(
        json.dumps(payload, sort_keys=True, separators=(",", ":")), "utf-8"
    )
    temporary.replace(target)


def test_dependency_failure_matrix_and_five_states() -> None:
    cases = (
        ("current", _observation(), "verified_current", None, True),
        (
            "http-success-unverified",
            _observation(independently_verified=False),
            "unverified",
            "evidence.unverified",
            False,
        ),
        (
            "stale",
            _observation(observed_at=NOW - timedelta(seconds=301)),
            "stale",
            "evidence.stale",
            False,
        ),
        (
            "conflict",
            _observation(conflicting_evidence_ids=("ev_other",)),
            "conflicted",
            "evidence.conflicted",
            False,
        ),
        (
            "invalid",
            _observation(payload_valid=False),
            "invalid",
            "evidence.payload_invalid",
            False,
        ),
        (
            "repository-failure",
            _observation(repository_available=False, transport_succeeded=False),
            "unverified",
            "evidence.repository_unavailable",
            False,
        ),
    )
    rows = []
    for case_id, observation, status, reason, supports in cases:
        result = GATE.classify(observation, now=NOW)
        passed = (
            result.status == status
            and result.reason_code == reason
            and result.supports_current_claim is supports
        )
        rows.append(
            {
                "case_id": case_id,
                "status": result.status,
                "reason_code": result.reason_code,
                "supports_current_claim": result.supports_current_claim,
                "passed": passed,
            }
        )
    assert all(row["passed"] for row in rows)
    assert {row["status"] for row in rows} == {
        "verified_current",
        "unverified",
        "stale",
        "conflicted",
        "invalid",
    }
    _write_report(
        {
            "schema_version": "1.0",
            "task_id": "TASK-P07-004",
            "total": len(rows),
            "passed": sum(bool(row["passed"]) for row in rows),
            "stale_evidence_supports_current_count": sum(
                row["status"] == "stale" and row["supports_current_claim"]
                for row in rows
            ),
            "unstable_reason_code_count": sum(
                row["status"] != "verified_current"
                and not str(row["reason_code"]).startswith("evidence.")
                for row in rows
            ),
            "production_write_count": 0,
            "rows": rows,
        }
    )


def test_external_failure_is_not_claimed_as_nonexistence() -> None:
    result = GATE.classify(
        _observation(repository_available=False, transport_succeeded=False), now=NOW
    )
    assert result.status == "unverified"
    assert result.reason_code == "evidence.repository_unavailable"
    assert not result.supports_current_claim


def test_freshness_boundary_is_current_then_stale() -> None:
    at_boundary = _observation(observed_at=NOW - timedelta(seconds=300))
    after_boundary = _observation(
        observed_at=NOW - timedelta(seconds=300, microseconds=1)
    )
    assert GATE.classify(at_boundary, now=NOW).status == "verified_current"
    assert GATE.classify(after_boundary, now=NOW).status == "stale"


def test_five_state_classifier_preserves_evidence_citation_public_contract() -> None:
    record = EvidenceRecord(
        evidence_id="ev_compatibility",
        source_kind="validator",
        source_ref="evidence://validation/compatibility",
        sha256="a" * 64,
        claim_ids=("claim_compatibility",),
        status=EvidenceStatus.VERIFIED_CURRENT,
        version=1,
    )
    ledger = EvidenceLedger()
    ledger.append(record)
    citation = CitationAssembler(ledger).assemble(("claim_compatibility",))[0]
    assert citation.evidence_id == record.evidence_id
    assert citation.sha256 == record.sha256
