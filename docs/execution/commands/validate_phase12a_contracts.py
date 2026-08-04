#!/usr/bin/env python3
"""Validate the selected local-provisional P12A contract and focused evidence."""

from __future__ import annotations

import argparse
import json
import subprocess
import tempfile
from pathlib import Path


TASK_IDS = [f"TASK-P12A-{token}" for token in ("010", "020", "030", "040", "050", "060", "990", "999")]


def load_json(path: Path) -> dict:
    return json.loads(path.read_text(encoding="utf-8-sig"))


def export_catalog(root: Path) -> dict:
    with tempfile.TemporaryDirectory(prefix="p12a-catalog-") as folder:
        output = Path(folder) / "catalog.json"
        catalog_path = root / "docs/execution/commands/TaskGateCatalog.psd1"
        script = (
            "$raw=[IO.File]::ReadAllText('" + str(catalog_path).replace("'", "''") +
            "',[Text.UTF8Encoding]::new($false));"
            "$catalog=[scriptblock]::Create($raw).InvokeReturnAsIs();"
            "$json=$catalog|ConvertTo-Json -Depth 100 -Compress;"
            "[IO.File]::WriteAllText('" + str(output).replace("'", "''") +
            "',$json,[Text.UTF8Encoding]::new($false))"
        )
        command = [r"C:\Program Files\WindowsApps\Microsoft.PowerShell_7.6.4.0_x64__8wekyb3d8bbwe\pwsh.exe", "-NoProfile", "-Command", script]
        result = subprocess.run(command, cwd=root, capture_output=True, text=True, encoding="utf-8", errors="replace", check=False)
        if result.returncode:
            raise RuntimeError(f"catalog export failed: {result.stderr.strip()}")
        return load_json(output)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", default=".")
    parser.add_argument("--task-id", default="TASK-P12A-000")
    args = parser.parse_args()
    root = Path(args.root).resolve()
    errors: list[str] = []
    contract = load_json(root / "docs/execution/evidence/phase-12a/P12A-000/proposed-execution-contract.json")
    selection = load_json(root / "docs/execution/evidence/phase-12a/P12A-000/selection-record.json")
    runtime = load_json(root / "docs/execution/evidence/phase-12a/phase-runtime-manifest.json")
    catalog = export_catalog(root)
    tasks = catalog.get("Tasks", {})

    if catalog.get("CatalogVersion") != "2.5.0" or len(tasks) != 177:
        errors.append("Catalog version/count mismatch")
    if contract.get("activation_state") != "selected_local_provisional":
        errors.append("P12A is not selected local provisional")
    if contract.get("single_agent_architecture") is not True or contract.get("multi_agent_framework_allowed") is not False:
        errors.append("Single-Agent boundary is not frozen")
    if selection.get("selected_candidate") != "P12A" or selection.get("selected_count") != 1:
        errors.append("XOR selection is invalid")
    if runtime.get("entry_full_regression_rerun") is not False or runtime.get("phase_base_oid") != selection.get("phase_base_oid"):
        errors.append("entry regression/base binding is invalid")
    scope = contract.get("memory_scope", {})
    if scope.get("types") != ["travel_pace", "mobility_requirement", "dietary_requirement", "transport_preference"]:
        errors.append("closed Memory types mismatch")
    if scope.get("purpose") != "itinerary.personalization" or scope.get("value_shape") != "closed_enum_only":
        errors.append("purpose/value shape mismatch")
    for task in contract.get("tasks", []):
        task_id = task.get("task_id")
        if task_id not in TASK_IDS:
            errors.append(f"unexpected task: {task_id}")
            continue
        if tasks.get(task_id, {}).get("file_allowlist") != task.get("file_allowlist"):
            errors.append(f"exact allowlist mismatch: {task_id}")
    if any(task_id not in tasks for task_id in TASK_IDS):
        errors.append("Catalog P12A task missing")
    if tasks.get("TASK-P12-089", {}).get("prerequisite_task_ids") != ["TASK-P12A-990"]:
        errors.append("P12-089 dependency mismatch")
    if tasks.get("TASK-P12A-999", {}).get("prerequisite_task_ids") != ["TASK-P12A-990", "TASK-P12-089"]:
        errors.append("P12A-999 dependency mismatch")
    if "Push" in tasks.get("TASK-P12A-999", {}).get("allowed_phase_merge_modes", []):
        errors.append("P12A-999 permits push")

    report = {"schema_version":"1.0","task_id":args.task_id,"passed":not errors,"error_count":len(errors),"errors":errors,"catalog_version":catalog.get("CatalogVersion"),"catalog_task_count":len(tasks),"single_agent_architecture":True,"production_write_count":0}
    print(json.dumps(report, sort_keys=True))
    return 0 if not errors else 1


if __name__ == "__main__":
    raise SystemExit(main())
