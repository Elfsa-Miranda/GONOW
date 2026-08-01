"""A deterministic, bounded single-agent itinerary planning graph."""

from __future__ import annotations

from collections.abc import Callable, Mapping
from dataclasses import dataclass
from enum import StrEnum

from app.runtime.state import BudgetSnapshot, GoNowAgentState, StateGuard, WorkflowStage


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
            self.max_steps < 1
            or self.max_no_progress_rounds < 0
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
        state: GoNowAgentState,
        step: PlanningStep,
        *,
        now_monotonic: float,
    ) -> BudgetDecision:
        if now_monotonic < 0:
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
        expected = ALLOWED_TRANSITIONS.get(state.workflow_stage)
        if expected is None or step.next_stage is not expected:
            raise PlanningGraphError("graph.transition_invalid")
        decision = self._limiter.evaluate(
            state,
            step,
            now_monotonic=self._clock(),
        )
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
