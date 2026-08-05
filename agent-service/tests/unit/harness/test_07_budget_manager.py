from __future__ import annotations

import site
import sys
from pathlib import Path

import pytest


SERVICE_ROOT = Path(__file__).resolve().parents[3]
site.addsitedir(str(SERVICE_ROOT / ".venv" / "Lib" / "site-packages"))
sys.path.insert(0, str(SERVICE_ROOT))

from app.graphs.itinerary_planning import (  # noqa: E402
    BudgetDimension,
    BudgetExceeded,
    BudgetManager,
)


def test_07_budget_manager_s_allows_available_dimension() -> None:
    BudgetManager.require(True, BudgetDimension.MODEL_CALL)


def test_07_budget_manager_i_rejects_exhausted_model_budget() -> None:
    with pytest.raises(BudgetExceeded, match="budget.exhausted") as failure:
        BudgetManager.require(False, BudgetDimension.MODEL_CALL)
    assert failure.value.dimension is BudgetDimension.MODEL_CALL


def test_07_budget_manager_i_rejects_exhausted_tool_budget_independently() -> None:
    with pytest.raises(BudgetExceeded) as failure:
        BudgetManager.require(False, BudgetDimension.TOOL_CALL)
    assert failure.value.dimension is BudgetDimension.TOOL_CALL


def test_07_budget_manager_d_fails_closed_when_deadline_is_unavailable() -> None:
    with pytest.raises(BudgetExceeded, match="budget.exhausted"):
        BudgetManager.require(False, BudgetDimension.DEADLINE)
