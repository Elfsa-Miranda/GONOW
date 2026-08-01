from __future__ import annotations

import site
import sys
from pathlib import Path
from uuid import UUID

import pytest


SERVICE_ROOT = Path(__file__).resolve().parents[3]
site.addsitedir(str(SERVICE_ROOT / ".venv" / "Lib" / "site-packages"))
sys.path.insert(0, str(SERVICE_ROOT))

from app.graphs.itinerary_planning import (  # noqa: E402
    BudgetDimension,
    BudgetExceeded,
    BudgetPolicy,
    MultiBudgetLimiter,
    PlanningStep,
)
from app.runtime.state import (  # noqa: E402
    BudgetSnapshot,
    GoNowAgentState,
    StateReference,
    WorkflowStage,
)


def _state() -> GoNowAgentState:
    return GoNowAgentState(
        run_id=UUID(int=11),
        thread_id=UUID(int=12),
        tenant_id=UUID(int=13),
        principal_ref="principal://budget-limiter",
        behavior_release_id=UUID(int=14),
        behavior_digest="c" * 64,
        goal_ref=StateReference(kind="goal", uri="goal://budget/001", sha256="d" * 64),
        budget=BudgetSnapshot(
            remaining_model_calls=1,
            remaining_tool_calls=1,
            remaining_tokens=100,
        ),
    )


def _limiter() -> MultiBudgetLimiter:
    return MultiBudgetLimiter(
        BudgetPolicy(max_steps=2, max_no_progress_rounds=1, deadline_monotonic=20)
    )


def test_08_multi_budget_limiter_s_consumes_all_dimensions_atomically() -> None:
    decision = _limiter().evaluate(
        _state(),
        PlanningStep(
            next_stage=WorkflowStage.PLAN, model_calls=1, tool_calls=1, tokens=100
        ),
        now_monotonic=10,
    )
    assert decision.budget == BudgetSnapshot(
        remaining_model_calls=0, remaining_tool_calls=0, remaining_tokens=0
    )


@pytest.mark.parametrize(
    ("step", "now", "dimension"),
    (
        (PlanningStep(next_stage=WorkflowStage.PLAN, model_calls=2), 10, BudgetDimension.MODEL_CALL),
        (PlanningStep(next_stage=WorkflowStage.PLAN, tool_calls=2), 10, BudgetDimension.TOOL_CALL),
        (PlanningStep(next_stage=WorkflowStage.PLAN, tokens=101), 10, BudgetDimension.TOKEN),
        (PlanningStep(next_stage=WorkflowStage.PLAN), 21, BudgetDimension.DEADLINE),
    ),
)
def test_08_multi_budget_limiter_i_reports_exact_fuse(
    step: PlanningStep, now: float, dimension: BudgetDimension
) -> None:
    with pytest.raises(BudgetExceeded, match="budget.global_exhausted") as failure:
        _limiter().evaluate(_state(), step, now_monotonic=now)
    assert failure.value.dimension is dimension


def test_08_multi_budget_limiter_i_rejects_no_progress_independently() -> None:
    state = _state().model_copy(update={"no_progress_rounds": 1})
    with pytest.raises(BudgetExceeded) as failure:
        _limiter().evaluate(
            state,
            PlanningStep(next_stage=WorkflowStage.PLAN, made_progress=False),
            now_monotonic=10,
        )
    assert failure.value.dimension is BudgetDimension.NO_PROGRESS


def test_08_multi_budget_limiter_d_failure_does_not_mutate_input() -> None:
    state = _state()
    before = state.checkpoint_json()
    with pytest.raises(BudgetExceeded):
        _limiter().evaluate(
            state,
            PlanningStep(next_stage=WorkflowStage.PLAN, tokens=101),
            now_monotonic=10,
        )
    assert state.checkpoint_json() == before
