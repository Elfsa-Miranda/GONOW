import json
from pathlib import Path

import pytest
from pydantic import ValidationError

from app.memory.contracts import MemoryFact


DATASET = Path("tests/eval/datasets/structured-memory/v1/scenarios.jsonl")


def scenarios() -> list[dict]:
    return [json.loads(line) for line in DATASET.read_text(encoding="utf-8").splitlines()]


def test_preregistered_fixture_is_complete_and_unique() -> None:
    rows = scenarios()
    assert len(rows) == 12
    assert len({row["scenario_id"] for row in rows}) == 12
    assert {row["memory_type"] for row in rows} == {"travel_pace", "mobility_requirement", "dietary_requirement", "transport_preference"}


def test_all_eligible_values_are_typed_and_all_injection_values_reject() -> None:
    for row in scenarios():
        if row["expected"] == "eligible":
            assert MemoryFact(memory_type=row["memory_type"], value=row["value"]).value == row["value"]
        if row["expected"] == "reject_invalid_enum":
            with pytest.raises(ValidationError):
                MemoryFact(memory_type=row["memory_type"], value=row["value"])


def test_local_fixture_makes_no_production_value_claim() -> None:
    trigger = json.loads(Path("../docs/execution/evidence/phase-12a/P12A-010/trigger-evidence.json").read_text(encoding="utf-8"))
    assert trigger["production_trigger_decision"] == "unknown_pending_real_data"
    assert trigger["model_api_call_count"] == 0
