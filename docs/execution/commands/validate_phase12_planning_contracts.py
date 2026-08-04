#!/usr/bin/env python3
"""Validate dormant Phase 12 A/B/D execution and STAR planning contracts.

This validator is intentionally limited to document-time contracts. It never treats a
dormant template as trigger evidence, implementation approval, or a STAR result.
"""

from __future__ import annotations

import argparse
import copy
import hashlib
import json
import os
import re
import subprocess
import tempfile
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from jsonschema import Draft202012Validator, FormatChecker


PACKAGES = {
    "P12A": {
        "suffix": "a",
        "direct_ct": ["CT-009", "CT-015"],
        "primary": "paired_task_success_net_gain_pp",
        "diagnostic": "correct_recall_rate",
        "required_redline": "retrieved_injection_executed_action_count",
    },
    "P12B": {
        "suffix": "b",
        "direct_ct": [],
        "primary": "total_cost_per_successful_quality_qualified_task",
        "diagnostic": "retry_fallback_cost_amplification_ratio",
        "required_redline": "quality_floor_violation_count",
    },
    "P12D": {
        "suffix": "d",
        "direct_ct": [],
        "primary": "pending_one_of_closed_write_reliability_profile",
        "diagnostic": "command_receipt_coverage_rate",
        "required_redline": "duplicate_formal_write_count",
    },
}


def load_json(path: Path) -> dict[str, Any]:
    with path.open("r", encoding="utf-8") as handle:
        value = json.load(handle)
    if not isinstance(value, dict):
        raise ValueError(f"{path} must contain a JSON object")
    return value


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def schema_errors(schema: dict[str, Any], value: dict[str, Any]) -> list[str]:
    validator = Draft202012Validator(schema, format_checker=FormatChecker())
    return [
        f"{'/'.join(str(item) for item in error.absolute_path) or '<root>'}: {error.message}"
        for error in sorted(validator.iter_errors(value), key=lambda item: list(item.absolute_path))
    ]


def semantic_execution_errors(candidate: str, value: dict[str, Any]) -> list[str]:
    errors: list[str] = []
    expected = PACKAGES[candidate]
    if value.get("candidate") != candidate:
        errors.append("candidate mismatch")
    if value.get("stable_ct_disposition", {}).get("direct_applicable") != expected["direct_ct"]:
        errors.append("stable direct CT semantics changed")
    task_ids = [task.get("task_id") for task in value.get("tasks", [])]
    expected_ids = [f"TASK-{candidate}-0{index}0" for index in range(1, 7)]
    if task_ids != expected_ids:
        errors.append("atomic task IDs or order differ from 010..060")
    test_ids: list[str] = []
    for index, task in enumerate(value.get("tasks", []), start=1):
        allowlist = task.get("file_allowlist", [])
        status = task.get("file_allowlist_status")
        if index == 1 and (not allowlist or status != "exact_proposed"):
            errors.append("010 must have an exact proposed evidence-only allowlist")
        if index > 1 and (allowlist or status != "must_bind_before_activation"):
            errors.append(f"0{index}0 must fail closed until exact activation allowlist is bound")
        test_ids.extend(task.get("test_node_ids", []))
    if len(test_ids) != len(set(test_ids)):
        errors.append("candidate test node IDs are not unique")
    handoff = value.get("global_089_handoff", {})
    if handoff.get("task_id") != "TASK-P12-089" or not handoff.get("no_candidate_specific_089_created"):
        errors.append("global TASK-P12-089 handoff is missing")
    if any("-089" in str(item) for item in task_ids):
        errors.append("candidate-specific 089 task is forbidden")
    if candidate == "P12B" and not any(
        item.startswith("CT-011:")
        for item in value.get("stable_ct_disposition", {}).get("explicit_non_applicable", [])
    ):
        errors.append("P12B must explain why stable CT-011 is not directly applicable")
    return errors


def semantic_metrics_errors(candidate: str, value: dict[str, Any]) -> list[str]:
    errors: list[str] = []
    expected = PACKAGES[candidate]
    if value.get("candidate") != candidate:
        errors.append("candidate mismatch")
    primary = value.get("primary_result", {})
    diagnostic = value.get("diagnostic", {})
    if primary.get("metric_id") != expected["primary"] or primary.get("role") != "primary_result":
        errors.append("primary metric role or ID differs from preregistration")
    if diagnostic.get("metric_id") != expected["diagnostic"] or diagnostic.get("role") != "diagnostic":
        errors.append("diagnostic metric role or ID differs from preregistration")
    redlines = value.get("redlines", [])
    redline_ids = {item.get("metric_id") for item in redlines}
    if expected["required_redline"] not in redline_ids:
        errors.append("required package redline is absent")
    for redline in redlines:
        if redline.get("role") != "redline" or redline.get("threshold") != "0 hard_redline":
            errors.append("redline is not represented as an exact zero hard boundary")
        if redline.get("averaging_allowed") is not False:
            errors.append("redline permits averaging")
        if not redline.get("denominator"):
            errors.append("redline denominator is missing")
    if candidate == "P12D" and primary.get("metric_id") == "duplicate_formal_write_count":
        errors.append("P12D duplicate count is a redline, not an improvement primary")
    if candidate == "P12B" and diagnostic.get("metric_id") == "quality_floor_violation_count":
        errors.append("P12B quality floor is a redline, not a cost diagnostic")
    if value.get("statistical_plan", {}).get("zero_success_handling") != "undefined_fail_closed":
        errors.append("zero-success cost/result handling is not fail closed")
    if len(value.get("no_claim_boundary", [])) < 3:
        errors.append("no-claim boundary is incomplete")
    return errors


def trigger_fixture(candidate: str) -> dict[str, Any]:
    common: dict[str, Any] = {
        "schema_version": "1.0",
        "candidate": candidate,
        "task_id": f"TASK-{candidate}-010",
        "release_b_head_oid": "1" * 40,
        "dataset_sha256": "2" * 64,
        "source_window": {
            "start_at": "2026-01-01T00:00:00+08:00",
            "end_at": "2026-02-01T00:00:00+08:00",
            "timezone": "Asia/Shanghai",
        },
        "denominator": {"metric_id": "eligible_units", "value": 100, "unit": "tasks"},
        "exclusion_rules": ["verified infrastructure outage only"],
        "estimator": {"name": "test-only-estimator", "version": "1", "formula": "x / n"},
        "uncertainty": {
            "confidence_level": 0.95,
            "interval_method": "test-only exact interval",
            "lower": 0.1,
            "upper": 0.2,
        },
        "trigger_threshold": {
            "metric_id": "test_trigger",
            "operator": ">=",
            "value": 0.1,
            "unit": "ratio",
            "source_ref": "test-only owner decision",
        },
        "trigger_decision": "positive",
        "owner_decision_ref": "test-only owner decision",
        "recorded_at": "2026-02-01T00:00:00+08:00",
    }
    if candidate == "P12A":
        common["package_fields"] = {
            "calibrated_trigger": "missing durable fact failure rate",
            "eligible_failure_numerator": 20,
            "consent_purpose_decision_ref": "test-only purpose",
            "licensed_deidentified_dataset": True,
        }
    elif candidate == "P12B":
        common["package_fields"] = {
            "complete_comparable_weeks": 4,
            "price_snapshot_version": "test-only-v1",
            "price_snapshot_sha256": "3" * 64,
            "tco_formula": "all cost / successful tasks",
            "quality_noninferiority_margin_pp": 0.5,
        }
    else:
        common["package_fields"] = {
            "selected_write_entry": "test-only:itinerary-update",
            "selected_primary_metric_id": "duplicate_effect_rate_per_10k_intents",
            "impact_map_sha256": "4" * 64,
            "unknown_critical_side_effect_count": 0,
        }
    return common


def git_head(root: Path) -> str:
    result = subprocess.run(
        ["git", "-C", str(root), "rev-parse", "HEAD"],
        check=True,
        text=True,
        capture_output=True,
    )
    return result.stdout.strip()


def write_atomic_json(path: Path, value: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary = tempfile.mkstemp(prefix=f".{path.name}.", suffix=".tmp", dir=path.parent)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8", newline="\n") as handle:
            json.dump(value, handle, ensure_ascii=False, indent=2)
            handle.write("\n")
        os.replace(temporary, path)
    except Exception:
        if os.path.exists(temporary):
            os.unlink(temporary)
        raise


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repository-root", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    root = args.repository_root.resolve()
    output = args.output if args.output.is_absolute() else root / args.output

    errors: list[str] = []
    validated_paths: list[str] = []
    negative_tests: list[dict[str, Any]] = []
    schema_paths = {
        "execution": root / "docs/execution/schemas/phase12-candidate-execution-contract-v1.schema.json",
        "metrics": root / "docs/execution/schemas/phase12-star-preregistration-v1.schema.json",
        "trigger": root / "docs/execution/schemas/phase12-trigger-evidence-v1.schema.json",
    }
    schemas = {name: load_json(path) for name, path in schema_paths.items()}
    for name, schema in schemas.items():
        Draft202012Validator.check_schema(schema)
        validated_paths.append(str(schema_paths[name].relative_to(root)).replace("\\", "/"))

    guidance_path = root / "docs/execution/evidence/phase-12/ABD-PLAN-HARDENING/guidance-index.json"
    guidance = load_json(guidance_path)
    validated_paths.append(str(guidance_path.relative_to(root)).replace("\\", "/"))
    for source in guidance.get("guidance_sources", []):
        source_path = root / source["path"]
        if not source_path.is_file() or sha256(source_path) != source["sha256"]:
            errors.append(f"guidance hash mismatch: {source['path']}")

    documents: dict[str, dict[str, dict[str, Any]]] = {}
    for candidate, package in PACKAGES.items():
        evidence = root / f"docs/execution/evidence/phase-12{package['suffix']}/{candidate}-000"
        execution_path = evidence / "proposed-execution-contract.json"
        metrics_path = evidence / "metrics-preregistration.json"
        execution = load_json(execution_path)
        metrics = load_json(metrics_path)
        documents[candidate] = {"execution": execution, "metrics": metrics}
        for path in (execution_path, metrics_path):
            validated_paths.append(str(path.relative_to(root)).replace("\\", "/"))
        errors.extend(f"{candidate} execution schema: {item}" for item in schema_errors(schemas["execution"], execution))
        errors.extend(f"{candidate} execution semantic: {item}" for item in semantic_execution_errors(candidate, execution))
        errors.extend(f"{candidate} metrics schema: {item}" for item in schema_errors(schemas["metrics"], metrics))
        errors.extend(f"{candidate} metrics semantic: {item}" for item in semantic_metrics_errors(candidate, metrics))

        plan_path = root / f"docs/execution/evidence/phase-12/{candidate}-000/task-plan.md"
        plan = plan_path.read_text(encoding="utf-8")
        for marker in ("guidance-index.json", "proposed-execution-contract.json", "Pre-registered STAR contract", "TASK-P12-089"):
            if marker not in plan:
                errors.append(f"{candidate} plan missing {marker}")
        candidate_089 = re.compile(
            rf"(?m)^(?:Atomic task:\s*)?TASK-{candidate}-089\s*$|->\s*(?:TASK-)?{candidate}-089\b"
        )
        if candidate_089.search(plan):
            errors.append(f"{candidate} plan materializes a candidate-specific 089")

    for candidate in PACKAGES:
        valid_trigger = trigger_fixture(candidate)
        trigger_failures = schema_errors(schemas["trigger"], valid_trigger)
        if trigger_failures:
            errors.extend(f"{candidate} positive trigger fixture: {item}" for item in trigger_failures)

    negative_metrics = copy.deepcopy(documents["P12A"]["metrics"])
    del negative_metrics["primary_result"]["denominator"]
    result = bool(schema_errors(schemas["metrics"], negative_metrics))
    negative_tests.append({"test_id": "missing_metric_denominator_rejected", "passed": result})
    if not result:
        errors.append("negative test failed: missing metric denominator accepted")

    negative_redline = copy.deepcopy(documents["P12B"]["metrics"])
    negative_redline["redlines"][0]["averaging_allowed"] = True
    result = bool(schema_errors(schemas["metrics"], negative_redline)) or bool(semantic_metrics_errors("P12B", negative_redline))
    negative_tests.append({"test_id": "averageable_redline_rejected", "passed": result})
    if not result:
        errors.append("negative test failed: averageable redline accepted")

    negative_activation = copy.deepcopy(documents["P12D"]["execution"])
    negative_activation["activation_ready"] = True
    result = bool(schema_errors(schemas["execution"], negative_activation))
    negative_tests.append({"test_id": "dormant_activation_ready_rejected", "passed": result})
    if not result:
        errors.append("negative test failed: dormant activation_ready=true accepted")

    negative_ct = copy.deepcopy(documents["P12B"]["execution"])
    negative_ct["stable_ct_disposition"]["direct_applicable"] = ["CT-011"]
    result = bool(semantic_execution_errors("P12B", negative_ct))
    negative_tests.append({"test_id": "stable_ct_repurpose_rejected", "passed": result})
    if not result:
        errors.append("negative test failed: stable CT repurpose accepted")

    negative_trigger = trigger_fixture("P12D")
    negative_trigger["package_fields"]["selected_write_entry"] = "none"
    negative_trigger["package_fields"]["selected_primary_metric_id"] = "none"
    result = bool(schema_errors(schemas["trigger"], negative_trigger))
    negative_tests.append({"test_id": "p12d_positive_none_write_entry_rejected", "passed": result})
    if not result:
        errors.append("negative test failed: P12D selected_write_entry=none accepted as positive evidence")

    valid_negative_trigger = trigger_fixture("P12D")
    valid_negative_trigger["trigger_decision"] = "negative"
    valid_negative_trigger["package_fields"]["selected_write_entry"] = "none"
    valid_negative_trigger["package_fields"]["selected_primary_metric_id"] = "none"
    valid_negative_errors = schema_errors(schemas["trigger"], valid_negative_trigger)
    if valid_negative_errors:
        errors.extend(f"P12D negative trigger fixture: {item}" for item in valid_negative_errors)

    receipt = {
        "schema_version": "1.0",
        "gate_id": "PHASE12-ABD-PLANNING-CONTRACTS",
        "head_oid": git_head(root),
        "validated_paths": sorted(validated_paths),
        "validated_document_count": len(validated_paths),
        "positive_package_count": len(PACKAGES),
        "negative_tests": negative_tests,
        "negative_test_pass_count": sum(1 for item in negative_tests if item["passed"]),
        "error_count": len(errors),
        "errors": errors,
        "overall_status": "passed" if not errors else "failed",
        "formal_selection_status": "pending",
        "runtime_or_contract_change_count": 0,
        "recorded_at": datetime.now(timezone.utc).astimezone().isoformat(),
    }
    write_atomic_json(output, receipt)
    print(json.dumps(receipt, ensure_ascii=False, indent=2))
    return 0 if not errors else 3


if __name__ == "__main__":
    raise SystemExit(main())
