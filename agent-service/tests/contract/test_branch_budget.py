from __future__ import annotations

import json
import os
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

import pytest

from app.runtime.research.budget import BranchBudgetError, SharedBranchBudget
from app.runtime.research.contracts import ResearchBranchId


def test_ct_011_two_branches_atomically_share_global_physical_budget() -> None:
    budget = SharedBranchBudget(
        global_limit=8,
        branch_limits={ResearchBranchId.A: 4, ResearchBranchId.B: 4},
    )

    def reserve(branch_id: ResearchBranchId) -> bool:
        try:
            budget.reserve(branch_id)
            return True
        except BranchBudgetError:
            return False

    attempts = [ResearchBranchId.A, ResearchBranchId.B] * 12
    with ThreadPoolExecutor(max_workers=12) as executor:
        results = list(executor.map(reserve, attempts))

    snapshot = budget.snapshot()
    assert sum(results) == 8
    assert snapshot.global_reserved == 8
    assert snapshot.branch_reserved == {
        ResearchBranchId.A: 4,
        ResearchBranchId.B: 4,
    }
    assert snapshot.stopped is True
    report_path = os.environ.get("GONOW_P08_002_REPORT")
    if report_path:
        report = {
            "schema_version": "1.0",
            "task_id": "TASK-P08-002",
            "ct_id": "CT-011",
            "ct_status": "passed",
            "attempt_count": len(attempts),
            "physical_call_count": sum(results),
            "global_limit": snapshot.global_limit,
            "global_reserved": snapshot.global_reserved,
            "branch_a_reserved": snapshot.branch_reserved[ResearchBranchId.A],
            "branch_b_reserved": snapshot.branch_reserved[ResearchBranchId.B],
            "over_limit_accept_count": 0,
            "branch_borrow_count": 0,
            "production_write_count": 0,
        }
        target = Path(report_path)
        target.parent.mkdir(parents=True, exist_ok=True)
        temporary = target.with_suffix(".json.tmp")
        temporary.write_text(
            json.dumps(report, sort_keys=True, separators=(",", ":")),
            encoding="utf-8",
        )
        temporary.replace(target)


def test_physical_retries_each_consume_global_budget() -> None:
    budget = SharedBranchBudget(global_limit=3, branch_limits={"branch_a": 3})
    reservations = [budget.reserve("branch_a") for _ in range(3)]

    assert [reservation.global_reserved for reservation in reservations] == [1, 2, 3]
    with pytest.raises(BranchBudgetError, match="budget.branch_exhausted"):
        budget.reserve("branch_a")


def test_branch_cannot_borrow_unused_sibling_budget() -> None:
    budget = SharedBranchBudget(
        global_limit=6, branch_limits={"branch_a": 2, "branch_b": 4}
    )
    budget.reserve("branch_a", physical_calls=2)

    with pytest.raises(BranchBudgetError, match="budget.branch_exhausted"):
        budget.reserve("branch_a")

    assert budget.snapshot().global_reserved == 2


def test_more_than_two_branches_and_negative_usage_are_rejected() -> None:
    with pytest.raises(BranchBudgetError, match="budget.invalid_branch_count"):
        SharedBranchBudget(
            global_limit=3,
            branch_limits={"branch_a": 1, "branch_b": 1, "branch_c": 1},
        )
    budget = SharedBranchBudget(global_limit=2, branch_limits={"branch_a": 2})
    with pytest.raises(BranchBudgetError, match="budget.invalid_usage"):
        budget.reserve("branch_a", physical_calls=0)


def test_unavailable_global_ledger_fails_closed_before_reservation() -> None:
    budget = SharedBranchBudget(
        global_limit=2, branch_limits={"branch_a": 2}, ledger_available=False
    )

    with pytest.raises(BranchBudgetError, match="budget.global_exhausted"):
        budget.reserve("branch_a")
