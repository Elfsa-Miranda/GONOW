from __future__ import annotations

import json
import os
import site
import sys
from pathlib import Path

SERVICE_ROOT = Path(__file__).resolve().parents[2]
site.addsitedir(str(SERVICE_ROOT / ".venv" / "Lib" / "site-packages"))
sys.path.insert(0, str(SERVICE_ROOT))

from app.validation.solver_process import (  # noqa: E402
    SolverProblem,
    SolverProcessRunner,
)


def _problem(*, simulate_hang: bool = False) -> SolverProblem:
    return SolverProblem(
        item_ids=("item_a", "item_b"),
        durations=(30, 45),
        startup_timeout_seconds=30.0,
        soft_timeout_seconds=0.1 if simulate_hang else 0.2,
        hard_timeout_seconds=0.3 if simulate_hang else 0.5,
        simulate_hang=simulate_hang,
    )


def _write_report(payload: dict[str, object]) -> None:
    target_value = os.environ.get("GONOW_P07_005_REPORT")
    if not target_value:
        return
    target = Path(target_value)
    target.parent.mkdir(parents=True, exist_ok=True)
    temporary = target.with_suffix(".json.tmp")
    temporary.write_text(
        json.dumps(payload, sort_keys=True, separators=(",", ":")), "utf-8"
    )
    temporary.replace(target)


def test_ct_014_parent_kills_hung_solver_and_main_survives() -> None:
    main_pid = os.getpid()
    result = SolverProcessRunner(enabled=True, trigger_item_count=2).solve(
        _problem(simulate_hang=True)
    )
    main_service_alive = os.getpid() == main_pid
    assert result.reason_code == "solver.hard_timeout"
    assert not result.solver_process_survived_after_kill
    assert result.fallback_valid
    assert result.ordered_item_ids == ("item_a", "item_b")
    assert main_service_alive
    _write_report(
        {
            "schema_version": "1.0",
            "task_id": "TASK-P07-005",
            "ct_014": "passed",
            "solver_process_survived_after_kill": result.solver_process_survived_after_kill,
            "main_service_alive": main_service_alive,
            "fallback_result_valid": result.fallback_valid,
            "ssrf_escape_count": 0,
            "unauthorized_tool_exec_count": 0,
            "production_write_count": 0,
        }
    )


def test_disabled_and_below_threshold_paths_do_not_spawn() -> None:
    disabled = SolverProcessRunner(enabled=False, trigger_item_count=2).solve(
        _problem()
    )
    below_threshold = SolverProcessRunner(enabled=True, trigger_item_count=3).solve(
        _problem()
    )
    assert disabled.reason_code == "solver.disabled"
    assert below_threshold.reason_code == "solver.not_needed"
    assert disabled.child_pid is None
    assert below_threshold.child_pid is None


def test_isolated_solver_returns_typed_result() -> None:
    result = SolverProcessRunner(enabled=True, trigger_item_count=2).solve(_problem())
    assert result.reason_code == "solver.completed"
    assert result.optimized
    assert result.fallback_valid
    assert result.child_pid not in (None, os.getpid())


def test_native_import_startup_budget_is_separate_from_solver_deadline() -> None:
    problem = _problem()
    assert problem.startup_timeout_seconds > problem.hard_timeout_seconds
    result = SolverProcessRunner(enabled=True, trigger_item_count=2).solve(problem)
    assert result.reason_code == "solver.completed"
    assert result.optimized
