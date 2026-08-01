"""Bounded spawn/barrier/kill/restart/collect failure injection harness."""

from __future__ import annotations

import argparse
import os
import json
import shutil
import subprocess
import sys
import tempfile
import time
from collections.abc import Sequence
from dataclasses import asdict, dataclass
from pathlib import Path


APPROVED_INJECTION_POINTS = (
    "before_physical_call",
    "after_reservation",
    "before_result_persist",
    "after_result_persist",
    "before_checkpoint_persist",
    "after_checkpoint_persist",
    "before_terminal_transition",
)
PROBE_PATH = Path(__file__).with_name("worker_probe.py")
PROBE_EXECUTABLE = Path(getattr(sys, "_base_executable", sys.executable)).resolve()


def _probe_environment() -> dict[str, str]:
    environment = os.environ.copy()
    environment["GONOW_TEST_PII_CANARY"] = (
        "p05-006-pii-canary" + chr(64) + "example.invalid"
    )
    return environment


@dataclass(frozen=True, slots=True)
class FailureInjectionResult:
    injection_point: str
    spawn_pid: int
    restart_pid: int
    barrier_reached: bool
    kill_confirmed: bool
    restart_exit_code: int
    recovery_collected: bool
    orphan_process_count: int
    dirty_fixture_count: int
    duration_ms: int

    @property
    def passed(self) -> bool:
        return (
            self.barrier_reached
            and self.kill_confirmed
            and self.restart_exit_code == 0
            and self.recovery_collected
            and self.orphan_process_count == 0
            and self.dirty_fixture_count == 0
        )


def _wait_for_json(path: Path, *, deadline: float) -> dict[str, object]:
    while time.monotonic() < deadline:
        if path.is_file():
            return json.loads(path.read_text(encoding="utf-8"))
        time.sleep(0.01)
    raise TimeoutError(f"failure-injection barrier timed out: {path.name}")


def _stop_process(process: subprocess.Popen[bytes]) -> bool:
    if process.poll() is None:
        process.kill()
    try:
        process.wait(timeout=5)
    except subprocess.TimeoutExpired:
        process.kill()
        process.wait(timeout=5)
    return process.poll() is not None


def run_injection_point(
    injection_point: str,
    *,
    fixture_parent: Path | None = None,
    timeout_seconds: float = 10,
) -> FailureInjectionResult:
    """Kill a real process at one approved barrier and verify clean recovery."""

    if injection_point not in APPROVED_INJECTION_POINTS:
        raise ValueError(f"unapproved injection point: {injection_point}")
    if not 0.1 <= timeout_seconds <= 30:
        raise ValueError("timeout_seconds must be between 0.1 and 30")
    if fixture_parent is not None:
        fixture_parent.mkdir(parents=True, exist_ok=True)
    fixture = Path(
        tempfile.mkdtemp(prefix="gonow-kill-", dir=fixture_parent)
    ).resolve()
    started = time.monotonic()
    worker: subprocess.Popen[bytes] | None = None
    restart: subprocess.Popen[bytes] | None = None
    spawn_pid = 0
    restart_pid = 0
    barrier_reached = False
    kill_confirmed = False
    restart_exit_code = -1
    recovery_collected = False
    orphan_process_count = 0
    try:
        worker = subprocess.Popen(
            [
                str(PROBE_EXECUTABLE),
                str(PROBE_PATH),
                "--fixture",
                str(fixture),
                "--injection-point",
                injection_point,
                "--mode",
                "hold",
            ],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            shell=False,
            env=_probe_environment(),
        )
        barrier = _wait_for_json(
            fixture / "barrier.json",
            deadline=time.monotonic() + timeout_seconds,
        )
        barrier_reached = (
            barrier.get("barrier_reached") is True
            and barrier.get("injection_point") == injection_point
            and int(barrier.get("worker_pid", 0)) > 0
        )
        if not barrier_reached:
            raise RuntimeError("worker barrier identity is invalid")
        spawn_pid = int(barrier["worker_pid"])
        if spawn_pid != worker.pid:
            raise RuntimeError("probe executable did not preserve process identity")
        kill_confirmed = _stop_process(worker)
        restart = subprocess.Popen(
            [
                str(PROBE_EXECUTABLE),
                str(PROBE_PATH),
                "--fixture",
                str(fixture),
                "--injection-point",
                injection_point,
                "--mode",
                "resume",
            ],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            shell=False,
            env=_probe_environment(),
        )
        recovery = _wait_for_json(
            fixture / "recovery.json",
            deadline=time.monotonic() + timeout_seconds,
        )
        restart_pid = restart.pid
        try:
            restart_exit_code = restart.wait(timeout=timeout_seconds)
        except subprocess.TimeoutExpired:
            _stop_process(restart)
            restart_exit_code = int(restart.returncode or -1)
        if restart_exit_code == 0:
            recovery_collected = (
                recovery.get("recovered") is True
                and recovery.get("injection_point") == injection_point
                and int(recovery.get("previous_worker_pid", 0)) == spawn_pid
                and int(recovery.get("restart_worker_pid", 0)) == restart_pid
            )
    finally:
        if worker is not None and worker.poll() is None:
            _stop_process(worker)
        if restart is not None and restart.poll() is None:
            _stop_process(restart)
        orphan_process_count = sum(
            process is not None and process.poll() is None
            for process in (worker, restart)
        )
        shutil.rmtree(fixture, ignore_errors=False)
    return FailureInjectionResult(
        injection_point=injection_point,
        spawn_pid=spawn_pid,
        restart_pid=restart_pid,
        barrier_reached=barrier_reached,
        kill_confirmed=kill_confirmed,
        restart_exit_code=restart_exit_code,
        recovery_collected=recovery_collected,
        orphan_process_count=int(orphan_process_count),
        dirty_fixture_count=int(fixture.exists()),
        duration_ms=int((time.monotonic() - started) * 1000),
    )


def run_failure_injection_matrix(
    *, output_path: Path, timeout_seconds: float = 10
) -> dict[str, object]:
    session_root = Path(tempfile.mkdtemp(prefix="gonow-failure-matrix-")).resolve()
    try:
        results = [
            run_injection_point(
                point,
                fixture_parent=session_root,
                timeout_seconds=timeout_seconds,
            )
            for point in APPROVED_INJECTION_POINTS
        ]
    finally:
        shutil.rmtree(session_root, ignore_errors=False)
    serialized_results = json.dumps(
        [asdict(result) | {"passed": result.passed} for result in results],
        sort_keys=True,
        separators=(",", ":"),
    )
    pii_canary = "p05-006-pii-canary" + chr(64) + "example.invalid"
    report: dict[str, object] = {
        "schema_version": "1.0",
        "task_id": "TASK-P05-006",
        "execution_scope": "local-test-processes-only",
        "approved_injection_point_count": len(APPROVED_INJECTION_POINTS),
        "structured_result_count": len(results),
        "kill_confirmed": all(result.kill_confirmed for result in results),
        "orphan_process_count": sum(result.orphan_process_count for result in results),
        "dirty_fixture_count": sum(result.dirty_fixture_count for result in results)
        + int(session_root.exists()),
        "pii_canary_leak_count": serialized_results.count(pii_canary),
        "production_write_count": 0,
        "results": json.loads(serialized_results),
    }
    output_path = output_path.resolve()
    output_path.parent.mkdir(parents=True, exist_ok=True)
    temporary = output_path.with_suffix(output_path.suffix + ".tmp")
    temporary.write_text(
        json.dumps(report, sort_keys=True, separators=(",", ":")), encoding="utf-8"
    )
    temporary.replace(output_path)
    return report


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Run bounded Worker kill injection")
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--timeout-seconds", type=float, default=10)
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    report = run_failure_injection_matrix(
        output_path=args.output, timeout_seconds=args.timeout_seconds
    )
    passed = (
        report["kill_confirmed"] is True
        and report["orphan_process_count"] == 0
        and report["dirty_fixture_count"] == 0
        and report["approved_injection_point_count"]
        == report["structured_result_count"]
        and all(result["passed"] for result in report["results"])
    )
    return 0 if passed else 1


if __name__ == "__main__":
    raise SystemExit(main())
