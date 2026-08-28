"""Parent-owned process isolation for the optional native OR-Tools solver."""

from __future__ import annotations

import multiprocessing
import os
from collections.abc import Sequence
from multiprocessing.connection import Connection
from typing import Literal

from pydantic import BaseModel, ConfigDict, Field, model_validator


SolverReason = Literal[
    "solver.completed",
    "solver.disabled",
    "solver.not_needed",
    "solver.soft_timeout",
    "solver.hard_timeout",
    "solver.startup_timeout",
    "solver.child_failed",
]


class SolverProblem(BaseModel):
    model_config = ConfigDict(extra="forbid", frozen=True)

    item_ids: tuple[str, ...] = Field(min_length=1, max_length=128)
    durations: tuple[int, ...] = Field(min_length=1, max_length=128)
    startup_timeout_seconds: float = Field(default=30.0, ge=1.0, le=60.0)
    soft_timeout_seconds: float = Field(default=0.2, ge=0.01, le=10.0)
    hard_timeout_seconds: float = Field(default=0.5, ge=0.02, le=15.0)
    simulate_hang: bool = False

    @model_validator(mode="after")
    def validate_shape(self) -> SolverProblem:
        if len(self.item_ids) != len(self.durations):
            raise ValueError("solver.shape_mismatch")
        if len(set(self.item_ids)) != len(self.item_ids):
            raise ValueError("solver.duplicate_item")
        if any(duration <= 0 or duration > 1_440 for duration in self.durations):
            raise ValueError("solver.duration_out_of_range")
        if self.hard_timeout_seconds <= self.soft_timeout_seconds:
            raise ValueError("solver.hard_timeout_not_after_soft_timeout")
        return self


class SolverResult(BaseModel):
    model_config = ConfigDict(extra="forbid", frozen=True)

    ordered_item_ids: tuple[str, ...]
    optimized: bool
    fallback_valid: bool
    reason_code: SolverReason
    child_pid: int | None = None
    solver_process_survived_after_kill: bool = False


class SolverChildReady(BaseModel):
    model_config = ConfigDict(extra="forbid", frozen=True)

    schema_version: Literal["1.0"] = "1.0"
    kind: Literal["ready"] = "ready"
    child_pid: int = Field(gt=0)


class SolverChildResult(BaseModel):
    model_config = ConfigDict(extra="forbid", frozen=True)

    schema_version: Literal["1.0"] = "1.0"
    kind: Literal["result"] = "result"
    result: SolverResult


def _child_entry(problem_json: str, result_connection: Connection) -> None:
    """Import native code only inside the isolated child process."""
    problem = SolverProblem.model_validate_json(problem_json)
    from ortools.sat.python import cp_model

    result_connection.send(SolverChildReady(child_pid=os.getpid()).model_dump_json())
    if problem.simulate_hang:
        multiprocessing.Event().wait(problem.hard_timeout_seconds * 10)
        return

    model = cp_model.CpModel()
    starts = [
        model.new_int_var(0, sum(problem.durations), f"start_{index}")
        for index in range(len(problem.item_ids))
    ]
    for index in range(1, len(starts)):
        model.add(starts[index] >= starts[index - 1] + problem.durations[index - 1])
    model.minimize(starts[-1])
    solver = cp_model.CpSolver()
    solver.parameters.max_time_in_seconds = problem.soft_timeout_seconds
    status = solver.solve(model)
    if status not in (cp_model.OPTIMAL, cp_model.FEASIBLE):
        result = SolverResult(
            ordered_item_ids=problem.item_ids,
            optimized=False,
            fallback_valid=True,
            reason_code="solver.soft_timeout",
            child_pid=os.getpid(),
        )
    else:
        result = SolverResult(
            ordered_item_ids=problem.item_ids,
            optimized=True,
            fallback_valid=True,
            reason_code="solver.completed",
            child_pid=os.getpid(),
        )
    result_connection.send(SolverChildResult(result=result).model_dump_json())
    result_connection.close()


class SolverProcessRunner:
    """Gate solver use, enforce a hard parent deadline, and return typed fallback."""

    def __init__(self, *, enabled: bool, trigger_item_count: int = 8) -> None:
        if trigger_item_count < 2 or trigger_item_count > 128:
            raise ValueError("solver.trigger_item_count_invalid")
        self._enabled = enabled
        self._trigger_item_count = trigger_item_count

    def solve(self, problem: SolverProblem) -> SolverResult:
        if not self._enabled:
            return self._fallback(problem.item_ids, "solver.disabled")
        if len(problem.item_ids) < self._trigger_item_count:
            return self._fallback(problem.item_ids, "solver.not_needed")

        context = multiprocessing.get_context("spawn")
        result_connection, child_connection = context.Pipe(duplex=False)
        process = context.Process(
            target=_child_entry,
            args=(problem.model_dump_json(), child_connection),
            daemon=True,
            name="gonow-optional-solver",
        )
        process.start()
        child_connection.close()
        if not result_connection.poll(problem.startup_timeout_seconds):
            return self._terminate(
                process,
                result_connection,
                problem.item_ids,
                "solver.startup_timeout",
            )
        try:
            raw_ready = result_connection.recv()
            ready = SolverChildReady.model_validate_json(raw_ready)
        except (EOFError, OSError, ValueError, TypeError):
            return self._terminate(
                process,
                result_connection,
                problem.item_ids,
                "solver.child_failed",
            )
        if ready.child_pid != process.pid:
            return self._terminate(
                process,
                result_connection,
                problem.item_ids,
                "solver.child_failed",
            )
        if not result_connection.poll(problem.hard_timeout_seconds):
            return self._terminate(
                process,
                result_connection,
                problem.item_ids,
                "solver.hard_timeout",
            )
        try:
            raw_result = result_connection.recv()
            message = SolverChildResult.model_validate_json(raw_result)
        except (EOFError, OSError, ValueError, TypeError):
            return self._terminate(
                process,
                result_connection,
                problem.item_ids,
                "solver.child_failed",
            )
        if message.result.child_pid != process.pid:
            return self._terminate(
                process,
                result_connection,
                problem.item_ids,
                "solver.child_failed",
            )
        result_connection.close()
        self._join_or_kill(process)
        return message.result

    @classmethod
    def _terminate(
        cls,
        process: multiprocessing.Process,
        result_connection: Connection,
        item_ids: Sequence[str],
        reason: SolverReason,
    ) -> SolverResult:
        result_connection.close()
        process.join(timeout=0)
        if process.is_alive():
            process.kill()
        process.join(timeout=1.0)
        return SolverResult(
            ordered_item_ids=tuple(item_ids),
            optimized=False,
            fallback_valid=True,
            reason_code=reason,
            child_pid=process.pid,
            solver_process_survived_after_kill=process.is_alive(),
        )

    @staticmethod
    def _join_or_kill(process: multiprocessing.Process) -> None:
        process.join(timeout=1.0)
        if process.is_alive():
            process.kill()
            process.join(timeout=1.0)

    @staticmethod
    def _fallback(item_ids: Sequence[str], reason: SolverReason) -> SolverResult:
        return SolverResult(
            ordered_item_ids=tuple(item_ids),
            optimized=False,
            fallback_valid=True,
            reason_code=reason,
        )
