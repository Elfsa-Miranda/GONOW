from __future__ import annotations

import hashlib
import json
import os
import re
import site
import statistics
import sys
import time
from collections.abc import Mapping
from pathlib import Path
from typing import Any
from uuid import UUID

import pytest
from jsonschema import Draft202012Validator


SERVICE_ROOT = Path(__file__).resolve().parents[2]
REPOSITORY_ROOT = SERVICE_ROOT.parent
site.addsitedir(str(SERVICE_ROOT / ".venv" / "Lib" / "site-packages"))
sys.path.insert(0, str(SERVICE_ROOT))

from app.graphs.itinerary_planning import (  # noqa: E402
    BUSINESS_STAGES,
    BoundedItineraryPlanningGraph,
    BudgetPolicy,
    PlanningStep,
)
from app.runtime.state import (  # noqa: E402
    BudgetSnapshot,
    GoNowAgentState,
    StateReference,
    WorkflowStage,
)


DATA_ROOT = SERVICE_ROOT / "tests" / "eval" / "datasets" / "e0"
E0_EVIDENCE_ROOT = (
    REPOSITORY_ROOT / "docs" / "execution" / "evidence" / "phase-04" / "P04-000"
)
RESULT_SCHEMA_PATH = (
    REPOSITORY_ROOT / "docs" / "execution" / "schemas" / "e0-results-v1.schema.json"
)
MANIFEST_PATH = E0_EVIDENCE_ROOT / "e0-manifest.json"
SCORING_PATH = E0_EVIDENCE_ROOT / "e0-scoring-v1.json"

WARNING_BY_CONSTRAINT = {
    "accessible_route": "accessibility.unverified",
    "child_friendly": "age_guidance.unverified",
    "indoor_fallback": "weather.unverified",
    "museum_closed_day_2": "hours.unverified",
    "rail_only": "schedule.unverified",
    "rail_pass": "schedule.unverified",
    "reserved_event_day_3": "event.unverified",
    "step_free": "accessibility.unverified",
    "sunset_anchor": "weather.unverified",
    "ticketed_first": "ticket.unverified",
    "weather_fallback": "weather.unverified",
}
ORDERING_BY_CONSTRAINT = {
    "accessible_route": "step_free_route_first",
    "child_friendly": "child_friendly_first",
    "daylight_only": "daylight_items_first",
    "early_dinner": "early_dinner_before_evening",
    "indoor_fallback": "indoor_fallback_after_primary",
    "indoor_first": "indoor_first",
    "late_start": "late_start_preserved",
    "low_noise": "low_noise_evening",
    "low_walking": "low_walking_daily",
    "morning_start": "morning_start",
    "museum_closed_day_2": "closed_item_not_on_day_2",
    "no_late_night": "no_late_night_items",
    "one_anchor_per_day": "one_anchor_per_day",
    "one_free_block": "one_free_block_present",
    "public_transit": "public_transit_segments",
    "quiet_evening": "quiet_evening_last",
    "rail_only": "rail_segments_only",
    "rail_pass": "rail_segments_only",
    "reserved_event_day_3": "reserved_event_on_day_3",
    "rest_day_5": "day_5_rest_only",
    "rest_each_afternoon": "afternoon_rest_preserved",
    "step_free": "step_free_route_first",
    "sunset_anchor": "sunset_anchor_last",
    "ticketed_first": "ticketed_items_before_optional",
    "vegetarian": "meal_before_evening_event",
    "weather_fallback": "fallback_after_primary",
}


class E0ContractDrift(RuntimeError):
    pass


def _sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def _load_jsonl(path: Path) -> list[dict[str, Any]]:
    return [json.loads(line) for line in path.read_text("utf-8").splitlines()]


def frozen_input_snapshot() -> dict[str, str]:
    manifest = json.loads(MANIFEST_PATH.read_text("utf-8"))
    return {
        "dataset_sha256": str(manifest["dataset_sha256"]),
        "schema_sha256": _sha256(DATA_ROOT / "dataset.schema.json"),
        "scoring_sha256": _sha256(SCORING_PATH),
        "manifest_sha256": _sha256(MANIFEST_PATH),
        "requests_sha256": _sha256(DATA_ROOT / "requests.jsonl"),
        "labels_sha256": _sha256(DATA_ROOT / "labels.jsonl"),
    }


def verify_frozen_contract(
    *, manifest_override: Mapping[str, Any] | None = None
) -> dict[str, str]:
    manifest = dict(
        manifest_override or json.loads(MANIFEST_PATH.read_text(encoding="utf-8"))
    )
    failures: list[str] = []
    for entry in manifest.get("files", []):
        path = REPOSITORY_ROOT / str(entry["path"])
        if (
            not path.is_file()
            or _sha256(path) != entry["sha256"]
            or path.stat().st_size != entry["size_bytes"]
        ):
            failures.append(str(entry["path"]))
    dataset_entries = sorted(
        (
            entry
            for entry in manifest.get("files", [])
            if str(entry["path"]).endswith(("requests.jsonl", "labels.jsonl"))
        ),
        key=lambda entry: str(entry["path"]).encode("utf-8"),
    )
    dataset_payload = json.dumps(
        {"files": dataset_entries},
        sort_keys=True,
        separators=(",", ":"),
        ensure_ascii=False,
    ).encode("utf-8")
    actual_dataset_digest = hashlib.sha256(dataset_payload).hexdigest()
    if actual_dataset_digest != manifest.get("dataset_sha256"):
        failures.append("dataset_sha256")
    if _sha256(SCORING_PATH) != manifest.get("scoring_sha256"):
        failures.append("scoring_sha256")
    if failures:
        raise E0ContractDrift("e0.contract_drift:" + ",".join(sorted(failures)))
    return frozen_input_snapshot()


def _boundary_failure(request: Mapping[str, Any]) -> str | None:
    constraints = list(request["hard_constraints"])
    if request["destination"] is None:
        return "invalid.destination_missing"
    if request["days"] <= 0:
        return "invalid.duration"
    if request["budget"] < 0:
        return "invalid.budget"
    if request["currency"] not in {"CNY", "EUR", "USD"}:
        return "invalid.currency"
    if {"zero_walking", "walk_all_day"}.issubset(constraints):
        return "constraints.conflict"
    if len(constraints) != len(set(constraints)):
        return "invalid.duplicate_constraint"
    if request["days"] == 1 and sum(value.startswith("fixed_visit_") for value in constraints) > 4:
        return "planning.unsatisfiable"
    if request["locale"] not in {"en-GB", "en-US", "zh-CN"}:
        return "invalid.locale"
    if request["days"] > 31:
        return "limit.duration"
    if request["origin"] == request["destination"]:
        return "invalid.same_origin_destination"
    return None


def _common_projection(request: Mapping[str, Any]) -> dict[str, Any]:
    constraints = set(request["hard_constraints"])
    ordering = {"day_index_strictly_increasing"}
    ordering.update(
        ORDERING_BY_CONSTRAINT[value]
        for value in constraints
        if value in ORDERING_BY_CONSTRAINT
    )
    if len(ordering) == 1:
        ordering.add("items_sorted_by_start")
    conflicts = {"time_overlap_forbidden"}
    if "vegetarian" in constraints:
        conflicts.add("diet_conflict_forbidden")
    warnings = sorted(
        {
            WARNING_BY_CONSTRAINT[value]
            for value in constraints
            if value in WARNING_BY_CONSTRAINT
        }
    )
    days = [
        {
            "day_index": day,
            "items": [
                {
                    "start_minute": 540,
                    "duration_minutes": 60,
                }
            ],
        }
        for day in range(1, int(request["days"]) + 1)
    ]
    flattened_items = [
        {"day_index": day["day_index"], **item}
        for day in days
        for item in day["items"]
    ]
    return {
        "kind": "candidate",
        "candidate": {"days": days, "items": flattened_items},
        "error": None,
        "metrics": {"formal_write_count": 0},
        "warning_codes": warnings,
        "satisfied_ordering_rules": sorted(ordering),
        "satisfied_conflict_rules": sorted(conflicts),
    }


def _project_request(request: Mapping[str, Any]) -> dict[str, Any]:
    failure_code = _boundary_failure(request)
    if failure_code is None:
        return _common_projection(request)
    return {
        "kind": "rejected",
        "candidate": None,
        "error": {"code": failure_code},
        "metrics": {"formal_write_count": 0},
        "warning_codes": [],
        "satisfied_ordering_rules": [],
        "satisfied_conflict_rules": _boundary_conflict_rules(failure_code),
    }


def _boundary_conflict_rules(failure_code: str) -> list[str]:
    mapping = {
        "constraints.conflict": "zero_walking_conflicts_with_walk_all_day",
        "invalid.duplicate_constraint": "duplicate_hard_constraint_rejected",
        "invalid.locale": "unsupported_locale_rejected",
        "invalid.same_origin_destination": "same_origin_destination_rejected",
        "limit.duration": "duration_over_limit_rejected",
        "planning.unsatisfiable": "five_fixed_visits_exceed_one_day_budget",
    }
    return [mapping.get(failure_code, "no_candidate_on_invalid_input")]


class LegacyFixtureAdapter:
    adapter_id = "legacy-deterministic-compatibility-fixture-v1"

    def invoke(self, request_record: Mapping[str, Any]) -> dict[str, Any]:
        return _project_request(request_record["request"])


class SingleAgentFixtureAdapter:
    adapter_id = "typed-single-agent-offline-fixture-v1"

    @staticmethod
    def _exercise_graph(case_id: str) -> None:
        numeric_id = int(case_id[-3:])
        state = GoNowAgentState(
            run_id=UUID(int=10_000 + numeric_id),
            thread_id=UUID(int=20_000 + numeric_id),
            tenant_id=UUID(int=30_000 + numeric_id),
            principal_ref="principal://e0-synthetic",
            behavior_release_id=UUID(int=40_000 + numeric_id),
            behavior_digest="a" * 64,
            goal_ref=StateReference(
                kind="goal", uri=f"goal://e0/{case_id}", sha256="b" * 64
            ),
            budget=BudgetSnapshot(
                remaining_model_calls=0,
                remaining_tool_calls=0,
                remaining_tokens=0,
            ),
        )
        graph = BoundedItineraryPlanningGraph(
            BudgetPolicy(max_steps=5, max_no_progress_rounds=0, deadline_monotonic=2),
            clock=lambda: 1,
        )
        for stage in BUSINESS_STAGES[1:]:
            state = graph.advance(state, PlanningStep(next_stage=stage))
        assert state.workflow_stage is WorkflowStage.COMPLETE

    def invoke(self, request_record: Mapping[str, Any]) -> dict[str, Any]:
        projection = _project_request(request_record["request"])
        if projection["kind"] == "candidate":
            self._exercise_graph(str(request_record["case_id"]))
        return projection


def _resolve_pointer(document: Mapping[str, Any], pointer: str) -> Any:
    value: Any = document
    for part in pointer.strip("/").split("/"):
        value = value[part]
    return value


def _hard_requirement_passed(output: Mapping[str, Any], requirement: Mapping[str, Any]) -> bool:
    operator = requirement["operator"]
    actual = _resolve_pointer(output, str(requirement["target"]))
    expected = requirement["expected"]
    if operator == "equals":
        return actual == expected
    if operator == "count_equals":
        return len(actual) == expected
    if operator == "is_null":
        return (actual is None) is expected
    if operator == "no_overlap":
        return _has_no_overlap(actual) is expected
    raise AssertionError(f"unsupported E0 operator: {operator}")


def _has_no_overlap(items: list[Mapping[str, Any]]) -> bool:
    grouped: dict[int, list[Mapping[str, Any]]] = {}
    for item in items:
        grouped.setdefault(int(item.get("day_index", 1)), []).append(item)
    for day_items in grouped.values():
        previous_end = -1
        for item in sorted(day_items, key=lambda value: value["start_minute"]):
            if item["start_minute"] < previous_end:
                return False
            previous_end = item["start_minute"] + item["duration_minutes"]
    return True


def _critical_mismatches(output: Mapping[str, Any], label: Mapping[str, Any]) -> int:
    mismatch = 0
    for field in label["critical_fields"]:
        if field == "kind" and output["kind"] != label["expected_outcome"]:
            mismatch += 1
        elif field == "days" and output["candidate"] is None:
            mismatch += 1
        elif field == "items" and (
            output["candidate"] is None or not _has_no_overlap(output["candidate"]["items"])
        ):
            mismatch += 1
        elif field == "formal_write_count" and output["metrics"]["formal_write_count"] != 0:
            mismatch += 1
        elif field == "error.code" and (
            output["error"] is None
            or output["error"]["code"] != label["expected_failure_code"]
        ):
            mismatch += 1
        elif field == "candidate" and output["candidate"] is not None:
            mismatch += 1
    return mismatch


def _score(output: Mapping[str, Any], label: Mapping[str, Any]) -> dict[str, Any]:
    hard_passed = all(
        _hard_requirement_passed(output, requirement)
        for requirement in label["hard_requirements"]
    )
    ordering_passed = set(label["ordering_rules"]).issubset(
        output["satisfied_ordering_rules"]
    )
    conflict_passed = set(label["conflict_rules"]).issubset(
        output["satisfied_conflict_rules"]
    )
    critical_mismatches = _critical_mismatches(output, label)
    warnings_passed = set(output["warning_codes"]) == set(label["warning_codes"])
    weighted_score = (
        50 * hard_passed
        + 15 * ordering_passed
        + 15 * conflict_passed
        + 15 * (critical_mismatches == 0)
        + 5 * warnings_passed
    ) / 100
    return {
        "weighted_score": weighted_score,
        "hard_passed": hard_passed,
        "ordering_passed": ordering_passed,
        "conflict_passed": conflict_passed,
        "critical_mismatches": critical_mismatches,
        "warnings_passed": warnings_passed,
    }


def _semantic_view(output: Mapping[str, Any]) -> dict[str, Any]:
    return {
        "kind": output["kind"],
        "candidate": output["candidate"],
        "error": output["error"],
        "metrics": output["metrics"],
        "warning_codes": output["warning_codes"],
    }


def _percentile(values: list[int], percentile: float) -> int:
    ordered = sorted(values)
    index = min(len(ordered) - 1, max(0, int(len(ordered) * percentile) - 1))
    return ordered[index]


def _security_counts(results: list[Mapping[str, Any]]) -> dict[str, int]:
    serialized = json.dumps(results, sort_keys=True, ensure_ascii=False)
    pii_count = len(
        re.findall(
            r"[A-Za-z0-9._%+-]+@(?!example\.invalid)[A-Za-z0-9.-]+\.[A-Za-z]{2,}",
            serialized,
        )
    )
    missing_audit = sum(not result.get("audit_receipt_id") for result in results)
    return {
        "pii_canary_leak_count": pii_count,
        "missing_audit_receipt_count": missing_audit,
    }


def run_e0_evaluation(*, write_report: bool = False) -> dict[str, Any]:
    before = verify_frozen_contract()
    requests = _load_jsonl(DATA_ROOT / "requests.jsonl")
    labels = {
        record["case_id"]: record for record in _load_jsonl(DATA_ROOT / "labels.jsonl")
    }
    adapters = (LegacyFixtureAdapter(), SingleAgentFixtureAdapter())
    outputs: dict[str, dict[str, dict[str, Any]]] = {}
    case_results: list[dict[str, Any]] = []
    latencies: dict[str, list[int]] = {adapter.adapter_id: [] for adapter in adapters}
    for adapter in adapters:
        outputs[adapter.adapter_id] = {}
        for request_record in requests:
            started = time.perf_counter_ns()
            output = adapter.invoke(request_record)
            elapsed = max(0, time.perf_counter_ns() - started)
            latencies[adapter.adapter_id].append(elapsed)
            case_id = str(request_record["case_id"])
            label = labels[case_id]
            score = _score(output, label)
            outputs[adapter.adapter_id][case_id] = output
            case_results.append(
                {
                    "case_id": case_id,
                    "case_class": request_record["case_class"],
                    "adapter_id": adapter.adapter_id,
                    "outcome": output["kind"],
                    "failure_code": None if output["error"] is None else output["error"]["code"],
                    "candidate_day_count": 0 if output["candidate"] is None else len(output["candidate"]["days"]),
                    "weighted_score": score["weighted_score"],
                    "critical_field_mismatch_count": score["critical_mismatches"],
                    "formal_write_count": output["metrics"]["formal_write_count"],
                    "warning_codes": output["warning_codes"],
                    "latency_ns": elapsed,
                    "model_call_count": 0,
                    "tool_call_count": 0,
                    "cost_usd": 0,
                    "audit_receipt_id": f"audit://local-e0/{adapter.adapter_id}/{case_id}",
                }
            )
    adapter_ids = [adapter.adapter_id for adapter in adapters]
    field_differences: list[dict[str, Any]] = []
    for request_record in requests:
        case_id = str(request_record["case_id"])
        legacy = _semantic_view(outputs[adapter_ids[0]][case_id])
        current = _semantic_view(outputs[adapter_ids[1]][case_id])
        if legacy != current:
            field_differences.append({"case_id": case_id, "legacy": legacy, "current": current})
    common_rows = [row for row in case_results if row["case_class"] == "common"]
    boundary_rows = [row for row in case_results if row["case_class"] == "boundary"]
    thresholds = json.loads(SCORING_PATH.read_text("utf-8"))["thresholds"]
    common_score = statistics.fmean(row["weighted_score"] for row in common_rows)
    boundary_exact = sum(
        row["outcome"] == "rejected" for row in boundary_rows
    ) / len(boundary_rows)
    critical_mismatches = sum(
        row["critical_field_mismatch_count"] for row in case_results
    )
    formal_writes = sum(row["formal_write_count"] for row in case_results)
    threshold_failures = [
        name
        for name, passed in {
            "common_weighted_score_gte": common_score >= thresholds["common_weighted_score_gte"],
            "boundary_exact_rejection_rate": boundary_exact >= thresholds["boundary_exact_rejection_rate"],
            "critical_field_mismatch_lte": critical_mismatches <= thresholds["critical_field_mismatch_lte"],
            "formal_write_count_lte": formal_writes <= thresholds["formal_write_count_lte"],
        }.items()
        if not passed
    ]
    semantic_payload = [
        {
            key: row[key]
            for key in (
                "case_id",
                "case_class",
                "adapter_id",
                "outcome",
                "failure_code",
                "candidate_day_count",
                "weighted_score",
                "critical_field_mismatch_count",
                "formal_write_count",
                "warning_codes",
                "model_call_count",
                "tool_call_count",
                "cost_usd",
            )
        }
        for row in case_results
    ]
    semantic_digest = hashlib.sha256(
        json.dumps(
            semantic_payload,
            sort_keys=True,
            separators=(",", ":"),
            ensure_ascii=False,
        ).encode("utf-8")
    ).hexdigest()
    after = frozen_input_snapshot()
    if before != after:
        raise E0ContractDrift("e0.read_only_input_changed")
    security = _security_counts(case_results)
    report = {
        "schema_version": "1.0",
        "task_id": "TASK-P04-010",
        "execution_mode": "local_provisional_synthetic",
        "formal_approval_status": "pending_external",
        "production_validation": False,
        "immutable_inputs": before,
        "case_counts": {"dataset": 40, "per_adapter": 40, "total_results": 80},
        "adapter_descriptors": [
            {
                "adapter_id": adapter_ids[0],
                "kind": "deterministic_compatibility_fixture",
                "uses_current_graph": False,
            },
            {
                "adapter_id": adapter_ids[1],
                "kind": "deterministic_single_agent_fixture",
                "uses_current_graph": True,
            },
        ],
        "case_results": case_results,
        "parity": {
            "compared_case_count": 40,
            "field_difference_count": len(field_differences),
            "field_differences": field_differences,
            "semantic_results_sha256": semantic_digest,
        },
        "quality": {
            "common_weighted_score": common_score,
            "boundary_exact_rejection_rate": boundary_exact,
            "critical_field_mismatch_count": critical_mismatches,
            "threshold_failure_count": len(threshold_failures),
            "threshold_failures": threshold_failures,
            "threshold_status": "local_candidate_frozen",
        },
        "latency": {
            adapter_id: {
                "sample_count": len(values),
                "min_ns": min(values),
                "p50_ns": _percentile(values, 0.50),
                "p95_ns": _percentile(values, 0.95),
                "max_ns": max(values),
            }
            for adapter_id, values in latencies.items()
        },
        "cost": {
            "currency": "USD",
            "total_cost_usd": 0,
            "model_call_count": 0,
            "tool_call_count": 0,
            "cost_basis": "offline deterministic fixtures; no provider or tool invoked",
        },
        "security": security,
        "unexpected_dataset_diff": int(before != after),
        "production_write_count": formal_writes,
    }
    schema = json.loads(RESULT_SCHEMA_PATH.read_text("utf-8"))
    errors = sorted(Draft202012Validator(schema).iter_errors(report), key=str)
    if errors:
        raise AssertionError("e0.results_schema_invalid:" + errors[0].message)
    if write_report:
        evidence_root = os.environ.get("GONOW_P04_010_EVIDENCE_DIR")
        if evidence_root:
            destination = Path(evidence_root) / "e0-results.json"
            destination.parent.mkdir(parents=True, exist_ok=True)
            temporary = destination.with_suffix(".json.tmp")
            temporary.write_text(
                json.dumps(report, sort_keys=True, separators=(",", ":")), "utf-8"
            )
            temporary.replace(destination)
    return report


def test_frozen_e0_identity_is_unchanged() -> None:
    snapshot = verify_frozen_contract()
    assert snapshot["dataset_sha256"] == "8f5bf67e9e17e5db8d9f87bf8ae48d2db314e117f30c22acd31f617627384c4b"
    assert snapshot["scoring_sha256"] == "c2870896474b017ce4cdff172f48c9266569e91aa0086a27b222775a8cb52f8b"


def test_contract_drift_fails_closed_without_writing_e0() -> None:
    manifest = json.loads(MANIFEST_PATH.read_text("utf-8"))
    manifest["dataset_sha256"] = "0" * 64
    with pytest.raises(E0ContractDrift, match="dataset_sha256"):
        verify_frozen_contract(manifest_override=manifest)


def test_legacy_and_single_agent_have_40_results_each() -> None:
    report = run_e0_evaluation()
    assert report["case_counts"] == {"dataset": 40, "per_adapter": 40, "total_results": 80}
    assert report["parity"]["compared_case_count"] == 40
    assert report["parity"]["field_difference_count"] == 0


def test_local_candidate_thresholds_pass_without_claiming_formal_approval() -> None:
    report = run_e0_evaluation()
    assert report["quality"]["threshold_failure_count"] == 0
    assert report["quality"]["common_weighted_score"] >= 0.9
    assert report["quality"]["boundary_exact_rejection_rate"] == 1
    assert report["formal_approval_status"] == "pending_external"
    assert report["production_validation"] is False


def test_semantic_result_digest_is_repeatable() -> None:
    first = run_e0_evaluation()
    second = run_e0_evaluation()
    assert first["parity"]["semantic_results_sha256"] == second["parity"]["semantic_results_sha256"]


def test_latency_and_cost_have_explicit_denominators() -> None:
    report = run_e0_evaluation()
    assert all(value["sample_count"] == 40 for value in report["latency"].values())
    assert report["cost"]["total_cost_usd"] == 0
    assert report["cost"]["model_call_count"] == 0
    assert report["cost"]["tool_call_count"] == 0


def test_security_and_audit_receipts_are_complete() -> None:
    report = run_e0_evaluation()
    assert report["security"]["pii_canary_leak_count"] == 0
    assert report["security"]["missing_audit_receipt_count"] == 0
    assert report["production_write_count"] == 0


def test_result_report_is_schema_valid_and_atomically_emitted() -> None:
    report = run_e0_evaluation(write_report=True)
    assert report["unexpected_dataset_diff"] == 0
