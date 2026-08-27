from __future__ import annotations

import json
from pathlib import Path

import pytest

from app.harness.catalog import HarnessMappingError
from app.harness.context_planner_v2 import load_context_planner_harness_mapping


REPOSITORY_ROOT = Path(__file__).resolve().parents[3]
MAPPING = (
    REPOSITORY_ROOT
    / "docs/execution/schemas/context-planner-v2-harness-mapping.json"
)


def test_context_planner_controls_map_to_owner_tests_evidence_and_codes() -> None:
    mapping = load_context_planner_harness_mapping(
        MAPPING,
        repository_root=REPOSITORY_ROOT,
    )
    assert mapping["owner_task"] == "P13-004"
    assert len(mapping["controls"]) == 11
    assert {item["harness_control_id"] for item in mapping["controls"]} == {
        1,
        8,
        12,
        14,
        22,
        23,
        26,
        27,
        29,
        30,
        31,
    }


def test_context_planner_mapping_tampering_fails_closed(tmp_path: Path) -> None:
    value = json.loads(MAPPING.read_text(encoding="utf-8"))
    value["controls"][0]["harness_control_id"] = 99
    tampered = tmp_path / MAPPING.name
    tampered.write_text(json.dumps(value), encoding="utf-8")
    with pytest.raises(HarnessMappingError, match="harness.catalog_path_invalid"):
        load_context_planner_harness_mapping(
            tampered,
            repository_root=REPOSITORY_ROOT,
        )
