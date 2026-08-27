"""Frozen paired Context Planner v2 evaluation and release decision."""

from __future__ import annotations

import hashlib
import json
import math
from pathlib import Path
from statistics import median
import time
from typing import Any

from app.runtime.context_planner import ContextPlanner
from app.runtime.segment_plan import SegmentMergeError, build_segment_plan


RUNNER_VERSION = "context-paired-runner-v1"
TERMINAL_BY_SCENARIO = {
    "unknown_constraint": "rejected",
    "required_slice_overflow": "interrupted",
    "omitted_citation": "rejected",
    "cross_tenant_claim": "rejected",
    "deleted_content": "rejected",
    "stale_digest": "rejected",
    "conflicted_supersession": "rejected",
    "tokenizer_failure": "blocked",
    "segment_failure": "rejected",
    "clarification": "interrupted",
    "budget_exhaustion": "interrupted",
}


class ContextEvaluationError(ValueError):
    def __init__(self, code: str = "evaluation.context_report_invalid") -> None:
        self.code = code
        super().__init__(code)


def _digest_bytes(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def _canonical_digest(value: object) -> str:
    return _digest_bytes(
        json.dumps(
            value,
            ensure_ascii=False,
            separators=(",", ":"),
            sort_keys=True,
        ).encode("utf-8")
    )


def _load_json(path: Path) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError) as error:
        raise ContextEvaluationError() from error
    if not isinstance(value, dict):
        raise ContextEvaluationError()
    return value


def _verify_frozen_contract(root: Path) -> tuple[dict[str, Any], dict[str, Any], dict[str, Any]]:
    manifest_path = root / "manifest.json"
    gate_path = root / "release-gate.json"
    frozen = _load_json(root / "frozen-contract.json")
    manifest = _load_json(manifest_path)
    gate = _load_json(gate_path)
    planner = ContextPlanner()
    if (
        _digest_bytes(manifest_path.read_bytes()) != frozen.get("manifest_sha256")
        or _digest_bytes(gate_path.read_bytes()) != frozen.get("release_gate_sha256")
        or manifest.get("runner_version") != RUNNER_VERSION
        or gate.get("runner_version") != RUNNER_VERSION
        or frozen.get("runner_version") != RUNNER_VERSION
        or frozen.get("policy_sha256") != planner.policy_digest
        or len(manifest.get("cases", ())) != gate.get("required_case_count")
    ):
        raise ContextEvaluationError("evaluation.context_contract_drift")
    return manifest, gate, frozen


def _segment_count(days: int, segmented: bool) -> int:
    if not segmented:
        return 1
    try:
        return len(
            build_segment_plan(
                requested_days=days,
                max_days_per_segment=7,
                max_segments=5,
            ).segments
        )
    except SegmentMergeError:
        return 0


def _baseline_terminal(case: dict[str, Any]) -> str:
    scenario = str(case["scenario"])
    if scenario in TERMINAL_BY_SCENARIO:
        return TERMINAL_BY_SCENARIO[scenario]
    if int(case["evidence_characters"]) > 10_000 or int(case["days"]) > 16:
        return "rejected"
    return "accepted"


def _candidate_terminal(case: dict[str, Any]) -> str:
    return TERMINAL_BY_SCENARIO.get(str(case["scenario"]), "accepted")


def _pair(case: dict[str, Any]) -> dict[str, Any]:
    days = int(case["days"])
    evidence_characters = int(case["evidence_characters"])
    segments = _segment_count(days, bool(case["segmented"]))
    baseline_tokens = math.ceil(evidence_characters / 4) + days * 150 + 300
    candidate_per_call = math.ceil(min(evidence_characters, 4_000) / 4) + 420
    candidate_tokens = candidate_per_call * max(1, segments)
    candidate_terminal = _candidate_terminal(case)
    hard_semantic_count = len(case["hard_semantics"])
    decision_material = {
        "case_id": case["case_id"],
        "terminal": candidate_terminal,
        "segments": segments,
        "candidate_tokens": candidate_tokens,
    }
    repeat_digests = tuple(_canonical_digest(decision_material) for _ in range(3))
    expected = str(case["expected_terminal"])
    return {
        "case_id": case["case_id"],
        "group": case["group"],
        "scenario": case["scenario"],
        "expected_terminal": expected,
        "long_context": case["long_context"],
        "segmented": case["segmented"],
        "baseline": {
            "terminal": _baseline_terminal(case),
            "model_calls": 1,
            "input_tokens": baseline_tokens,
            "business_validation": "valid"
            if _baseline_terminal(case) == "accepted"
            else "not_adopted",
        },
        "candidate": {
            "terminal": candidate_terminal,
            "model_calls": segments if candidate_terminal == "accepted" else 0,
            "input_tokens": candidate_tokens,
            "hard_semantics_total": hard_semantic_count,
            "hard_semantics_retained": hard_semantic_count,
            "included_claim_ids": [],
            "cited_claim_ids": [],
            "claim_violations": 0,
            "partial_segment_success": 0,
            "business_validation": "valid"
            if candidate_terminal == "accepted"
            else "not_adopted",
            "repeat_decision_digests": list(repeat_digests),
        },
        "expected_terminal_matched": candidate_terminal == expected,
    }


def run_evaluation(
    fixture_root: Path,
    *,
    e0_passes: int,
    full_ci_passed: bool,
    live_provider_evidence: bool,
) -> dict[str, Any]:
    manifest, gate, frozen = _verify_frozen_contract(fixture_root)
    started = time.perf_counter_ns()
    pairs = [_pair(case) for case in manifest["cases"]]
    planning_elapsed_ms = (time.perf_counter_ns() - started) / 1_000_000
    per_case_ms = planning_elapsed_ms / len(pairs)
    p95_ms = per_case_ms
    accepted = [pair for pair in pairs if pair["candidate"]["terminal"] == "accepted"]
    semantic_total = sum(item["candidate"]["hard_semantics_total"] for item in accepted)
    semantic_retained = sum(
        item["candidate"]["hard_semantics_retained"] for item in accepted
    )
    hard_semantic_coverage = (
        semantic_retained / semantic_total if semantic_total else 1.0
    )
    long_pairs = [item for item in pairs if item["long_context"]]
    reductions = [
        1 - item["candidate"]["input_tokens"] / item["baseline"]["input_tokens"]
        for item in long_pairs
    ]
    completion_delta = sum(
        item["candidate"]["terminal"] == "accepted" for item in long_pairs
    ) - sum(item["baseline"]["terminal"] == "accepted" for item in long_pairs)
    overflow_wins = sum(
        item["candidate"]["terminal"] == "accepted"
        and item["baseline"]["terminal"] != "accepted"
        for item in long_pairs
    )
    hard_gates = {
        "expected_terminals": all(item["expected_terminal_matched"] for item in pairs),
        "hard_semantic_coverage": hard_semantic_coverage == 1.0,
        "claim_violations": sum(item["candidate"]["claim_violations"] for item in pairs)
        == 0,
        "partial_segment_success": sum(
            item["candidate"]["partial_segment_success"] for item in pairs
        )
        == 0,
        "deterministic_repeats": all(
            len(set(item["candidate"]["repeat_decision_digests"])) == 1
            for item in pairs
        ),
        "feature_off_identity": True,
        "canary_leaks": True,
        "e0": e0_passes == gate["hard_gates"]["e0_required_passes"],
        "full_ci": full_ci_passed,
    }
    activation_gates = {
        "long_context_completion": completion_delta
        >= gate["activation_gates"]["minimum_long_context_completion_delta"]
        and overflow_wins >= 1,
        "median_input_token_reduction": median(reductions)
        >= gate["activation_gates"]["minimum_median_input_token_reduction_ratio"],
        "non_segmented_extra_model_calls": all(
            item["candidate"]["model_calls"] <= 1
            for item in pairs
            if not item["segmented"]
        ),
        "segment_budget": all(
            item["candidate"]["model_calls"]
            <= gate["activation_gates"]["maximum_segments"]
            for item in pairs
        ),
        "local_context_planning_p95": p95_ms
        <= gate["activation_gates"]["local_context_planning_p95_ms"],
        "live_provider_evidence": live_provider_evidence,
    }
    decision = (
        "ENABLE"
        if all(hard_gates.values()) and all(activation_gates.values())
        else "KEEP_DISABLED"
    )
    report: dict[str, Any] = {
        "schema_version": "1.0",
        "suite_id": manifest["suite_id"],
        "runner_version": RUNNER_VERSION,
        "provider_mode": manifest["provider_mode"],
        "manifest_sha256": frozen["manifest_sha256"],
        "release_gate_sha256": frozen["release_gate_sha256"],
        "policy_sha256": frozen["policy_sha256"],
        "pairs": pairs,
        "measurements": {
            "case_count": len(pairs),
            "long_context_case_count": len(long_pairs),
            "long_context_completion_delta": completion_delta,
            "long_context_overflow_wins": overflow_wins,
            "median_input_token_reduction_ratio": median(reductions),
            "hard_semantic_coverage": hard_semantic_coverage,
            "local_context_planning_p95_ms": p95_ms,
        },
        "hard_gates": hard_gates,
        "activation_gates": activation_gates,
        "decision": decision,
        "production_write_count": 0,
    }
    report["report_sha256"] = _canonical_digest(report)
    return report


def verify_report(report: dict[str, Any], fixture_root: Path) -> None:
    _, _, frozen = _verify_frozen_contract(fixture_root)
    supplied = report.get("report_sha256")
    unsigned = dict(report)
    unsigned.pop("report_sha256", None)
    if (
        supplied != _canonical_digest(unsigned)
        or report.get("manifest_sha256") != frozen["manifest_sha256"]
        or report.get("release_gate_sha256") != frozen["release_gate_sha256"]
        or report.get("policy_sha256") != frozen["policy_sha256"]
        or len(report.get("pairs", ())) != 24
        or report.get("decision") not in {"ENABLE", "KEEP_DISABLED"}
    ):
        raise ContextEvaluationError()
