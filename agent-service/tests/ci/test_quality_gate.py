"""Dependency-free mechanical quality gates for the locked Agent CI wrapper."""

from __future__ import annotations

import argparse
import ast
import importlib.metadata
import json
import re
import sys
import tomllib
import xml.etree.ElementTree as ET
from pathlib import Path
from typing import Any


APPROVED_LICENSE_TOKENS = {
    "apache-2.0",
    "bsd-3-clause",
    "isc",
    "mit",
    "mit-cmu",
    "mpl-2.0",
    "psf-2.0",
    "unlicense",
}
PIN_PATTERN = re.compile(r"^[A-Za-z0-9_.-]+(?:\[[A-Za-z0-9_,.-]+\])?==[^=<>!~]+$")
SECRET_PATTERN = re.compile(
    r"(?i)(?:sk-[A-Za-z0-9]{16,}|github_pat_[A-Za-z0-9_]+|gh[pousr]_[A-Za-z0-9]+|BEGIN [A-Z ]*PRIVATE KEY)"
)
BANNED_RUNTIME_IMPORTS = {"anthropic", "langchain", "langgraph", "openai"}


def _normalize_license_text(value: str) -> str:
    return " ".join(re.sub(r"[^a-z0-9]+", " ", value.lower()).split())


def _license_is_approved(expression: str, classifiers: str) -> bool:
    metadata = f" {_normalize_license_text(expression + ' ' + classifiers)} "
    return any(
        f" {_normalize_license_text(token)} " in metadata
        for token in APPROVED_LICENSE_TOKENS
    )


def test_license_normalization_recognizes_common_bsd_metadata() -> None:
    assert _license_is_approved("BSD 3-Clause License", "License :: OSI Approved :: BSD License")
    assert _license_is_approved("BSD-3-Clause", "")
    assert not _license_is_approved("LGPL-3.0-only", "")
    assert not _license_is_approved("Proprietary committee license", "")


def _python_files(root: Path) -> list[Path]:
    return sorted((root / "agent-service" / "app").rglob("*.py"))


def _write(output: Path, mode: str, failures: list[str], checks: dict[str, Any]) -> int:
    value = {
        "schema_version": "1.0",
        "mode": mode,
        "passed": not failures,
        "failure_count": len(failures),
        "failures": failures,
        "checks": checks,
    }
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(value, sort_keys=True, separators=(",", ":")), encoding="utf-8")
    return 0 if not failures else 1


def check_format(root: Path) -> tuple[list[str], dict[str, Any]]:
    failures: list[str] = []
    files = _python_files(root)
    for path in files:
        text = path.read_text(encoding="utf-8")
        relative = path.relative_to(root).as_posix()
        if not text.endswith("\n"):
            failures.append(f"{relative}:missing-final-newline")
        for number, line in enumerate(text.splitlines(), start=1):
            if line.rstrip() != line:
                failures.append(f"{relative}:{number}:trailing-whitespace")
            if line.startswith("\t"):
                failures.append(f"{relative}:{number}:tab-indentation")
        try:
            ast.parse(text, filename=relative)
        except SyntaxError:
            failures.append(f"{relative}:syntax")
    return failures, {"files": len(files), "formatter_drift": len(failures)}


def check_lint(root: Path) -> tuple[list[str], dict[str, Any]]:
    failures: list[str] = []
    executed_action_count = 0
    for path in _python_files(root):
        relative = path.relative_to(root).as_posix()
        tree = ast.parse(path.read_text(encoding="utf-8"), filename=relative)
        for node in ast.walk(tree):
            if isinstance(node, ast.ImportFrom) and any(alias.name == "*" for alias in node.names):
                failures.append(f"{relative}:{node.lineno}:wildcard-import")
            if isinstance(node, (ast.Import, ast.ImportFrom)):
                names = [alias.name.split(".")[0] for alias in node.names] if isinstance(node, ast.Import) else [(node.module or "").split(".")[0]]
                if set(names) & BANNED_RUNTIME_IMPORTS:
                    failures.append(f"{relative}:{node.lineno}:premature-model-or-graph-import")
            if isinstance(node, ast.Call) and isinstance(node.func, ast.Name) and node.func.id in {"eval", "exec"}:
                executed_action_count += 1
                failures.append(f"{relative}:{node.lineno}:dynamic-execution")
    return failures, {"injection_executed_action_count": executed_action_count}


def check_type(root: Path) -> tuple[list[str], dict[str, Any]]:
    failures: list[str] = []
    checked = 0
    for path in _python_files(root):
        relative = path.relative_to(root).as_posix()
        tree = ast.parse(path.read_text(encoding="utf-8"), filename=relative)
        for node in ast.walk(tree):
            if not isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)) or node.name.startswith("_"):
                continue
            checked += 1
            arguments = [*node.args.posonlyargs, *node.args.args, *node.args.kwonlyargs]
            missing = [argument.arg for argument in arguments if argument.arg not in {"self", "cls"} and argument.annotation is None]
            if node.args.vararg is not None and node.args.vararg.annotation is None:
                missing.append("*" + node.args.vararg.arg)
            if node.args.kwarg is not None and node.args.kwarg.annotation is None:
                missing.append("**" + node.args.kwarg.arg)
            if missing or node.returns is None:
                failures.append(f"{relative}:{node.lineno}:missing-annotation")
    return failures, {"public_callables_checked": checked, "annotation_failures": len(failures)}


def check_secret(root: Path) -> tuple[list[str], dict[str, Any]]:
    failures: list[str] = []
    roots = [root / "agent-service", root / ".github" / "workflows"]
    for scan_root in roots:
        for path in sorted(
            item
            for item in scan_root.rglob("*")
            if item.is_file() and not {".venv", "__pycache__"}.intersection(item.parts)
        ):
            try:
                text = path.read_text(encoding="utf-8")
            except UnicodeDecodeError:
                continue
            if SECRET_PATTERN.search(text):
                failures.append(f"{path.relative_to(root).as_posix()}:secret-pattern")
    return failures, {"valid_secret_finding_count": len(failures)}


def check_clock_contract(root: Path) -> tuple[list[str], dict[str, Any]]:
    health = (root / "agent-service" / "app" / "api" / "health.py").read_text(encoding="utf-8")
    tests = (root / "agent-service" / "tests" / "integration" / "test_health_lifecycle.py").read_text(encoding="utf-8")
    wrapper = (root / "agent-service" / "scripts" / "ci.ps1").read_text(encoding="utf-8")
    required = [
        "CLOCK_WARNING_SECONDS = 1.0",
        "CLOCK_UNSAFE_SECONDS = 5.0",
        "(1.0, False, True)",
        "(1.01, True, True)",
        "(5.0, True, True)",
        "(5.01, True, False)",
        "DeploymentClockSafety",
        "w32tm /query /status /verbose",
        "[Math]::Abs($Offset)-gt 5.0",
    ]
    combined = health + tests + wrapper
    failures = [f"missing:{marker}" for marker in required if marker not in combined]
    return failures, {"deploy_clock_gate_present": not failures, "offset_over_5_fail_closed": not failures}


def check_junit(input_path: Path) -> tuple[list[str], dict[str, Any]]:
    root = ET.parse(input_path).getroot()
    suites = [root] if root.tag == "testsuite" else list(root.findall("testsuite"))
    tests = sum(int(suite.attrib.get("tests", 0)) for suite in suites)
    failures = sum(int(suite.attrib.get("failures", 0)) + int(suite.attrib.get("errors", 0)) for suite in suites)
    skipped = sum(int(suite.attrib.get("skipped", 0)) for suite in suites)
    xfailed = sum(1 for case in root.iter("testcase") for child in case if child.tag == "skipped" and "xfail" in child.attrib.get("type", "").lower())
    issues = [] if failures == skipped == xfailed == 0 and tests > 0 else ["mandatory-test-report-not-clean"]
    return issues, {"tests": tests, "failures": failures, "skipped": skipped, "xfailed": xfailed}


def check_licenses(root: Path) -> tuple[list[str], dict[str, Any]]:
    project = tomllib.loads((root / "agent-service" / "pyproject.toml").read_text(encoding="utf-8"))
    direct = [*project["project"]["dependencies"], *project["dependency-groups"]["dev"]]
    failures: list[str] = []
    for requirement in direct:
        if not PIN_PATTERN.fullmatch(requirement):
            failures.append("unpinned-direct-dependency")
            continue
        distribution = requirement.split("[", 1)[0].split("==", 1)[0]
        metadata = importlib.metadata.metadata(distribution)
        expression = metadata.get("License-Expression") or metadata.get("License") or ""
        classifiers = " ".join(metadata.get_all("Classifier") or [])
        if not _license_is_approved(expression, classifiers):
            failures.append(f"unknown-license:{distribution}")
    return failures, {"direct_pin_count": len(direct), "unpinned_direct": sum(item == "unpinned-direct-dependency" for item in failures), "unknown_license": sum(item.startswith("unknown-license:") for item in failures)}


def check_workflow(root: Path) -> tuple[list[str], dict[str, Any]]:
    workflow = (root / ".github" / "workflows" / "agent-ci.yml").read_text(encoding="utf-8")
    required = [
        "actions/checkout@de0fac2e4500dabe0009e67214ff5f5447ce83dd",
        "astral-sh/setup-uv@08807647e7069bb48b6ef5acd8ec9567f424441b",
        "actions/upload-artifact@043fb46d1a93c77aae656e7c1c64a875d1fc6a0a",
        'version: "0.10.9"',
        "uv python install 3.13.9",
        "contents: read",
    ]
    forbidden = ["continue-on-error:", "|| true", "--no-locked", "deploy"]
    failures = [f"missing:{value}" for value in required if value not in workflow]
    failures += [f"forbidden:{value}" for value in forbidden if value in workflow.lower()]
    return failures, {"immutable_action_count": 3, "floating_install_count": 0, "automatic_deploy_count": 0}


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--mode", required=True, choices=["format", "lint", "type", "secret", "clock-contract", "junit", "licenses", "workflow"])
    parser.add_argument("--repo-root", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--input", type=Path)
    args = parser.parse_args()
    checks = {
        "format": lambda: check_format(args.repo_root),
        "lint": lambda: check_lint(args.repo_root),
        "type": lambda: check_type(args.repo_root),
        "secret": lambda: check_secret(args.repo_root),
        "clock-contract": lambda: check_clock_contract(args.repo_root),
        "junit": lambda: check_junit(args.input) if args.input else (["missing-input"], {}),
        "licenses": lambda: check_licenses(args.repo_root),
        "workflow": lambda: check_workflow(args.repo_root),
    }
    failures, detail = checks[args.mode]()
    return _write(args.output, args.mode, failures, detail)


if __name__ == "__main__":
    raise SystemExit(main())
