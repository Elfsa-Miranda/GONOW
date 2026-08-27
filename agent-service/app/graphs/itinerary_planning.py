"""A deterministic, bounded single-agent itinerary planning graph."""

from __future__ import annotations

from collections.abc import Callable, Mapping
from dataclasses import dataclass, replace
from enum import StrEnum
import math
from typing import Protocol

from app.runtime.state import (
    BudgetSnapshot,
    GoNowAgentState,
    StateGuard,
    StateReference,
    WorkflowStage,
)


MAX_BUSINESS_STAGES = 6
BUSINESS_STAGES = (
    WorkflowStage.INTAKE,
    WorkflowStage.PLAN,
    WorkflowStage.EVIDENCE,
    WorkflowStage.COMPOSE,
    WorkflowStage.VALIDATE,
    WorkflowStage.COMPLETE,
)
ALLOWED_TRANSITIONS: Mapping[WorkflowStage, WorkflowStage] = {
    current: following for current, following in zip(BUSINESS_STAGES, BUSINESS_STAGES[1:])
}


class BudgetDimension(StrEnum):
    STEP = "step"
    MODEL_CALL = "model_call"
    TOOL_CALL = "tool_call"
    TOKEN = "token"
    DEADLINE = "deadline"
    NO_PROGRESS = "no_progress"


class PlanningGraphError(ValueError):
    def __init__(self, code: str, *, dimension: BudgetDimension | None = None) -> None:
        self.code = code
        self.dimension = dimension
        super().__init__(code)


class BudgetExceeded(PlanningGraphError):
    pass


@dataclass(frozen=True, slots=True)
class BudgetPolicy:
    max_steps: int
    max_no_progress_rounds: int
    deadline_monotonic: float

    def __post_init__(self) -> None:
        if (
            isinstance(self.max_steps, bool)
            or not isinstance(self.max_steps, int)
            or self.max_steps < 1
            or isinstance(self.max_no_progress_rounds, bool)
            or not isinstance(self.max_no_progress_rounds, int)
            or self.max_no_progress_rounds < 0
            or isinstance(self.deadline_monotonic, bool)
            or not isinstance(self.deadline_monotonic, (int, float))
            or not math.isfinite(self.deadline_monotonic)
            or self.deadline_monotonic < 0
        ):
            raise PlanningGraphError("budget.policy_invalid")


@dataclass(frozen=True, slots=True)
class PlanningStep:
    next_stage: WorkflowStage
    model_calls: int = 0
    tool_calls: int = 0
    tokens: int = 0
    made_progress: bool = True

    def __post_init__(self) -> None:
        if self.model_calls < 0 or self.tool_calls < 0 or self.tokens < 0:
            raise PlanningGraphError("budget.request_invalid")


@dataclass(frozen=True, slots=True)
class BudgetDecision:
    budget: BudgetSnapshot
    step_count: int
    model_call_count: int
    tool_call_count: int
    no_progress_rounds: int


class BudgetedStageState(Protocol):
    workflow_stage: WorkflowStage
    step_count: int
    model_call_count: int
    tool_call_count: int
    no_progress_rounds: int
    budget: BudgetSnapshot


@dataclass(frozen=True, slots=True)
class StageReferenceDelta:
    task_contract_ref: StateReference | None = None
    plan_intent_ref: StateReference | None = None
    evidence_refs: tuple[StateReference, ...] | None = None
    candidate_draft_ref: StateReference | None = None


@dataclass(frozen=True, slots=True)
class InProcessStageState:
    """Reference-only stage state; Job-level recovery remains authoritative."""

    budget: BudgetSnapshot
    workflow_stage: WorkflowStage = WorkflowStage.INTAKE
    task_contract_ref: StateReference | None = None
    plan_intent_ref: StateReference | None = None
    evidence_refs: tuple[StateReference, ...] = ()
    candidate_draft_ref: StateReference | None = None
    step_count: int = 0
    model_call_count: int = 0
    tool_call_count: int = 0
    no_progress_rounds: int = 0

    def __post_init__(self) -> None:
        if (
            self.workflow_stage is WorkflowStage.BLOCKED
            or min(
                self.step_count,
                self.model_call_count,
                self.tool_call_count,
                self.no_progress_rounds,
            )
            < 0
            or (
                self.task_contract_ref is not None
                and self.task_contract_ref.kind != "requirement"
            )
            or (
                self.plan_intent_ref is not None
                and self.plan_intent_ref.kind != "requirement"
            )
            or any(item.kind != "evidence" for item in self.evidence_refs)
            or (
                self.candidate_draft_ref is not None
                and self.candidate_draft_ref.kind != "candidate"
            )
        ):
            raise PlanningGraphError("graph.stage_state_invalid")


class BudgetManager:
    """Evaluate one budget dimension without mutating state."""

    @staticmethod
    def require(
        condition: bool,
        dimension: BudgetDimension,
        *,
        code: str = "budget.exhausted",
    ) -> None:
        if not condition:
            raise BudgetExceeded(code, dimension=dimension)


class MultiBudgetLimiter:
    """Atomically evaluate independent fuses and return one immutable decision."""

    def __init__(self, policy: BudgetPolicy) -> None:
        self._policy = policy

    def evaluate(
        self,
        state: BudgetedStageState,
        step: PlanningStep,
        *,
        now_monotonic: float,
    ) -> BudgetDecision:
        if (
            isinstance(now_monotonic, bool)
            or not isinstance(now_monotonic, (int, float))
            or not math.isfinite(now_monotonic)
            or now_monotonic < 0
        ):
            raise PlanningGraphError("budget.clock_invalid")
        no_progress_rounds = 0 if step.made_progress else state.no_progress_rounds + 1
        checks = (
            (state.step_count + 1 <= self._policy.max_steps, BudgetDimension.STEP),
            (
                step.model_calls <= state.budget.remaining_model_calls,
                BudgetDimension.MODEL_CALL,
            ),
            (
                step.tool_calls <= state.budget.remaining_tool_calls,
                BudgetDimension.TOOL_CALL,
            ),
            (step.tokens <= state.budget.remaining_tokens, BudgetDimension.TOKEN),
            (now_monotonic <= self._policy.deadline_monotonic, BudgetDimension.DEADLINE),
            (
                no_progress_rounds <= self._policy.max_no_progress_rounds,
                BudgetDimension.NO_PROGRESS,
            ),
        )
        for condition, dimension in checks:
            try:
                BudgetManager.require(condition, dimension)
            except BudgetExceeded as error:
                raise BudgetExceeded(
                    "budget.global_exhausted", dimension=error.dimension
                ) from error
        return BudgetDecision(
            budget=BudgetSnapshot(
                remaining_model_calls=(
                    state.budget.remaining_model_calls - step.model_calls
                ),
                remaining_tool_calls=state.budget.remaining_tool_calls - step.tool_calls,
                remaining_tokens=state.budget.remaining_tokens - step.tokens,
            ),
            step_count=state.step_count + 1,
            model_call_count=state.model_call_count + step.model_calls,
            tool_call_count=state.tool_call_count + step.tool_calls,
            no_progress_rounds=no_progress_rounds,
        )

class BoundedItineraryPlanningGraph:
    """Advance the fixed six-stage business graph through guarded state deltas."""

    def __init__(
        self,
        policy: BudgetPolicy,
        *,
        clock: Callable[[], float],
        state_guard: StateGuard | None = None,
    ) -> None:
        self._clock = clock
        self._limiter = MultiBudgetLimiter(policy)
        self._state_guard = state_guard or StateGuard()

    @property
    def max_business_stages(self) -> int:
        return len(BUSINESS_STAGES)

    def advance(
        self, state: GoNowAgentState, step: PlanningStep
    ) -> GoNowAgentState:
        decision = self.preflight(state, step)
        return self._state_guard.apply(
            state,
            {
                "workflow_stage": step.next_stage,
                "step_count": decision.step_count,
                "model_call_count": decision.model_call_count,
                "tool_call_count": decision.tool_call_count,
                "no_progress_rounds": decision.no_progress_rounds,
                "budget": decision.budget,
            },
        )

    def preflight(
        self,
        state: BudgetedStageState,
        step: PlanningStep,
    ) -> BudgetDecision:
        """Evaluate transition and budget before its next stage side effect."""

        expected = ALLOWED_TRANSITIONS.get(state.workflow_stage)
        if expected is None or step.next_stage is not expected:
            raise PlanningGraphError("graph.transition_invalid")
        return self._limiter.evaluate(
            state,
            step,
            now_monotonic=self._clock(),
        )

    def advance_in_process(
        self,
        state: InProcessStageState,
        step: PlanningStep,
        *,
        references: StageReferenceDelta = StageReferenceDelta(),
    ) -> InProcessStageState:
        self._assert_reference_delta(state.workflow_stage, references)
        decision = self.preflight(state, step)
        changes = {
            field_name: value
            for field_name, value in (
                ("task_contract_ref", references.task_contract_ref),
                ("plan_intent_ref", references.plan_intent_ref),
                ("evidence_refs", references.evidence_refs),
                ("candidate_draft_ref", references.candidate_draft_ref),
            )
            if value is not None
        }
        candidate = replace(
            state,
            workflow_stage=step.next_stage,
            step_count=decision.step_count,
            model_call_count=decision.model_call_count,
            tool_call_count=decision.tool_call_count,
            no_progress_rounds=decision.no_progress_rounds,
            budget=decision.budget,
            **changes,
        )
        self._assert_stage_references(candidate)
        return candidate

    @staticmethod
    def _assert_reference_delta(
        current_stage: WorkflowStage,
        references: StageReferenceDelta,
    ) -> None:
        supplied = {
            field_name
            for field_name, value in (
                ("task_contract_ref", references.task_contract_ref),
                ("plan_intent_ref", references.plan_intent_ref),
                ("evidence_refs", references.evidence_refs),
                ("candidate_draft_ref", references.candidate_draft_ref),
            )
            if value is not None
        }
        allowed = {
            WorkflowStage.INTAKE: {"task_contract_ref"},
            WorkflowStage.PLAN: {"plan_intent_ref"},
            WorkflowStage.EVIDENCE: {"evidence_refs"},
            WorkflowStage.COMPOSE: {"candidate_draft_ref"},
            WorkflowStage.VALIDATE: set(),
        }.get(current_stage, set())
        if not supplied.issubset(allowed):
            raise PlanningGraphError("graph.stage_delta_forbidden")

    @staticmethod
    def _assert_stage_references(state: InProcessStageState) -> None:
        if state.workflow_stage in {
            WorkflowStage.PLAN,
            WorkflowStage.EVIDENCE,
            WorkflowStage.COMPOSE,
            WorkflowStage.VALIDATE,
            WorkflowStage.COMPLETE,
        } and state.task_contract_ref is None:
            raise PlanningGraphError("graph.stage_reference_missing")
        if state.workflow_stage in {
            WorkflowStage.EVIDENCE,
            WorkflowStage.COMPOSE,
            WorkflowStage.VALIDATE,
            WorkflowStage.COMPLETE,
        } and state.plan_intent_ref is None:
            raise PlanningGraphError("graph.stage_reference_missing")
        if state.workflow_stage in {
            WorkflowStage.VALIDATE,
            WorkflowStage.COMPLETE,
        } and state.candidate_draft_ref is None:
            raise PlanningGraphError("graph.stage_reference_missing")
