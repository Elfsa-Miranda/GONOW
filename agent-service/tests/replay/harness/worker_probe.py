"""Disposable worker process used by the process-level kill harness."""

from __future__ import annotations

import argparse
import json
import os
import time
from collections.abc import Sequence
from pathlib import Path


def _write_json_atomic(path: Path, value: dict[str, object]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + f".{os.getpid()}.tmp")
    temporary.write_text(
        json.dumps(value, sort_keys=True, separators=(",", ":")), encoding="utf-8"
    )
    os.replace(temporary, path)


def _hold_at_barrier(*, fixture: Path, injection_point: str) -> int:
    state = {
        "schema_version": "1.0",
        "injection_point": injection_point,
        "worker_pid": os.getpid(),
        "durable_marker": f"durable:{injection_point}",
    }
    _write_json_atomic(fixture / "durable-state.json", state)
    _write_json_atomic(
        fixture / "barrier.json",
        {
            "schema_version": "1.0",
            "injection_point": injection_point,
            "worker_pid": os.getpid(),
            "barrier_reached": True,
        },
    )
    while True:
        time.sleep(60)


def _resume(*, fixture: Path, injection_point: str) -> int:
    state = json.loads((fixture / "durable-state.json").read_text(encoding="utf-8"))
    if state.get("injection_point") != injection_point:
        raise RuntimeError("durable injection point does not match restart request")
    _write_json_atomic(
        fixture / "recovery.json",
        {
            "schema_version": "1.0",
            "injection_point": injection_point,
            "previous_worker_pid": int(state["worker_pid"]),
            "restart_worker_pid": os.getpid(),
            "durable_marker": state["durable_marker"],
            "recovered": True,
        },
    )
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="GoNow disposable failure probe")
    parser.add_argument("--fixture", type=Path, required=True)
    parser.add_argument("--injection-point", required=True)
    parser.add_argument("--mode", choices=("hold", "resume"), required=True)
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    fixture = args.fixture.resolve()
    if args.mode == "hold":
        return _hold_at_barrier(
            fixture=fixture, injection_point=args.injection_point
        )
    return _resume(fixture=fixture, injection_point=args.injection_point)


if __name__ == "__main__":
    raise SystemExit(main())
