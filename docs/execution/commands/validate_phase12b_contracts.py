#!/usr/bin/env python3
"""Validate the selected local-provisional P12B contract and focused evidence."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import subprocess
import tempfile
from pathlib import Path
from typing import Any


TASK_IDS = [
    "TASK-P12B-010",
    "TASK-P12B-020",
    "TASK-P12B-030",
    "TASK-P12B-040",
    "TASK-P12B-050",
    "TASK-P12B-060",
    "TASK-P12B-990",
    "TASK-P12B-999",
]


def load(path: Path) -> dict[str, Any]:
    value = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(value, dict):
        raise ValueError(f"{path} must contain an object")
    return value


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def export_catalog(root: Path) -> dict[str, Any]:
    with tempfile.TemporaryDirectory(prefix="gonow-p12b-catalog-") as directory:
        output = Path(directory) / "catalog.json"
        command = [
            r"C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe",
            "-NoProfile",
            "-ExecutionPolicy",
            "Bypass",
            "-File",
            str(root / "tool/bootstrap/Export-TaskGateCatalog.ps1"),
            "-CatalogPath",
            str(root / "docs/execution/commands/TaskGateCatalog.psd1"),
            "-OutputPath",
            str(output),
        ]
        environment = os.environ.copy()
        native_modules = r"C:\Windows\System32\WindowsPowerShell\v1.0\Modules"
        environment["PSModulePath"] = native_modules + os.pathsep + environment.get("PSModulePath", "")
        subprocess.run(command, check=True, text=True, capture_output=True, env=environment)
        return load(output)


def validate_task_010(root: Path, errors: list[str]) -> None:
    evidence_root = root / "docs/execution/evidence/phase-12b/P12B-010"
    required = [
        "calibration-dataset-manifest.json",
        "metrics-binding.json",
        "price-snapshot.json",
        "route-scope.json",
        "trigger-evidence.json",
    ]
    for name in required:
        if not (evidence_root / name).is_file():
            errors.append(f"P12B-010 evidence missing: {name}")
    scope_path = evidence_root / "route-scope.json"
    if scope_path.is_file():
        scope = load(scope_path)
        if scope.get("route_scope_count") != 1 or scope.get("runtime_entry") != "server:itinerary_generation":
            errors.append("P12B-010 must freeze exactly the server itinerary-generation route")
        if scope.get("production_fact_claim_count") != 0:
            errors.append("P12B-010 invents a production fact")
    manifest_path = evidence_root / "calibration-dataset-manifest.json"
    if manifest_path.is_file():
        manifest = load(manifest_path)
        count = int(manifest.get("scenario_count", -1))
        if count < 1 or count > 20:
            errors.append("P12B-010 scenario count is outside 1..20")
        dataset_path = root / manifest.get("dataset_path", "")
        if not dataset_path.is_file() or digest(dataset_path) != manifest.get("dataset_sha256"):
            errors.append("P12B-010 dataset hash binding failed")
    metrics_path = evidence_root / "metrics-binding.json"
    if metrics_path.is_file():
        metrics = load(metrics_path)
        budgets = metrics.get("live_budget", {})
        if budgets != {"max_tasks": 20, "max_live_calls": 40, "max_total_tokens": 100000}:
            errors.append("P12B-010 live budget differs from the user ceiling")
        if metrics.get("primary_metric") != "total_cost_per_successful_quality_qualified_task":
            errors.append("P12B-010 primary metric changed")
        if metrics.get("same_failure_denominator") is not True:
            errors.append("P12B-010 failure denominator is not frozen")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repository-root", type=Path, default=Path.cwd())
    parser.add_argument("--task", default="P12B-000")
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    root = args.repository_root.resolve()
    requested = args.task if args.task.startswith("TASK-") else f"TASK-{args.task}"
    errors: list[str] = []

    selection = load(root / "docs/execution/evidence/phase-12b/P12B-000/selection-record.json")
    contract = load(root / "docs/execution/evidence/phase-12b/P12B-000/proposed-execution-contract.json")
    catalog = export_catalog(root)
    catalog_tasks = catalog.get("Tasks", {})
    if selection.get("selected_candidate") != "P12B" or selection.get("selected_count") != 1:
        errors.append("selection must name exactly P12B")
    if sorted(selection.get("unselected_candidates", [])) != ["P12A", "P12C", "P12D"]:
        errors.append("selection XOR is invalid")
    if selection.get("phase_base_oid") != "f941051871ecd7ea811540072a032ce7aaa0119d":
        errors.append("phase base OID mismatch")
    if contract.get("activation_state") != "selected_local_provisional":
        errors.append("execution contract is not selected local provisional")
    if contract.get("single_agent_architecture") is not True or contract.get("multi_agent_framework_allowed") is not False:
        errors.append("Single-Agent architecture boundary is not frozen")
    for task_id in TASK_IDS:
        if task_id not in catalog_tasks:
            errors.append(f"Catalog task missing: {task_id}")
    for task in contract.get("tasks", []):
        catalog_task = catalog_tasks.get(task.get("task_id"), {})
        if catalog_task.get("file_allowlist") != task.get("file_allowlist"):
            errors.append(f"exact allowlist mismatch: {task.get('task_id')}")
    if catalog_tasks.get("TASK-P12-089", {}).get("prerequisite_task_ids") != ["TASK-P12A-990"]:
        errors.append("global P12-089 does not depend exactly on the current P12A-990 cycle")
    if catalog_tasks.get("TASK-P12B-999", {}).get("prerequisite_task_ids") != ["TASK-P12B-990", "TASK-P12-089"]:
        errors.append("P12B-999 dependency order is invalid")
    if "Push" in catalog_tasks.get("TASK-P12B-999", {}).get("allowed_phase_merge_modes", []):
        errors.append("P12B-999 permits remote push")
    if requested == "TASK-P12B-010":
        validate_task_010(root, errors)

    result = {
        "schema_version": "1.0",
        "gate_id": "P12B-EXECUTION-CONTRACT",
        "task_id": requested,
        "catalog_version": catalog.get("CatalogVersion"),
        "catalog_task_count": len(catalog_tasks),
        "selected_candidate": selection.get("selected_candidate"),
        "selected_count": selection.get("selected_count"),
        "single_agent_architecture": contract.get("single_agent_architecture"),
        "multi_agent_framework_allowed": contract.get("multi_agent_framework_allowed"),
        "production_write_count": 0,
        "error_count": len(errors),
        "errors": errors,
        "overall_status": "passed" if not errors else "failed",
    }
    encoded = json.dumps(result, ensure_ascii=False, indent=2) + "\n"
    if args.output:
        output = args.output if args.output.is_absolute() else root / args.output
        output.parent.mkdir(parents=True, exist_ok=True)
        output.write_text(encoded, encoding="utf-8", newline="\n")
    print(encoded, end="")
    return 0 if not errors else 3


if __name__ == "__main__":
    raise SystemExit(main())
