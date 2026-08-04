#!/usr/bin/env python3
"""Validate the selected local-provisional P12D task contract and focused evidence."""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import tempfile
from pathlib import Path
from typing import Any

from jsonschema import Draft202012Validator, FormatChecker


TASK_IDS = [
    "TASK-P12D-010",
    "TASK-P12D-020",
    "TASK-P12D-030",
    "TASK-P12D-040",
    "TASK-P12D-050",
    "TASK-P12D-060",
    "TASK-P12D-990",
    "TASK-P12D-999",
]


def load(path: Path) -> dict[str, Any]:
    value = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(value, dict):
        raise ValueError(f"{path} must contain an object")
    return value


def export_catalog(root: Path) -> dict[str, Any]:
    with tempfile.TemporaryDirectory(prefix="gonow-p12d-catalog-") as directory:
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


def schema_errors(schema: dict[str, Any], value: dict[str, Any]) -> list[str]:
    validator = Draft202012Validator(schema, format_checker=FormatChecker())
    return [
        f"{'/'.join(str(part) for part in error.absolute_path) or '<root>'}: {error.message}"
        for error in sorted(validator.iter_errors(value), key=lambda item: list(item.absolute_path))
    ]


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repository-root", type=Path, default=Path.cwd())
    parser.add_argument("--task", default="P12D-000")
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    root = args.repository_root.resolve()
    requested = args.task if args.task.startswith("TASK-") else f"TASK-{args.task}"
    errors: list[str] = []

    selection = load(root / "docs/execution/evidence/phase-12d/P12D-000/selection-record.json")
    contract = load(root / "docs/execution/evidence/phase-12d/P12D-000/proposed-execution-contract.json")
    catalog = export_catalog(root)
    if selection.get("selected_candidate") != "P12D" or selection.get("selected_count") != 1:
        errors.append("selection must name exactly P12D")
    if sorted(selection.get("unselected_candidates", [])) != ["P12A", "P12B", "P12C"]:
        errors.append("selection XOR is invalid")
    if selection.get("phase_base_oid") != "eab09d679a0cfd01e639dbc16bdc19a27dae5cb2":
        errors.append("phase base OID mismatch")
    if contract.get("activation_state") != "selected_local_provisional":
        errors.append("execution contract is not selected local provisional")
    if contract.get("single_agent_architecture") is not True or contract.get("multi_agent_framework_allowed") is not False:
        errors.append("Single-Agent architecture boundary is not frozen")
    catalog_tasks = catalog.get("Tasks", {})
    for task_id in TASK_IDS:
        if task_id not in catalog_tasks:
            errors.append(f"Catalog task missing: {task_id}")
    for task in contract.get("tasks", []):
        catalog_task = catalog_tasks.get(task.get("task_id"), {})
        if catalog_task.get("file_allowlist") != task.get("file_allowlist"):
            errors.append(f"exact allowlist mismatch: {task.get('task_id')}")
    if catalog_tasks.get("TASK-P12-089", {}).get("prerequisite_task_ids") != ["TASK-P12D-990"]:
        errors.append("global P12-089 does not depend exactly on P12D-990")
    if catalog_tasks.get("TASK-P12D-999", {}).get("prerequisite_task_ids") != ["TASK-P12D-990", "TASK-P12-089"]:
        errors.append("P12D-999 dependency order is invalid")
    if "Push" in catalog_tasks.get("TASK-P12D-999", {}).get("allowed_phase_merge_modes", []):
        errors.append("P12D-999 permits remote push")

    if requested == "TASK-P12D-010":
        evidence_root = root / "docs/execution/evidence/phase-12d/P12D-010"
        required = [
            "repository-write-inventory.json",
            "impact-map.json",
            "trigger-evidence.json",
            "metrics-binding.json",
        ]
        for name in required:
            if not (evidence_root / name).is_file():
                errors.append(f"P12D-010 evidence missing: {name}")
        trigger_path = evidence_root / "trigger-evidence.json"
        if trigger_path.is_file():
            trigger = load(trigger_path)
            schema = load(root / "docs/execution/schemas/phase12-trigger-evidence-v1.schema.json")
            errors.extend(f"trigger schema {item}" for item in schema_errors(schema, trigger))
            fields = trigger.get("package_fields", {})
            if trigger.get("trigger_decision") != "positive" or fields.get("selected_write_entry") in (None, "none"):
                errors.append("P12D-010 must freeze one positive selected write entry")
            if fields.get("unknown_critical_side_effect_count") != 0:
                errors.append("unknown critical side effects must equal zero")
        inventory_path = evidence_root / "repository-write-inventory.json"
        if inventory_path.is_file():
            inventory = load(inventory_path)
            if inventory.get("selected_write_entry_count") != 1:
                errors.append("repository inventory must select exactly one write entry")
            if inventory.get("production_fact_claim_count") != 0:
                errors.append("repository inventory invents a production fact")

    result = {
        "schema_version": "1.0",
        "gate_id": "P12D-EXECUTION-CONTRACT",
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
