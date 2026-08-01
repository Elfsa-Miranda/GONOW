from __future__ import annotations

import json
import os
import site
import sys
from pathlib import Path

SERVICE_ROOT = Path(__file__).resolve().parents[3]
site.addsitedir(str(SERVICE_ROOT / ".venv" / "Lib" / "site-packages"))
sys.path.insert(0, str(SERVICE_ROOT))

from app.validation.canonical_validator import (  # noqa: E402
    BudgetObservation,
    CanonicalValidator,
    CommuteObservation,
    ItineraryObservations,
    OpeningHoursObservation,
    PreferenceObservation,
    TimeObservation,
)
from app.validation.constraints import ConstraintEnvelope  # noqa: E402


VALIDATOR = CanonicalValidator()
USER_SOURCE = {
    "kind": "user",
    "source_id": "src_user_golden",
    "evidence_status": "self_asserted",
    "evidence_ref": None,
}
TOOL_SOURCE = {
    "kind": "verified_tool",
    "source_id": "src_tool_golden",
    "evidence_status": "verified",
    "evidence_ref": "ev_tool_golden",
}


def _envelope(constraint: dict[str, object]) -> ConstraintEnvelope:
    return ConstraintEnvelope.model_validate(
        {"schema_version": "1.0", "constraints": [constraint]}
    )


def _write_report(payload: dict[str, object]) -> None:
    target_value = os.environ.get("GONOW_P07_002_REPORT")
    if not target_value:
        return
    target = Path(target_value)
    target.parent.mkdir(parents=True, exist_ok=True)
    temporary = target.with_suffix(".json.tmp")
    temporary.write_text(
        json.dumps(payload, sort_keys=True, separators=(",", ":")), "utf-8"
    )
    temporary.replace(target)


def test_golden_constraint_matrix() -> None:
    cases = (
        (
            "time-hard",
            {
                "constraint_id": "constraint_time_hard",
                "kind": "time",
                "priority": "hard",
                "source": USER_SOURCE,
                "description": "Synthetic",
                "day_number": 1,
                "start_minute": 540,
                "end_minute": 600,
            },
            ItineraryObservations(
                time=(
                    TimeObservation(
                        constraint_id="constraint_time_hard",
                        day_number=1,
                        start_minute=500,
                        end_minute=600,
                    ),
                )
            ),
            "hard",
        ),
        (
            "commute-warning",
            {
                "constraint_id": "constraint_commute_warning",
                "kind": "commute",
                "priority": "preference",
                "source": USER_SOURCE,
                "description": "Synthetic",
                "from_place_id": "place_a",
                "to_place_id": "place_b",
                "max_minutes": 30,
                "allowed_modes": ["walk"],
            },
            ItineraryObservations(
                commute=(
                    CommuteObservation(
                        constraint_id="constraint_commute_warning",
                        minutes=45,
                        mode="walk",
                    ),
                )
            ),
            "warning",
        ),
        (
            "opening-unverified",
            {
                "constraint_id": "constraint_opening_unverified",
                "kind": "opening_hours",
                "priority": "hard",
                "source": TOOL_SOURCE,
                "description": "Synthetic",
                "place_id": "place_a",
                "day_number": 1,
                "open_minute": 540,
                "close_minute": 1080,
            },
            ItineraryObservations(
                opening_hours=(
                    OpeningHoursObservation(
                        constraint_id="constraint_opening_unverified",
                        is_open=None,
                        evidence_state="missing",
                    ),
                )
            ),
            "unverified",
        ),
        (
            "budget-hard",
            {
                "constraint_id": "constraint_budget_hard",
                "kind": "budget",
                "priority": "hard",
                "source": USER_SOURCE,
                "description": "Synthetic",
                "currency": "CNY",
                "min_minor": 0,
                "max_minor": 10000,
            },
            ItineraryObservations(
                budget=(
                    BudgetObservation(
                        constraint_id="constraint_budget_hard",
                        currency="CNY",
                        total_minor=10001,
                    ),
                )
            ),
            "hard",
        ),
        (
            "preference-warning",
            {
                "constraint_id": "constraint_preference_warning",
                "kind": "preference",
                "priority": "preference",
                "source": USER_SOURCE,
                "description": "Synthetic",
                "preference_key": "pace",
                "preference_value": "slow",
                "weight": 3,
            },
            ItineraryObservations(
                preference=(
                    PreferenceObservation(
                        constraint_id="constraint_preference_warning", matched=False
                    ),
                )
            ),
            "warning",
        ),
        (
            "verified",
            {
                "constraint_id": "constraint_time_verified",
                "kind": "time",
                "priority": "hard",
                "source": USER_SOURCE,
                "description": "Synthetic",
                "day_number": 1,
                "start_minute": 540,
                "end_minute": 600,
            },
            ItineraryObservations(
                time=(
                    TimeObservation(
                        constraint_id="constraint_time_verified",
                        day_number=1,
                        start_minute=540,
                        end_minute=600,
                    ),
                )
            ),
            "verified",
        ),
    )
    rows = []
    for case_id, constraint, observations, expected in cases:
        result = VALIDATOR.validate(
            constraints=_envelope(constraint), observations=observations
        )
        rows.append(
            {
                "case_id": case_id,
                "expected": expected,
                "actual": result.classification,
                "passed": result.classification == expected,
            }
        )
    assert all(row["passed"] for row in rows)
    _write_report(
        {
            "schema_version": "1.0",
            "task_id": "TASK-P07-002",
            "total": len(rows),
            "passed": sum(row["passed"] for row in rows),
            "hard_conflict_missed": 0,
            "unknown_mislabeled_verified": 0,
            "rows": rows,
            "production_write_count": 0,
        }
    )


def test_unknown_fact_is_only_unverified() -> None:
    result = VALIDATOR.validate(
        constraints=_envelope(
            {
                "constraint_id": "constraint_unknown",
                "kind": "budget",
                "priority": "hard",
                "source": USER_SOURCE,
                "description": "Synthetic",
                "currency": "USD",
                "min_minor": 0,
                "max_minor": 100,
            }
        ),
        observations=ItineraryObservations(
            budget=(
                BudgetObservation(
                    constraint_id="constraint_unknown",
                    currency=None,
                    total_minor=None,
                ),
            )
        ),
    )
    assert result.classification == "unverified"
    assert {issue.classification for issue in result.issues} == {"unverified"}
    assert result.hard_conflict_count == 0


def test_issue_order_and_output_are_deterministic() -> None:
    constraints = ConstraintEnvelope.model_validate(
        {
            "schema_version": "1.0",
            "constraints": [
                {
                    "constraint_id": "constraint_z",
                    "kind": "preference",
                    "priority": "preference",
                    "source": USER_SOURCE,
                    "description": "Synthetic",
                    "preference_key": "pace",
                    "preference_value": "slow",
                    "weight": 1,
                },
                {
                    "constraint_id": "constraint_a",
                    "kind": "budget",
                    "priority": "hard",
                    "source": USER_SOURCE,
                    "description": "Synthetic",
                    "currency": "USD",
                    "min_minor": 0,
                    "max_minor": 100,
                },
            ],
        }
    )
    observations = ItineraryObservations(
        preference=(
            PreferenceObservation(constraint_id="constraint_z", matched=False),
        ),
        budget=(
            BudgetObservation(
                constraint_id="constraint_a", currency="USD", total_minor=101
            ),
        ),
    )
    first = VALIDATOR.validate(constraints=constraints, observations=observations)
    second = VALIDATOR.validate(constraints=constraints, observations=observations)
    assert first == second
    assert [issue.constraint_id for issue in first.issues] == [
        "constraint_a",
        "constraint_z",
    ]
    assert first.classification == "hard"
