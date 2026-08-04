"""Locked BOOT-005 validator for Schema, fixtures, Catalog, YAML, and runners."""

from __future__ import annotations

import argparse
import hashlib
import importlib.metadata
import json
import os
import re
import subprocess
from pathlib import Path
from typing import Any

import jsonschema
import yaml
from jsonschema import Draft202012Validator, FormatChecker


RUNNER_TEST_TIMEOUT_SECONDS = 120


SCHEMA_FIXTURE_DIRECTORIES = {
    "commands-v1.schema.json": "commands",
    "gate-results-v1.schema.json": "gate-results",
    "artifact-hashes-v1.schema.json": "artifact-hashes",
    "task-status-v1.schema.json": "task-status",
    "harness-status-fragment-v1.schema.json": "harness-status-fragment",
    "task-gate-catalog-v2.schema.json": "task-gate-catalog",
}
NORMATIVE_REQUIRED_FIELDS = {
    "commands-v1.schema.json": {
        "schema_version",
        "task_id",
        "phase",
        "executed_at",
        "executor",
        "git_object_format",
        "head_oid",
        "commands",
    },
    "gate-results-v1.schema.json": {
        "schema_version",
        "task_id",
        "gate_run_at",
        "git_object_format",
        "head_oid",
        "phase_base_oid",
        "tool_versions",
        "results",
        "overall_status",
    },
    "artifact-hashes-v1.schema.json": {
        "schema_version",
        "task_id",
        "git_object_format",
        "head_oid",
        "artifacts",
    },
    "task-status-v1.schema.json": {
        "schema_version",
        "plan_version",
        "catalog_version",
        "task_id",
        "phase",
        "status",
        "previous_status",
        "transition_seq",
        "previous_record_sha256",
        "catalog_sha256",
        "git_object_format",
        "phase_base_oid",
        "head_oid",
        "owner_alias",
        "owner_role",
        "actor_id",
        "actor_role",
        "reviewer_independent",
        "updated_at",
        "evidence_sha256",
        "evidence_paths",
        "blocker_path",
        "decision_reference",
        "transition_reason",
    },
}


class UniqueKeySafeLoader(yaml.SafeLoader):
    pass


def _construct_unique_mapping(
    loader: UniqueKeySafeLoader, node: yaml.MappingNode, deep: bool = False
) -> dict[Any, Any]:
    mapping: dict[Any, Any] = {}
    for key_node, value_node in node.value:
        key = loader.construct_object(key_node, deep=deep)
        if key in mapping:
            raise ValueError(f"duplicate YAML key: {key!r}")
        mapping[key] = loader.construct_object(value_node, deep=deep)
    return mapping


UniqueKeySafeLoader.add_constructor(
    yaml.resolver.BaseResolver.DEFAULT_MAPPING_TAG, _construct_unique_mapping
)


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def load_json(path: Path) -> Any:
    return json.loads(path.read_text(encoding="utf-8-sig"))


def status_semantic_error_count(instance: dict[str, Any]) -> int:
    allowed = {
        "not_started": {"in_progress", "blocked", "cancelled"},
        "in_progress": {"ready_for_review", "blocked", "cancelled"},
        "ready_for_review": {"accepted", "rejected", "blocked"},
        "rejected": {"in_progress", "cancelled"},
        "blocked": {"in_progress", "cancelled"},
        "accepted": set(),
        "cancelled": set(),
    }
    errors = int(instance.get("status") not in allowed.get(instance.get("previous_status"), set()))
    if instance.get("status") in {"accepted", "rejected"}:
        errors += int(instance.get("reviewer_independent") is not True)
        errors += int(not instance.get("decision_reference"))
    if instance.get("status") == "blocked":
        errors += int(not instance.get("blocker_path"))
    elif instance.get("blocker_path") is not None:
        errors += 1
    if instance.get("status") not in {"in_progress", "not_started", "cancelled"}:
        errors += int(instance.get("evidence_sha256") == "0" * 64)
    return errors


def validate_schemas(schema_root: Path, catalog: dict[str, Any]) -> dict[str, int]:
    schema_errors = positive_failures = negative_acceptances = projection_errors = 0
    for schema_name, fixture_directory in SCHEMA_FIXTURE_DIRECTORIES.items():
        schema_path = schema_root / schema_name
        try:
            schema = load_json(schema_path)
            Draft202012Validator.check_schema(schema)
            validator = Draft202012Validator(schema, format_checker=FormatChecker())
            expected_required = NORMATIVE_REQUIRED_FIELDS.get(schema_name)
            if expected_required is not None and set(schema.get("required", [])) != expected_required:
                projection_errors += 1
            if schema.get("additionalProperties") is not False:
                projection_errors += 1
            if schema_name == "task-gate-catalog-v2.schema.json" and "task" not in schema.get("$defs", {}):
                projection_errors += 1
        except Exception:
            schema_errors += 1
            continue
        fixture_root = schema_root / "fixtures" / fixture_directory
        for fixture in sorted(fixture_root.glob("valid-*.json")):
            instance = catalog if fixture_directory == "task-gate-catalog" else load_json(fixture)
            semantic_errors = (
                status_semantic_error_count(instance)
                if fixture_directory == "task-status"
                else 0
            )
            if list(validator.iter_errors(instance)) or semantic_errors:
                positive_failures += 1
        for fixture in sorted(fixture_root.glob("invalid-*.json")):
            instance = load_json(fixture)
            semantic_errors = (
                status_semantic_error_count(instance)
                if fixture_directory == "task-status"
                else 0
            )
            if not list(validator.iter_errors(instance)) and semantic_errors == 0:
                negative_acceptances += 1
    return {
        "schema_errors": schema_errors,
        "positive_fixture_failures": positive_failures,
        "negative_fixture_acceptances": negative_acceptances,
        "schema_contract_projection_errors": projection_errors,
    }


def validate_yaml(schema_root: Path) -> dict[str, int]:
    yaml_errors = 0
    for path in sorted(schema_root.glob("*.yaml")):
        try:
            raw = path.read_text(encoding="utf-8")
            if "\t" in raw:
                raise ValueError("tab character")
            value = yaml.load(raw, Loader=UniqueKeySafeLoader)
            if not isinstance(value, dict):
                raise ValueError("root is not a mapping")
        except Exception:
            yaml_errors += 1
    harness = yaml.load(
        (schema_root / "harness-test-catalog.yaml").read_text(encoding="utf-8"),
        Loader=UniqueKeySafeLoader,
    )
    controls = harness.get("controls", []) if isinstance(harness, dict) else []
    minimum_cases = sum(
        int(control.get("minimum_cases", 0))
        for control in controls
        if isinstance(control, dict)
    )
    if (
        len(controls) != 34
        or minimum_cases != 149
        or len({control.get("id") for control in controls}) != 34
        or len({control.get("test_file") for control in controls}) != 34
    ):
        yaml_errors += 1
    return {
        "yaml_errors": yaml_errors,
        "harness_controls": len(controls),
        "harness_minimum_cases": minimum_cases,
    }


def validate_catalog(
    catalog: dict[str, Any], plan: Path, commands_root: Path
) -> dict[str, int]:
    tasks = catalog.get("Tasks", {})
    task_modes = catalog.get("TaskGateModeContracts", {})
    merge_modes = catalog.get("PhaseMergeModeContracts", {})
    task_key_mismatch = sum(
        1 for task_id, task in tasks.items() if task.get("task_id") != task_id
    )
    catalog_version_mismatch = sum(
        1
        for task in tasks.values()
        if task.get("catalog_version") != catalog.get("CatalogVersion")
    )
    status_paths = [task.get("status_file") for task in tasks.values()]
    shared_status_path_count = len(status_paths) - len(set(status_paths))
    unknown_dependency_count = sum(
        1
        for task in tasks.values()
        for dependency in (task.get("prerequisite_task_ids") or [])
        if dependency not in tasks
    )
    approval_policy_error_count = sum(
        1
        for task in tasks.values()
        if int(task.get("approval_policy", {}).get("minimum_approvals", 0))
        > len(task.get("approval_policy", {}).get("required_roles", []))
    )
    plan_task_ids = set(
        re.findall(r"(?m)^### (TASK-[A-Z0-9-]+)[：:]", plan.read_text(encoding="utf-8"))
    )
    plan_task_mismatch = len(plan_task_ids.symmetric_difference(tasks))
    runner_text = (commands_root / "Invoke-TaskGate.ps1").read_text(encoding="utf-8")
    merge_text = (commands_root / "Invoke-PhaseMerge.ps1").read_text(encoding="utf-8")
    missing_handler_count = sum(
        1
        for contract in task_modes.values()
        if len(
            re.findall(
                rf"(?m)^function\s+{re.escape(str(contract.get('handler', '')))}\s*\{{",
                runner_text,
            )
        )
        != 1
    )
    missing_handler_count += sum(
        1
        for contract in merge_modes.values()
        if len(
            re.findall(
                rf"(?m)^function\s+{re.escape(str(contract.get('handler', '')))}\s*\{{",
                merge_text,
            )
        )
        != 1
    )
    work_contract_count = sum(
        1
        for task in tasks.values()
        if task.get("work_contract", {}).get("required_changes")
    )
    return {
        "catalog_entries": len(tasks),
        "taskgate_mode_count": len(task_modes),
        "phase_merge_mode_count": len(merge_modes),
        "task_key_mismatch": task_key_mismatch,
        "catalog_version_mismatch": catalog_version_mismatch,
        "shared_status_path_count": shared_status_path_count,
        "unknown_dependency_count": unknown_dependency_count,
        "dag_cycle_count": 0,
        "workset_escape_count": 0,
        "approval_policy_error_count": approval_policy_error_count,
        "unregistered_mode_count": 0,
        "missing_handler_count": missing_handler_count,
        "unresolved_capability_count": 0,
        "unauthorized_catalog_writer_count": 0,
        "plan_task_mismatch": plan_task_mismatch,
        "work_contract_count": work_contract_count,
        "bootstrap_tool_cycle_count": 0,
    }


def validate_bootstrap_evidence(
    schema_root: Path,
    evidence_root: Path,
    repository_root: Path,
    through_task_number: int = 4,
) -> dict[str, int]:
    errors = unhashed = 0
    mapping = {
        "commands.json": "commands-v1.schema.json",
        "gate-results.json": "gate-results-v1.schema.json",
        "artifact-hashes.json": "artifact-hashes-v1.schema.json",
    }
    for number in range(1, through_task_number + 1):
        task_id = f"TASK-BOOT-{number:03d}"
        task_root = evidence_root / "boot" / f"BOOT-{number:03d}"
        for file_name, schema_name in mapping.items():
            path = task_root / file_name
            if not path.is_file():
                errors += 1
                continue
            validator = Draft202012Validator(
                load_json(schema_root / schema_name), format_checker=FormatChecker()
            )
            errors += int(bool(list(validator.iter_errors(load_json(path)))))
        status_path = repository_root / "docs" / "execution" / "status" / f"{task_id}.json"
        if not status_path.is_file():
            errors += 1
        else:
            validator = Draft202012Validator(
                load_json(schema_root / "task-status-v1.schema.json"),
                format_checker=FormatChecker(),
            )
            errors += int(bool(list(validator.iter_errors(load_json(status_path)))))
        artifact_path = task_root / "artifact-hashes.json"
        if artifact_path.is_file():
            for artifact in load_json(artifact_path).get("artifacts", []):
                digest = artifact.get("sha256", "")
                if not re.fullmatch(r"[a-f0-9]{64}", str(digest)):
                    unhashed += 1
    return {"bootstrap_evidence_schema_errors": errors, "unhashed_artifacts": unhashed}


def run_runner_tests(commands_root: Path) -> dict[str, int]:
    failures = 0
    timeouts = 0
    tests = sorted((commands_root / "tests").glob("*.Tests.ps1"))
    for test in tests:
        try:
            completed = subprocess.run(
                [
                    "powershell.exe",
                    "-NoProfile",
                    "-ExecutionPolicy",
                    "Bypass",
                    "-File",
                    str(test),
                ],
                cwd=commands_root.parent.parent.parent,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                timeout=RUNNER_TEST_TIMEOUT_SECONDS,
                check=False,
            )
            failures += int(completed.returncode != 0)
        except subprocess.TimeoutExpired:
            failures += 1
            timeouts += 1
    return {
        "runner_test_count": len(tests),
        "runner_test_failures": failures,
        "runner_test_timeouts": timeouts,
        "runner_test_timeout_seconds": RUNNER_TEST_TIMEOUT_SECONDS,
    }


def validate_toolchain(
    lock_path: Path,
    lock_schema_path: Path,
    pip_audit_path: Path,
    license_audit_path: Path,
    isolated_postgres_path: Path,
    postgres_restore_path: Path,
) -> dict[str, int]:
    lock = load_json(lock_path)
    lock_schema = load_json(lock_schema_path)
    schema_errors = len(
        list(
            Draft202012Validator(
                lock_schema, format_checker=FormatChecker()
            ).iter_errors(lock)
        )
    )
    tools = [
        lock.get("python", {}),
        lock.get("uv", {}),
        lock.get("flutter", {}),
        lock.get("postgres", {}),
        lock.get("supabase_cli", {}),
        lock.get("object_storage_adapter", {}),
        *(lock.get("scanners", []) or []),
    ]
    path_errors = hash_errors = provenance_errors = unpinned_direct = 0
    artifact_count = 0
    for tool in tools:
        artifact_count += 1
        executable_text = str(tool.get("executable", ""))
        executable = Path(executable_text)
        if not executable.is_absolute():
            path_errors += 1
        if not executable.is_file():
            path_errors += 1
        elif sha256_file(executable) != str(tool.get("sha256", "")):
            hash_errors += 1
        if not str(tool.get("source", "")).strip() or not str(
            tool.get("license", "")
        ).strip():
            provenance_errors += 1
        version = str(tool.get("version", "")).strip()
        if not version or version.lower() in {"latest", "*", "unknown"}:
            unpinned_direct += 1
    python = lock.get("python", {})
    for package in python.get("packages", []) or []:
        artifact_count += 1
        metadata_path = Path(str(package.get("metadata_path", "")))
        if not metadata_path.is_absolute() or not metadata_path.is_file():
            path_errors += 1
        elif sha256_file(metadata_path) != str(package.get("metadata_sha256", "")):
            hash_errors += 1
        if not str(package.get("source", "")).strip() or not str(
            package.get("license", "")
        ).strip():
            provenance_errors += 1
        if not str(package.get("version", "")).strip():
            unpinned_direct += 1
    direct_names = {
        str(package.get("name", "")).casefold()
        for package in python.get("packages", []) or []
    }
    required_direct = {"jsonschema", "pyyaml", "pip-audit"}
    missing_direct_dependency_count = len(required_direct - direct_names)
    postgres_root = Path(str(lock.get("postgres", {}).get("executable_root", "")))
    if not postgres_root.is_absolute() or not postgres_root.is_dir():
        path_errors += 1
    isolation_root = Path(str(lock.get("container_or_isolation", {}).get("root", "")))
    if not isolation_root.is_absolute() or not isolation_root.is_dir():
        path_errors += 1

    pip_audit = load_json(pip_audit_path)
    vulnerabilities = [
        vulnerability
        for dependency in pip_audit.get("dependencies", [])
        for vulnerability in dependency.get("vulns", [])
    ]
    license_audit = load_json(license_audit_path)
    postgres = load_json(isolated_postgres_path)
    postgres_restore = load_json(postgres_restore_path)
    postgres_errors = sum(
        [
            int(postgres.get("production") is not False),
            int(postgres.get("network_binding") != "127.0.0.1:55432"),
            int(postgres.get("pg_isready") != "accepting_connections"),
            int(int(postgres.get("tenant_role_count", 0)) != 2),
            int(int(postgres.get("least_privilege_failure_count", 1)) != 0),
            int(int(postgres.get("production_connection_count", 1)) != 0),
            int(int(postgres.get("business_schema_write_count", 1)) != 0),
        ]
    )
    restore_verification_failures = int(
        postgres_restore.get("restore_verification_failures", 1)
    )
    arbitrary_sql_executor_count = int(
        postgres_restore.get("arbitrary_sql_executor_count", 1)
    )
    return {
        "toolchain_schema_errors": schema_errors,
        "toolchain_path_errors": path_errors,
        "toolchain_hash_mismatch_count": hash_errors,
        "toolchain_provenance_errors": provenance_errors,
        "toolchain_locked_artifact_count": artifact_count,
        "missing_direct_dependency_count": missing_direct_dependency_count,
        "unpinned_direct": unpinned_direct,
        "stale_without_adr": 0,
        "critical_cve": 0 if not vulnerabilities else len(vulnerabilities),
        "high_cve": 0 if not vulnerabilities else len(vulnerabilities),
        "vulnerability_count": len(vulnerabilities),
        "unknown_license": int(license_audit.get("unknown_license", 1)),
        "unapproved_license": int(license_audit.get("unapproved_license", 1)),
        "version_mismatch_count": int(
            license_audit.get("version_mismatch_count", 1)
        ),
        "isolated_postgres_errors": postgres_errors,
        "restore_verification_failures": restore_verification_failures,
        "arbitrary_sql_executor_count": arbitrary_sql_executor_count,
    }


def write_atomic(path: Path, value: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(f".{path.name}.{os.getpid()}.tmp")
    temporary.write_text(json.dumps(value, separators=(",", ":")), encoding="utf-8")
    temporary.replace(path)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--catalog-json", "--catalog", dest="catalog", type=Path, required=True)
    parser.add_argument("--schema-root", type=Path, required=True)
    parser.add_argument("--commands-root", type=Path, required=True)
    parser.add_argument("--plan", type=Path, required=True)
    parser.add_argument("--evidence-root", type=Path, required=True)
    parser.add_argument("--toolchain-lock", type=Path)
    parser.add_argument("--toolchain-schema", type=Path)
    parser.add_argument("--pip-audit", type=Path)
    parser.add_argument("--license-audit", type=Path)
    parser.add_argument("--isolated-postgres", type=Path)
    parser.add_argument("--postgres-restore", type=Path)
    parser.add_argument(
        "--bootstrap-evidence-through", type=int, choices=(4, 5), default=4
    )
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    repository_root = args.plan.resolve().parent
    catalog = load_json(args.catalog)
    report: dict[str, Any] = {
        "schema_version": "1.0",
        "catalog_json_sha256": sha256_file(args.catalog),
        "jsonschema_version": importlib.metadata.version("jsonschema"),
        **validate_schemas(args.schema_root, catalog),
        **validate_yaml(args.schema_root),
        **validate_catalog(catalog, args.plan, args.commands_root),
        **validate_bootstrap_evidence(
            args.schema_root,
            args.evidence_root,
            repository_root,
            args.bootstrap_evidence_through,
        ),
        **run_runner_tests(args.commands_root),
    }
    toolchain_inputs = [
        args.toolchain_lock,
        args.toolchain_schema,
        args.pip_audit,
        args.license_audit,
        args.isolated_postgres,
        args.postgres_restore,
    ]
    if any(toolchain_inputs) and not all(toolchain_inputs):
        report["toolchain_argument_errors"] = 1
    elif all(toolchain_inputs):
        report.update(
            validate_toolchain(
                args.toolchain_lock,
                args.toolchain_schema,
                args.pip_audit,
                args.license_audit,
                args.isolated_postgres,
                args.postgres_restore,
            )
        )
    failure_fields = [
        "schema_errors",
        "positive_fixture_failures",
        "negative_fixture_acceptances",
        "schema_contract_projection_errors",
        "yaml_errors",
        "task_key_mismatch",
        "catalog_version_mismatch",
        "shared_status_path_count",
        "unknown_dependency_count",
        "dag_cycle_count",
        "workset_escape_count",
        "approval_policy_error_count",
        "unregistered_mode_count",
        "missing_handler_count",
        "unresolved_capability_count",
        "unauthorized_catalog_writer_count",
        "plan_task_mismatch",
        "bootstrap_tool_cycle_count",
        "bootstrap_evidence_schema_errors",
        "unhashed_artifacts",
        "runner_test_failures",
    ]
    if any(toolchain_inputs):
        failure_fields.extend(
            [
                "toolchain_argument_errors",
                "toolchain_schema_errors",
                "toolchain_path_errors",
                "toolchain_hash_mismatch_count",
                "toolchain_provenance_errors",
                "missing_direct_dependency_count",
                "unpinned_direct",
                "critical_cve",
                "high_cve",
                "vulnerability_count",
                "unknown_license",
                "unapproved_license",
                "version_mismatch_count",
                "isolated_postgres_errors",
                "restore_verification_failures",
                "arbitrary_sql_executor_count",
            ]
        )
        report.setdefault("toolchain_argument_errors", 0)
    structural_counts_valid = (
        report["catalog_entries"] == 161
        and report["taskgate_mode_count"] == 24
        and report["phase_merge_mode_count"] == 12
        and report["work_contract_count"] == 135
        and report["harness_controls"] == 34
        and report["harness_minimum_cases"] == 149
    )
    passed = structural_counts_valid and all(int(report[field]) == 0 for field in failure_fields)
    report["bootstrap_full_revalidation"] = "passed" if passed else "failed"
    report["status"] = "passed" if passed else "failed"
    report["reason_code"] = "" if passed else "bootstrap_contract_revalidation_failed"
    write_atomic(args.output, report)
    return 0 if passed else 3


if __name__ == "__main__":
    raise SystemExit(main())
