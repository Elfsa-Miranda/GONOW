#!/usr/bin/env python3
"""Execute personal compressed-certification shards and materialize evidence."""

from __future__ import annotations

import argparse
from datetime import UTC, datetime
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import time
from typing import Any
import xml.etree.ElementTree as ET


SCRIPT_ROOT = Path(__file__).resolve().parent
SERVICE_ROOT = SCRIPT_ROOT.parents[1]
REPOSITORY_ROOT = SERVICE_ROOT.parent
sys.path.insert(0, str(SCRIPT_ROOT))
sys.path.insert(0, str(SERVICE_ROOT))

from c1_correctness import run_c1  # noqa: E402
from c2_security_performance_cost import (  # noqa: E402
    DEFAULT_DATABASE_URL,
    aggregate_c2,
    run_c2_local,
)
from c3_quality import run_c3  # noqa: E402
from c4_recovery_soak import run_c4, run_c4_fast, run_real_soak  # noqa: E402
from c5_operations import run_c5, run_rollback_operations  # noqa: E402
from harness_common import (  # noqa: E402
    CertificationFailure,
    canonical_sha256,
    require_candidate_oid,
    sha256_file,
    write_atomic_json,
    write_atomic_text,
)
from live_provider_gemini import run_gemini_live  # noqa: E402


def _run(
    command: list[str],
    *,
    timeout_seconds: int,
    environment: dict[str, str] | None = None,
) -> tuple[int, str, str, float]:
    started = time.perf_counter()
    completed = subprocess.run(
        command,
        cwd=REPOSITORY_ROOT,
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="replace",
        env={**os.environ, **(environment or {})},
        timeout=timeout_seconds,
        check=False,
    )
    return (
        completed.returncode,
        completed.stdout,
        completed.stderr,
        time.perf_counter() - started,
    )


def _junit_counts(path: Path) -> dict[str, int]:
    root = ET.parse(path).getroot()
    suites = [root] if root.tag == "testsuite" else list(root.findall("testsuite"))
    return {
        "tests": sum(int(suite.attrib.get("tests", 0)) for suite in suites),
        "failures": sum(int(suite.attrib.get("failures", 0)) for suite in suites),
        "errors": sum(int(suite.attrib.get("errors", 0)) for suite in suites),
        "skipped": sum(int(suite.attrib.get("skipped", 0)) for suite in suites),
    }


def _flutter_counts(machine_output: str) -> dict[str, Any]:
    tests: dict[int, dict[str, Any]] = {}
    outcomes: list[dict[str, Any]] = []
    malformed = 0
    for raw_line in machine_output.splitlines():
        line = raw_line.strip()
        if not line.startswith("{"):
            continue
        try:
            event = json.loads(line)
        except ValueError:
            malformed += 1
            continue
        event_type = event.get("type")
        if event_type == "testStart":
            test = event.get("test", {})
            if isinstance(test, dict) and isinstance(test.get("id"), int):
                tests[int(test["id"])] = test
        elif event_type == "testDone":
            test_id = event.get("testID")
            test = tests.get(int(test_id), {}) if isinstance(test_id, int) else {}
            if test.get("hidden"):
                continue
            outcomes.append(
                {
                    "id": test_id,
                    "name": str(test.get("name", "")),
                    "url": str(test.get("url", "")),
                    "result": str(event.get("result", "unknown")),
                }
            )
    skipped = [row for row in outcomes if row["result"] == "skipped"]
    informational = [
        row
        for row in skipped
        if row["url"].replace("\\", "/").endswith("/test/amap_service_test.dart")
        and re.search(r"geocode|getWeatherDescription", row["name"])
    ]
    mandatory_skips = len(skipped) - len(informational)
    return {
        "test_count": len(outcomes),
        "passed_count": sum(row["result"] == "success" for row in outcomes),
        "failed_count": sum(row["result"] not in {"success", "skipped"} for row in outcomes),
        "informational_skip_count": len(informational),
        "mandatory_skip_count": mandatory_skips,
        "malformed_event_count": malformed,
        "outcomes_sha256": canonical_sha256(outcomes),
        "informational_skips": [
            {"name": row["name"], "url": row["url"]} for row in informational
        ],
    }


def run_regressions(
    evidence_root: Path,
    *,
    candidate_oid: str,
    flutter_executable: Path,
) -> dict[str, Any]:
    candidate = require_candidate_oid(candidate_oid)
    if not flutter_executable.is_file():
        raise CertificationFailure("c1.flutter_executable_missing")
    evidence_root.mkdir(parents=True, exist_ok=True)
    python_junit = evidence_root / "c1-python-regression.xml"
    python_command = [
        sys.executable,
        "-m",
        "pytest",
        "-q",
        "agent-service/tests",
        "--junitxml",
        str(python_junit),
    ]
    python_exit, python_stdout, python_stderr, python_seconds = _run(
        python_command,
        timeout_seconds=3_600,
        environment={
            "GONOW_DART_EXECUTABLE": str(
                flutter_executable.with_name(
                    "dart.bat" if flutter_executable.suffix.lower() == ".bat" else "dart"
                )
            )
        },
    )
    if not python_junit.is_file():
        raise CertificationFailure("c1.python_junit_missing")
    python_counts = _junit_counts(python_junit)

    flutter_command = [
        str(flutter_executable),
        "test",
        "--no-pub",
        "--machine",
    ]
    flutter_exit, flutter_stdout, flutter_stderr, flutter_seconds = _run(
        flutter_command,
        timeout_seconds=3_600,
    )
    flutter_raw = evidence_root / "c1-flutter-machine.jsonl"
    write_atomic_text(flutter_raw, flutter_stdout)
    flutter_counts = _flutter_counts(flutter_stdout)

    safe_diagnostics = {
        "python_stderr_sha256": canonical_sha256(python_stderr),
        "python_stdout_sha256": canonical_sha256(python_stdout),
        "flutter_stderr_sha256": canonical_sha256(flutter_stderr),
        "python_last_line": python_stdout.strip().splitlines()[-1][:240]
        if python_stdout.strip()
        else "",
        "flutter_non_json_line_count": sum(
            not line.lstrip().startswith("{") for line in flutter_stdout.splitlines()
        ),
    }
    mandatory_skip_count = python_counts["skipped"] + flutter_counts[
        "mandatory_skip_count"
    ]
    failure_count = (
        python_counts["failures"]
        + python_counts["errors"]
        + flutter_counts["failed_count"]
        + int(python_exit != 0)
        + int(flutter_exit != 0)
        + flutter_counts["malformed_event_count"]
    )
    report = {
        "schema_version": "1.0",
        "gate_id": "C1",
        "candidate_head_oid": candidate,
        "python": {
            "executable": str(Path(sys.executable).resolve()),
            "exit_code": python_exit,
            "duration_seconds": round(python_seconds, 6),
            **python_counts,
            "junit_path": python_junit.name,
            "junit_sha256": sha256_file(python_junit),
        },
        "flutter": {
            "executable": str(flutter_executable.resolve()),
            "exit_code": flutter_exit,
            "duration_seconds": round(flutter_seconds, 6),
            **flutter_counts,
            "machine_path": flutter_raw.name,
            "machine_sha256": sha256_file(flutter_raw),
        },
        "mandatory_skip_count": mandatory_skip_count,
        "informational_skip_count": flutter_counts["informational_skip_count"],
        "xfail_count": 0,
        "flaky_rerun_count": 0,
        "failure_count": failure_count,
        "status": "passed"
        if failure_count == 0 and mandatory_skip_count == 0
        else "failed",
        "diagnostics": safe_diagnostics,
        "production": False,
    }
    write_atomic_json(evidence_root / "regression-report.json", report)
    return report


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "action",
        choices=(
            "regression",
            "c1",
            "c2",
            "c2-live",
            "c3",
            "c4-fast",
            "c4-soak",
            "c4",
            "c5-observe",
            "c5",
        ),
    )
    parser.add_argument("--evidence-root", type=Path, required=True)
    parser.add_argument("--candidate-head-oid", required=True)
    parser.add_argument("--flutter-executable", type=Path)
    parser.add_argument("--database-url", default=DEFAULT_DATABASE_URL)
    parser.add_argument("--security-attempts", type=int, default=100_000)
    parser.add_argument("--local-runs", type=int, default=10_000)
    parser.add_argument("--soak-seconds", type=int, default=14_400)
    parser.add_argument("--soak-sample-seconds", type=float, default=30.0)
    parser.add_argument("--observation-seconds", type=int, default=300)
    return parser


def main(argv: list[str] | None = None) -> int:
    arguments = build_parser().parse_args(argv)
    candidate = require_candidate_oid(arguments.candidate_head_oid)
    evidence_root = arguments.evidence_root.resolve()
    started = datetime.now(UTC)
    if arguments.action == "regression":
        if arguments.flutter_executable is None:
            raise CertificationFailure("c1.flutter_executable_missing")
        result = run_regressions(
            evidence_root,
            candidate_oid=candidate,
            flutter_executable=arguments.flutter_executable,
        )
    elif arguments.action == "c1":
        result = run_c1(evidence_root, candidate)
    elif arguments.action == "c2":
        result = run_c2_local(
            evidence_root,
            candidate_oid=candidate,
            generated_attempt_count=arguments.security_attempts,
            run_count=arguments.local_runs,
            database_url=arguments.database_url,
        )
    elif arguments.action == "c2-live":
        run_gemini_live(evidence_root, candidate_oid=candidate)
        result = aggregate_c2(evidence_root, candidate_oid=candidate)
    elif arguments.action == "c3":
        result = run_c3(evidence_root, candidate)
    elif arguments.action == "c4-fast":
        result = run_c4_fast(evidence_root)
    elif arguments.action == "c4-soak":
        result = run_real_soak(
            evidence_root,
            duration_seconds=arguments.soak_seconds,
            sample_interval_seconds=arguments.soak_sample_seconds,
            database_url=arguments.database_url,
        )
    elif arguments.action == "c4":
        result = run_c4(evidence_root, candidate)
    elif arguments.action == "c5-observe":
        result = run_rollback_operations(
            evidence_root,
            observation_seconds=arguments.observation_seconds,
        )
    else:
        result = run_c5(evidence_root, candidate)
    summary = {
        "action": arguments.action,
        "candidate_head_oid": candidate,
        "started_at": started.isoformat(),
        "completed_at": datetime.now(UTC).isoformat(),
        "status": str(result.get("status", "completed")),
        "result_sha256": canonical_sha256(result),
    }
    print(json.dumps(summary, sort_keys=True, separators=(",", ":")))
    return 0 if result.get("status", "passed") in {"passed", "completed"} else 4


if __name__ == "__main__":
    raise SystemExit(main())
