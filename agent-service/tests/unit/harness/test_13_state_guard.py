from __future__ import annotations

import site
import sys
from pathlib import Path
from uuid import UUID

import pytest


SERVICE_ROOT = Path(__file__).resolve().parents[3]
site.addsitedir(str(SERVICE_ROOT / ".venv" / "Lib" / "site-packages"))
sys.path.insert(0, str(SERVICE_ROOT))

from app.runtime.state import (  # noqa: E402
    BudgetSnapshot,
    GoNowAgentState,
    StateContractError,
    StateGuard,
    StateReference,
    WorkflowStage,
)


def _state() -> GoNowAgentState:
    return GoNowAgentState(
        run_id=UUID(int=1),
        thread_id=UUID(int=2),
        tenant_id=UUID(int=3),
        principal_ref="principal://synthetic/harness",
        behavior_release_id=UUID(int=4),
        behavior_digest="4" * 64,
        goal_ref=StateReference(kind="goal", uri="goal://synthetic/harness", sha256="5" * 64),
        budget=BudgetSnapshot(
            remaining_model_calls=3,
            remaining_tool_calls=8,
            remaining_tokens=12000,
        ),
    )


def test_13_state_guard_s_applies_legal_delta() -> None:
    after = StateGuard().apply(
        _state(), {"workflow_stage": WorkflowStage.PLAN, "step_count": 1}
    )
    assert after.workflow_stage is WorkflowStage.PLAN
    assert after.step_count == 1


@pytest.mark.parametrize("forbidden", ("secret", "client", "reasoning"))
def test_13_state_guard_i_rejects_forbidden_extra_field(forbidden: str) -> None:
    with pytest.raises(StateContractError, match="state.invalid_delta"):
        StateGuard().apply(_state(), {forbidden: "synthetic-canary"})


def test_13_state_guard_i_rejects_immutable_identity_transition() -> None:
    with pytest.raises(StateContractError, match="state.invalid_delta"):
        StateGuard().apply(_state(), {"tenant_id": str(UUID(int=99))})


def test_13_state_guard_d_schema_dependency_failure_is_closed() -> None:
    with pytest.raises(StateContractError, match="state.invalid_delta"):
        StateGuard.unavailable().apply(_state(), {"step_count": 1})
