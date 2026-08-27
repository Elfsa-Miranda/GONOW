from __future__ import annotations

from collections import Counter
import hashlib
import json
from pathlib import Path


FIXTURE_ROOT = Path(__file__).resolve().parents[1] / "fixtures" / "context-planner-v2"


def _load(name: str) -> dict[str, object]:
    return json.loads((FIXTURE_ROOT / name).read_text(encoding="utf-8"))


def _digest(name: str) -> str:
    return hashlib.sha256((FIXTURE_ROOT / name).read_bytes()).hexdigest()


def test_context_planner_v2_contract_is_frozen_and_complete() -> None:
    frozen = _load("frozen-contract.json")
    manifest = _load("manifest.json")
    gate = _load("release-gate.json")
    cases = manifest["cases"]

    assert _digest("manifest.json") == frozen["manifest_sha256"]
    assert _digest("release-gate.json") == frozen["release_gate_sha256"]
    assert manifest["runner_version"] == frozen["runner_version"]
    assert gate["runner_version"] == frozen["runner_version"]
    assert len(cases) == gate["required_case_count"] == 24
    assert Counter(item["group"] for item in cases) == gate["required_group_counts"]
    assert len({item["case_id"] for item in cases}) == 24
    assert all(
        item["expected_terminal"]
        in {"accepted", "rejected", "interrupted", "blocked"}
        for item in cases
    )
    assert gate["activation_gates"] == {
        "minimum_long_context_completion_delta": 1,
        "minimum_median_input_token_reduction_ratio": 0.15,
        "non_segmented_extra_model_calls": 0,
        "maximum_segments": 5,
        "maximum_total_tokens": 250000,
        "local_context_planning_p95_ms": 25.0,
        "live_provider_evidence_required": True,
    }
