"""Bounded, local, deterministic repair for validated itinerary candidates."""

from __future__ import annotations

import copy
import hashlib
import json
from collections.abc import Callable, Mapping, Sequence
from typing import Any, Literal

from pydantic import BaseModel, ConfigDict, Field

from app.validation.canonical_validator import ValidationIssue


RepairStopReason = Literal["completed", "no_progress", "round_limit"]


class RepairOperation(BaseModel):
    model_config = ConfigDict(extra="forbid", frozen=True)

    op: Literal["replace"]
    path: str = Field(pattern=r"^/items/[0-9]+/[a-z][a-z0-9_]*$")
    value: Any


class RepairProposal(BaseModel):
    model_config = ConfigDict(extra="forbid", frozen=True)

    operations: tuple[RepairOperation, ...] = Field(min_length=1, max_length=8)


class RepairRequest(BaseModel):
    model_config = ConfigDict(extra="forbid", frozen=True)

    round_number: int = Field(ge=1, le=2)
    issue_ids: tuple[str, ...]
    issue_codes: tuple[str, ...]


class RepairRound(BaseModel):
    model_config = ConfigDict(extra="forbid", frozen=True)

    round_number: int = Field(ge=1, le=2)
    operation_count: int = Field(ge=1, le=8)
    before_issue_hash: str = Field(pattern=r"^[0-9a-f]{64}$")
    after_issue_hash: str = Field(pattern=r"^[0-9a-f]{64}$")
    made_progress: bool


class RepairOutcome(BaseModel):
    model_config = ConfigDict(extra="forbid", frozen=True)

    candidate: dict[str, Any]
    rounds: tuple[RepairRound, ...]
    stop_reason: RepairStopReason
    unresolved_original_conflicts: tuple[ValidationIssue, ...]


PatchProposer = Callable[[RepairRequest], RepairProposal]
CandidateValidator = Callable[[Mapping[str, Any]], Sequence[ValidationIssue]]


def _issue_key(issue: ValidationIssue) -> tuple[str, str, str]:
    return issue.constraint_id, issue.classification, issue.code


def _issue_hash(issues: Sequence[ValidationIssue]) -> str:
    payload = [list(_issue_key(issue)) for issue in sorted(issues, key=_issue_key)]
    return hashlib.sha256(
        json.dumps(payload, separators=(",", ":"), ensure_ascii=True).encode("utf-8")
    ).hexdigest()


def _issue_score(issues: Sequence[ValidationIssue]) -> tuple[int, int, int]:
    return (
        sum(issue.classification == "hard" for issue in issues),
        sum(issue.classification == "warning" for issue in issues),
        sum(issue.classification == "unverified" for issue in issues),
    )


class BoundedLocalRepair:
    """Apply at most two allowlisted leaf replacements and stop on no progress."""

    _ALLOWED_FIELDS = frozenset(
        {
            "cost_minor",
            "end_minute",
            "place_id",
            "start_minute",
            "travel_minutes",
        }
    )

    def repair(
        self,
        *,
        candidate: Mapping[str, Any],
        issues: Sequence[ValidationIssue],
        propose_patch: PatchProposer,
        validate: CandidateValidator,
    ) -> RepairOutcome:
        current = copy.deepcopy(dict(candidate))
        current_issues = tuple(issues)
        original_keys = {_issue_key(issue) for issue in current_issues}
        rounds: list[RepairRound] = []

        for round_number in range(1, 3):
            request = RepairRequest(
                round_number=round_number,
                issue_ids=tuple(issue.constraint_id for issue in current_issues),
                issue_codes=tuple(issue.code for issue in current_issues),
            )
            proposal = propose_patch(request)
            patched = self._apply_local_patch(current, proposal)
            next_issues = tuple(validate(patched))
            before_hash = _issue_hash(current_issues)
            after_hash = _issue_hash(next_issues)
            made_progress = (
                _issue_score(next_issues) < _issue_score(current_issues)
                and after_hash != before_hash
            )
            rounds.append(
                RepairRound(
                    round_number=round_number,
                    operation_count=len(proposal.operations),
                    before_issue_hash=before_hash,
                    after_issue_hash=after_hash,
                    made_progress=made_progress,
                )
            )
            if not made_progress:
                return self._outcome(
                    candidate=current,
                    rounds=rounds,
                    reason="no_progress",
                    current_issues=current_issues,
                    original_keys=original_keys,
                )
            current = patched
            current_issues = next_issues
            if not current_issues:
                return self._outcome(
                    candidate=current,
                    rounds=rounds,
                    reason="completed",
                    current_issues=current_issues,
                    original_keys=original_keys,
                )

        return self._outcome(
            candidate=current,
            rounds=rounds,
            reason="round_limit",
            current_issues=current_issues,
            original_keys=original_keys,
        )

    def _apply_local_patch(
        self, candidate: dict[str, Any], proposal: RepairProposal
    ) -> dict[str, Any]:
        patched = copy.deepcopy(candidate)
        items = patched.get("items")
        if not isinstance(items, list):
            raise ValueError("repair.candidate_items_required")
        seen_paths: set[str] = set()
        for operation in proposal.operations:
            if operation.path in seen_paths:
                raise ValueError("repair.duplicate_path")
            seen_paths.add(operation.path)
            _, root, index_value, field = operation.path.split("/")
            if root != "items" or field not in self._ALLOWED_FIELDS:
                raise ValueError("repair.path_not_allowed")
            index = int(index_value)
            if index >= len(items) or not isinstance(items[index], dict):
                raise ValueError("repair.item_not_found")
            if field not in items[index]:
                raise ValueError("repair.field_not_found")
            items[index][field] = copy.deepcopy(operation.value)
        return patched

    @staticmethod
    def _outcome(
        *,
        candidate: dict[str, Any],
        rounds: Sequence[RepairRound],
        reason: RepairStopReason,
        current_issues: Sequence[ValidationIssue],
        original_keys: set[tuple[str, str, str]],
    ) -> RepairOutcome:
        unresolved = tuple(
            sorted(
                (
                    issue
                    for issue in current_issues
                    if _issue_key(issue) in original_keys
                ),
                key=_issue_key,
            )
        )
        return RepairOutcome(
            candidate=candidate,
            rounds=tuple(rounds),
            stop_reason=reason,
            unresolved_original_conflicts=unresolved,
        )
