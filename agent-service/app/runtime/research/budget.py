"""Atomic shared budget reservations for at most two research branches."""

from __future__ import annotations

from collections.abc import Mapping
from threading import Lock

from pydantic import BaseModel, ConfigDict, Field

from app.runtime.research.contracts import ResearchBranchId


MAX_RESEARCH_BRANCHES = 2


class BranchBudgetError(RuntimeError):
    def __init__(self, code: str = "budget.global_exhausted") -> None:
        self.code = code
        super().__init__(code)


class BranchBudgetSnapshot(BaseModel):
    model_config = ConfigDict(extra="forbid", frozen=True)

    global_limit: int = Field(ge=1)
    global_reserved: int = Field(ge=0)
    branch_limits: Mapping[ResearchBranchId, int]
    branch_reserved: Mapping[ResearchBranchId, int]
    stopped: bool


class BranchBudgetReservation(BaseModel):
    model_config = ConfigDict(extra="forbid", frozen=True)

    branch_id: ResearchBranchId
    physical_calls: int = Field(ge=1)
    branch_reserved: int = Field(ge=1)
    global_reserved: int = Field(ge=1)
    global_remaining: int = Field(ge=0)


class SharedBranchBudget:
    """In-process experiment ledger with fail-closed, non-borrowing reservations.

    The Phase 8 caller must create one instance per Run. Each retry or provider
    attempt reserves its physical call before invocation; reservations are never
    released or transferred between branches.
    """

    def __init__(
        self,
        *,
        global_limit: int,
        branch_limits: Mapping[ResearchBranchId | str, int],
        ledger_available: bool = True,
    ) -> None:
        if not branch_limits or len(branch_limits) > MAX_RESEARCH_BRANCHES:
            raise BranchBudgetError("budget.invalid_branch_count")
        try:
            normalized = {
                ResearchBranchId(branch_id): limit
                for branch_id, limit in branch_limits.items()
            }
        except ValueError as error:
            raise BranchBudgetError("budget.invalid_branch_count") from error
        if global_limit < 1:
            raise BranchBudgetError("budget.invalid_limit")
        if any(limit < 1 for limit in normalized.values()):
            raise BranchBudgetError("budget.invalid_limit")
        if sum(normalized.values()) > global_limit:
            raise BranchBudgetError("budget.branch_allocation_exceeds_global")
        self._global_limit = global_limit
        self._branch_limits = normalized
        self._branch_reserved = {branch_id: 0 for branch_id in normalized}
        self._global_reserved = 0
        self._ledger_available = ledger_available
        self._lock = Lock()

    def reserve(
        self, branch_id: ResearchBranchId | str, *, physical_calls: int = 1
    ) -> BranchBudgetReservation:
        try:
            normalized_branch = ResearchBranchId(branch_id)
        except ValueError as error:
            raise BranchBudgetError("budget.branch_unknown") from error
        if physical_calls < 1:
            raise BranchBudgetError("budget.invalid_usage")
        with self._lock:
            if not self._ledger_available:
                raise BranchBudgetError()
            if normalized_branch not in self._branch_limits:
                raise BranchBudgetError("budget.branch_unknown")
            next_branch = self._branch_reserved[normalized_branch] + physical_calls
            next_global = self._global_reserved + physical_calls
            if next_branch > self._branch_limits[normalized_branch]:
                raise BranchBudgetError("budget.branch_exhausted")
            if next_global > self._global_limit:
                raise BranchBudgetError()
            self._branch_reserved[normalized_branch] = next_branch
            self._global_reserved = next_global
            return BranchBudgetReservation(
                branch_id=normalized_branch,
                physical_calls=physical_calls,
                branch_reserved=next_branch,
                global_reserved=next_global,
                global_remaining=self._global_limit - next_global,
            )

    def snapshot(self) -> BranchBudgetSnapshot:
        with self._lock:
            if not self._ledger_available:
                raise BranchBudgetError()
            return BranchBudgetSnapshot(
                global_limit=self._global_limit,
                global_reserved=self._global_reserved,
                branch_limits=dict(self._branch_limits),
                branch_reserved=dict(self._branch_reserved),
                stopped=self._global_reserved >= self._global_limit
                or all(
                    self._branch_reserved[branch_id] >= limit
                    for branch_id, limit in self._branch_limits.items()
                ),
            )
