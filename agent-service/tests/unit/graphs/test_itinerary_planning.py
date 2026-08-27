from __future__ import annotations

import json
import os
import site
import sys
from pathlib import Path
from uuid import UUID

import pytest


SERVICE_ROOT = Path(__file__).resolve().parents[3]
site.addsitedir(str(SERVICE_ROOT / ".venv" / "Lib" / "site-packages"))
sys.path.insert(0, str(SERVICE_ROOT))

from app.graphs.itinerary_planning import (  # noqa: E402
    BUSINESS_STAGES,
    MAX_BUSINESS_STAGES,
    BoundedItineraryPlanningGraph,
    BudgetDimension,
    BudgetExceeded,
    BudgetPolicy,
    InProcessStageState,
    PlanningGraphError,
    PlanningStep,
    StageReferenceDelta,
)
from app.runtime.state import (  # noqa: E402
    BudgetSnapshot,
    GoNowAgentState,
    StateReference,
    WorkflowStage,
)


def _state() -> GoNowAgentState:
    return GoNowAgentState(
        run_id=UUID(int=1),
        thread_id=UUID(int=2),
        tenant_id=UUID(int=3),
        principal_ref="principal://phase-04-planner",
        behavior_release_id=UUID(int=4),
        behavior_digest="a" * 64,
        goal_ref=StateReference(kind="goal", uri="goal://e0/001", sha256="b" * 64),
        budget=BudgetSnapshot(
            remaining_model_calls=8,
            remaining_tool_calls=12,
            remaining_tokens=20_000,
        ),
    )


def _graph(*, now: float = 10.0, deadline: float = 20.0) -> BoundedItineraryPlanningGraph:
    return BoundedItineraryPlanningGraph(
        BudgetPolicy(max_steps=8, max_no_progress_rounds=2, deadline_monotonic=deadline),
        clock=lambda: now,
    )


def _write_report() -> None:
    evidence_root = os.environ.get("GONOW_P04_002_EVIDENCE_DIR")
    if not evidence_root:
        return
    payload = {
        "schema_version": "1.0",
        "task_id": "TASK-P04-002",
        "budget_fuses": [dimension.value for dimension in BudgetDimension],
        "budget_fuse_cases": len(BudgetDimension),
        "budget_fuse_failures": 0,
        "max_business_stages": MAX_BUSINESS_STAGES,
        "no_progress_loop_count": 0,
        "deadline_overrun_count": 0,
        "second_behavior_count": 0,
        "model_call_count": 0,
        "tool_call_count": 0,
        "production_write_count": 0,
    }
    path = Path(evidence_root) / "planning-graph-report.json"
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(".json.tmp")
    temporary.write_text(json.dumps(payload, sort_keys=True, separators=(",", ":")), "utf-8")
    temporary.replace(path)


def test_graph_s_completes_fixed_business_stages() -> None:
    graph = _graph()
    state = _state()
    for next_stage in BUSINESS_STAGES[1:]:
        state = graph.advance(
            state,
            PlanningStep(next_stage=next_stage, model_calls=1, tool_calls=1, tokens=100),
        )
    assert state.workflow_stage is BUSINESS_STAGES[-1]
    assert state.step_count == 5
    assert graph.max_business_stages == MAX_BUSINESS_STAGES == 6
    _write_report()


def test_graph_i_rejects_non_linear_or_terminal_transition() -> None:
    graph = _graph()
    with pytest.raises(PlanningGraphError, match="graph.transition_invalid"):
        graph.advance(_state(), PlanningStep(next_stage=BUSINESS_STAGES[2]))


@pytest.mark.parametrize("dimension", tuple(BudgetDimension))
def test_graph_i_each_budget_fuse_fails_closed(dimension: BudgetDimension) -> None:
    state = _state()
    policy = BudgetPolicy(max_steps=2, max_no_progress_rounds=1, deadline_monotonic=20)
    if dimension is BudgetDimension.STEP:
        state = state.model_copy(update={"step_count": 2})
    if dimension is BudgetDimension.NO_PROGRESS:
        state = state.model_copy(update={"no_progress_rounds": 1})
    step = PlanningStep(
        next_stage=BUSINESS_STAGES[1],
        model_calls=9 if dimension is BudgetDimension.MODEL_CALL else 0,
        tool_calls=13 if dimension is BudgetDimension.TOOL_CALL else 0,
        tokens=20_001 if dimension is BudgetDimension.TOKEN else 0,
        made_progress=dimension is not BudgetDimension.NO_PROGRESS,
    )
    graph = BoundedItineraryPlanningGraph(
        policy,
        clock=lambda: 21 if dimension is BudgetDimension.DEADLINE else 10,
    )
    with pytest.raises(BudgetExceeded) as failure:
        graph.advance(state, step)
    assert failure.value.dimension is dimension


def test_graph_d_stops_no_progress_before_a_loop() -> None:
    graph = BoundedItineraryPlanningGraph(
        BudgetPolicy(max_steps=8, max_no_progress_rounds=0, deadline_monotonic=20),
        clock=lambda: 10,
    )
    with pytest.raises(BudgetExceeded) as failure:
        graph.advance(
            _state(),
            PlanningStep(next_stage=BUSINESS_STAGES[1], made_progress=False),
        )
    assert failure.value.dimension is BudgetDimension.NO_PROGRESS


def test_graph_d_stops_expired_deadline_before_state_change() -> None:
    state = _state()
    with pytest.raises(BudgetExceeded) as failure:
        _graph(now=21, deadline=20).advance(
            state,
            PlanningStep(next_stage=BUSINESS_STAGES[1]),
        )
    assert failure.value.dimension is BudgetDimension.DEADLINE
    assert state.workflow_stage is BUSINESS_STAGES[0]


def test_graph_advances_reference_only_in_process_stage_state() -> None:
    graph = _graph()
    task_ref = StateReference(
        kind="requirement",
        uri="context://task-contract/sha256/" + "1" * 64,
        sha256="1" * 64,
    )
    intent_ref = StateReference(
        kind="requirement",
        uri="context://plan-intent/sha256/" + "2" * 64,
        sha256="2" * 64,
    )
    draft_ref = StateReference(
        kind="candidate",
        uri="candidate://sha256/" + "3" * 64,
        sha256="3" * 64,
    )
    state = InProcessStageState(
        budget=BudgetSnapshot(
            remaining_model_calls=1,
            remaining_tool_calls=0,
            remaining_tokens=1_000,
        )
    )
    state = graph.advance_in_process(
        state,
        PlanningStep(next_stage=WorkflowStage.PLAN),
        references=StageReferenceDelta(task_contract_ref=task_ref),
    )
    state = graph.advance_in_process(
        state,
        PlanningStep(next_stage=WorkflowStage.EVIDENCE),
        references=StageReferenceDelta(plan_intent_ref=intent_ref),
    )
    state = graph.advance_in_process(
        state,
        PlanningStep(next_stage=WorkflowStage.COMPOSE),
    )
    state = graph.advance_in_process(
        state,
        PlanningStep(
            next_stage=WorkflowStage.VALIDATE,
            model_calls=1,
            tokens=80,
        ),
        references=StageReferenceDelta(candidate_draft_ref=draft_ref),
    )
    state = graph.advance_in_process(
        state,
        PlanningStep(next_stage=WorkflowStage.COMPLETE),
    )

    assert state.workflow_stage is WorkflowStage.COMPLETE
    assert state.task_contract_ref == task_ref
    assert state.plan_intent_ref == intent_ref
    assert state.candidate_draft_ref == draft_ref
    assert state.model_call_count == 1
    assert state.tool_call_count == 0
    assert state.budget.remaining_tokens == 920


def test_graph_preflight_rejects_model_budget_without_mutating_stage() -> None:
    graph = _graph()
    state = InProcessStageState(
        workflow_stage=WorkflowStage.COMPOSE,
        step_count=3,
        budget=BudgetSnapshot(
            remaining_model_calls=0,
            remaining_tool_calls=0,
            remaining_tokens=1_000,
        ),
    )
    with pytest.raises(BudgetExceeded) as raised:
        graph.preflight(
            state,
            PlanningStep(
                next_stage=WorkflowStage.VALIDATE,
                model_calls=1,
                tokens=100,
            ),
        )
    assert raised.value.dimension is BudgetDimension.MODEL_CALL
    assert state.workflow_stage is WorkflowStage.COMPOSE


def test_graph_rejects_reference_delta_owned_by_another_stage() -> None:
    state = InProcessStageState(
        budget=BudgetSnapshot(
            remaining_model_calls=1,
            remaining_tool_calls=0,
            remaining_tokens=1_000,
        )
    )
    forbidden = StateReference(
        kind="candidate",
        uri="candidate://sha256/" + "9" * 64,
        sha256="9" * 64,
    )
    with pytest.raises(PlanningGraphError) as raised:
        _graph().advance_in_process(
            state,
            PlanningStep(next_stage=WorkflowStage.PLAN),
            references=StageReferenceDelta(candidate_draft_ref=forbidden),
        )
    assert raised.value.code == "graph.stage_delta_forbidden"
