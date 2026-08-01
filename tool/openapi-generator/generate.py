#!/usr/bin/env python3
"""Generate the GoNow Dart Agent API client from the pinned OpenAPI surface."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
from typing import Any


REPOSITORY_ROOT = Path(__file__).resolve().parents[2]
TOOL_ROOT = Path(__file__).resolve().parent
LOCK_PATH = TOOL_ROOT / "generator-lock.json"
TEMPLATE_ROOT = TOOL_ROOT / "templates"


def _load_json(path: Path) -> dict[str, Any]:
    value = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(value, dict):
        raise ValueError(f"expected an object: {path}")
    return value


def _compatibility_errors(spec: dict[str, Any], baseline: dict[str, Any]) -> list[str]:
    errors: list[str] = []
    if spec.get("openapi") != baseline.get("openapi"):
        errors.append("openapi_version_changed")
    if spec.get("x-contract-name") != baseline.get("contract_name"):
        errors.append("contract_name_changed")
    if spec.get("info", {}).get("version") != baseline.get("contract_version"):
        errors.append("contract_version_changed")

    security_schemes = spec.get("components", {}).get("securitySchemes", {})
    for scheme in baseline.get("security_schemes", []):
        if scheme not in security_schemes:
            errors.append(f"security_scheme_removed:{scheme}")

    paths = spec.get("paths", {})
    for operation in baseline.get("operations", []):
        path = operation["path"]
        method = operation["method"]
        current = paths.get(path, {}).get(method)
        if not isinstance(current, dict):
            errors.append(f"operation_removed:{method}:{path}")
            continue
        if current.get("operationId") != operation["operation_id"]:
            errors.append(f"operation_id_changed:{method}:{path}")
        responses = current.get("responses", {})
        for status in operation["responses"]:
            if status not in responses:
                errors.append(f"response_removed:{method}:{path}:{status}")

    schemas = spec.get("components", {}).get("schemas", {})
    for name, contract in baseline.get("schemas", {}).items():
        current = schemas.get(name)
        if not isinstance(current, dict):
            errors.append(f"schema_removed:{name}")
            continue
        required = set(current.get("required", []))
        properties = current.get("properties", {})
        for field in contract.get("required", []):
            if field not in required:
                errors.append(f"required_field_removed:{name}:{field}")
        for field in contract.get("properties", []):
            if field not in properties:
                errors.append(f"property_removed:{name}:{field}")
    return errors


def _render_outputs(
    spec_sha256: str,
    generator_version: str,
    dart_executable: Path,
) -> dict[str, bytes]:
    replacements = {
        "@@SPEC_SHA256@@": spec_sha256,
        "@@GENERATOR_VERSION@@": generator_version,
    }
    outputs: dict[str, bytes] = {}
    for template_path in sorted(TEMPLATE_ROOT.glob("*.dart.in")):
        text = template_path.read_text(encoding="utf-8")
        for source, target in replacements.items():
            text = text.replace(source, target)
        if "@@" in text:
            raise ValueError(f"unresolved template token: {template_path.name}")
        output_name = template_path.name.removesuffix(".in")
        outputs[output_name] = text.replace("\r\n", "\n").encode("utf-8")
    if not outputs:
        raise ValueError("no generator templates found")
    with tempfile.TemporaryDirectory(prefix="gonow-openapi-dart-") as temporary_name:
        temporary_root = Path(temporary_name)
        for name, content in outputs.items():
            (temporary_root / name).write_bytes(content)
        format_run = subprocess.run(
            [str(dart_executable), "format", str(temporary_root)],
            check=False,
            capture_output=True,
            text=True,
            timeout=120,
        )
        if format_run.returncode != 0:
            raise RuntimeError(f"dart formatter failed with exit {format_run.returncode}")
        return {
            name: (temporary_root / name).read_bytes().replace(b"\r\n", b"\n")
            for name in outputs
        }


def _write_atomic(path: Path, content: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        with os.fdopen(descriptor, "wb") as temporary:
            temporary.write(content)
            temporary.flush()
            os.fsync(temporary.fileno())
        os.replace(temporary_name, path)
    finally:
        if os.path.exists(temporary_name):
            os.unlink(temporary_name)


def main() -> int:
    parser = argparse.ArgumentParser()
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--write", action="store_true")
    mode.add_argument("--check", action="store_true")
    parser.add_argument("--dart-executable", type=Path, required=True)
    arguments = parser.parse_args()

    if not arguments.dart_executable.is_file():
        print(json.dumps({"status": "failed", "reason": "dart_formatter_missing"}, sort_keys=True))
        return 5

    lock = _load_json(LOCK_PATH)
    spec_path = REPOSITORY_ROOT / lock["specification"]
    spec_bytes = spec_path.read_bytes()
    spec_sha256 = hashlib.sha256(spec_bytes).hexdigest()
    if spec_sha256 != lock["expected_spec_sha256"]:
        print(json.dumps({"status": "failed", "reason": "spec_digest_mismatch"}, sort_keys=True))
        return 2

    spec = json.loads(spec_bytes)
    baseline = _load_json(REPOSITORY_ROOT / lock["compatibility_baseline"])
    compatibility_errors = _compatibility_errors(spec, baseline)
    if compatibility_errors:
        print(
            json.dumps(
                {"status": "failed", "reason": "breaking_changes", "errors": compatibility_errors},
                sort_keys=True,
            )
        )
        return 3

    outputs = _render_outputs(
        spec_sha256,
        lock["generator_version"],
        arguments.dart_executable,
    )
    output_root = REPOSITORY_ROOT / lock["output_directory"]
    stale: list[str] = []
    for name, content in outputs.items():
        path = output_root / name
        if arguments.write:
            if not path.exists() or path.read_bytes() != content:
                _write_atomic(path, content)
        elif not path.exists() or path.read_bytes() != content:
            stale.append(name)

    expected_names = set(outputs)
    unexpected = sorted(
        path.name for path in output_root.glob("*.g.dart") if path.name not in expected_names
    ) if output_root.exists() else []
    if arguments.check and (stale or unexpected):
        print(
            json.dumps(
                {"status": "failed", "reason": "generated_diff", "stale": stale, "unexpected": unexpected},
                sort_keys=True,
            )
        )
        return 4

    print(
        json.dumps(
            {
                "status": "passed",
                "breaking_changes": 0,
                "generated_files": len(outputs),
                "generator_version": lock["generator_version"],
                "spec_sha256": spec_sha256,
            },
            sort_keys=True,
        )
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
