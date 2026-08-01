"""Validate the versioned 34-control Harness Catalog with safe YAML loading."""

from __future__ import annotations

import argparse
import json
import os
import xml.etree.ElementTree as ET
from pathlib import Path
from typing import Any

import yaml


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


def load_catalog(path: Path) -> dict[str, Any]:
    raw = path.read_text(encoding="utf-8")
    if "\t" in raw:
        raise ValueError("tab characters are forbidden in Harness Catalog YAML")
    value = yaml.load(raw, Loader=UniqueKeySafeLoader)
    if not isinstance(value, dict):
        raise ValueError("Harness Catalog root must be a mapping")
    return value


def validate_catalog(catalog: dict[str, Any]) -> dict[str, Any]:
    controls = catalog.get("controls")
    if not isinstance(controls, list):
        raise ValueError("controls must be a list")
    ids = [control.get("id") for control in controls if isinstance(control, dict)]
    paths = [control.get("test_file") for control in controls if isinstance(control, dict)]
    statuses = [control.get("status") for control in controls if isinstance(control, dict)]
    minimum_cases = [
        control.get("minimum_cases") for control in controls if isinstance(control, dict)
    ]
    errors: list[str] = []
    if catalog.get("schema_version") != "1.0":
        errors.append("schema_version")
    if catalog.get("status_model") != "contract_only->implemented|not_applicable":
        errors.append("status_model")
    if len(controls) != 34 or ids != list(range(1, 35)) or len(set(ids)) != 34:
        errors.append("control_ids")
    if len(paths) != 34 or len(set(paths)) != 34:
        errors.append("test_paths")
    if any(status not in {"contract_only", "implemented", "not_applicable"} for status in statuses):
        errors.append("statuses")
    if any(not isinstance(value, int) or value < 1 for value in minimum_cases):
        errors.append("minimum_cases")
    total = sum(value for value in minimum_cases if isinstance(value, int))
    if catalog.get("minimum_cases_total") != 149 or total != 149:
        errors.append("minimum_cases_total")
    return {
        "catalog_entries": len(controls),
        "unique_control_ids": len(set(ids)),
        "unique_test_paths": len(set(paths)),
        "minimum_cases": total,
        "catalog_errors": len(errors),
        "error_fields": errors,
    }


def validate_results(collection: Path | None, junit_root: Path | None) -> dict[str, Any]:
    if collection is None or junit_root is None:
        raise ValueError("--collection and --junit-root are required in results mode")
    collection_data = json.loads(collection.read_text(encoding="utf-8"))
    junit_files = sorted(junit_root.rglob("*.xml"))
    tests = failures = errors = skipped = 0
    for path in junit_files:
        root = ET.parse(path).getroot()
        suites = [root] if root.tag == "testsuite" else list(root.iter("testsuite"))
        for suite in suites:
            tests += int(suite.attrib.get("tests", "0"))
            failures += int(suite.attrib.get("failures", "0"))
            errors += int(suite.attrib.get("errors", "0"))
            skipped += int(suite.attrib.get("skipped", "0"))
    return {
        "collection_type": type(collection_data).__name__,
        "junit_file_count": len(junit_files),
        "tests": tests,
        "failures": failures,
        "errors": errors,
        "skipped": skipped,
    }


def write_atomic(path: Path, value: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(f".{path.name}.{os.getpid()}.tmp")
    temporary.write_text(json.dumps(value, separators=(",", ":")), encoding="utf-8")
    temporary.replace(path)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--mode", choices=("collect", "results"), required=True)
    parser.add_argument("--catalog", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--collection", type=Path)
    parser.add_argument("--junit-root", type=Path)
    args = parser.parse_args()
    try:
        report: dict[str, Any] = {
            "schema_version": "1.0",
            "mode": args.mode,
            **validate_catalog(load_catalog(args.catalog)),
        }
        if args.mode == "results":
            report.update(validate_results(args.collection, args.junit_root))
        report["status"] = (
            "passed"
            if report["catalog_errors"] == 0
            and (args.mode == "collect" or report["failures"] + report["errors"] == 0)
            else "failed"
        )
        report["reason_code"] = "" if report["status"] == "passed" else "harness_validation_failed"
        write_atomic(args.output, report)
        return 0 if report["status"] == "passed" else 3
    except Exception as exc:
        write_atomic(
            args.output,
            {
                "schema_version": "1.0",
                "mode": args.mode,
                "status": "failed",
                "reason_code": "harness_validation_error",
                "error_type": type(exc).__name__,
            },
        )
        return 3


if __name__ == "__main__":
    raise SystemExit(main())
