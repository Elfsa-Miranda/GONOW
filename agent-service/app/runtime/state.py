"""Typed, checkpoint-safe state and fail-closed state-delta validation."""

from __future__ import annotations

import json
from collections.abc import Callable, Mapping
from enum import StrEnum
from typing import Any, Literal
from uuid import UUID

from pydantic import BaseModel, ConfigDict, Field, ValidationError, field_validator


FORBIDDEN_STATE_KEYS = frozenset(
    {
        "api_key",
        "client",
        "connection",
        "credential",
        "model_client",
        "prompt",
        "prompt_body",
        "provider",
        "reasoning",
        "response_body",
        "secret",
        "token",
        "transcript",
    }
)
SHA256_PATTERN = r"^[0-9a-f]{64}$"
REF_PATTERN = r"^[a-z][a-z0-9+.-]*://[^\s]{1,500}$"


class StateContractError(ValueError):
    """Stable fail-closed error for unsafe or invalid state deltas."""

    def __init__(self, code: str = "state.invalid_delta") -> None:
        self.code = code
        super().__init__(code)


class WorkflowStage(StrEnum):
    INTAKE = "intake"
    PLAN = "plan"
    EVIDENCE = "evidence"
    COMPOSE = "compose"
    VALIDATE = "validate"
    COMPLETE = "complete"
    BLOCKED = "blocked"


class StateReference(BaseModel):
    """Content-addressed or opaque reference; never an embedded body."""

    model_config = ConfigDict(extra="forbid", frozen=True)

    kind: Literal["goal", "requirement", "evidence", "issue", "candidate", "checkpoint"]
    uri: str = Field(pattern=REF_PATTERN, max_length=512)
    sha256: str = Field(pattern=SHA256_PATTERN)


class BudgetSnapshot(BaseModel):
    """Persisted counters only; policy and clients remain in runtime context."""

    model_config = ConfigDict(extra="forbid", frozen=True)

    remaining_model_calls: int = Field(ge=0)
    remaining_tool_calls: int = Field(ge=0)
    remaining_tokens: int = Field(ge=0)


class GoNowAgentState(BaseModel):
    """Serializable business facts and immutable references for a single Run."""

    model_config = ConfigDict(extra="forbid", frozen=True)

    schema_version: Literal["1.0"] = "1.0"
    run_id: UUID
    thread_id: UUID
    tenant_id: UUID
    principal_ref: str = Field(pattern=r"^principal://[^\s]{1,240}$", max_length=256)
    behavior_release_id: UUID
    behavior_digest: str = Field(pattern=SHA256_PATTERN)
    goal_ref: StateReference
    hard_requirement_refs: tuple[StateReference, ...] = ()
    evidence_refs: tuple[StateReference, ...] = ()
    issue_refs: tuple[StateReference, ...] = ()
    candidate_ref: StateReference | None = None
    workflow_stage: WorkflowStage = WorkflowStage.INTAKE
    step_count: int = Field(default=0, ge=0)
    model_call_count: int = Field(default=0, ge=0)
    tool_call_count: int = Field(default=0, ge=0)
    repair_rounds: int = Field(default=0, ge=0, le=2)
    no_progress_rounds: int = Field(default=0, ge=0)
    budget: BudgetSnapshot

    @field_validator(
        "goal_ref", "hard_requirement_refs", "evidence_refs", "issue_refs", "candidate_ref"
    )
    @classmethod
    def _reference_kinds_match_fields(cls, value: Any, info: Any) -> Any:
        if value is None:
            return value
        expected = {
            "goal_ref": "goal",
            "hard_requirement_refs": "requirement",
            "evidence_refs": "evidence",
            "issue_refs": "issue",
            "candidate_ref": "candidate",
        }[info.field_name]
        references = value if isinstance(value, tuple) else (value,)
        if any(reference.kind != expected for reference in references):
            raise ValueError("state.reference_kind_mismatch")
        return value

    def checkpoint_dict(self) -> dict[str, Any]:
        """Return JSON-native state with no runtime dependency surface."""

        payload = self.model_dump(mode="json", exclude_none=False)
        _reject_forbidden_keys(payload)
        return payload

    def checkpoint_json(self) -> str:
        return json.dumps(
            self.checkpoint_dict(), sort_keys=True, separators=(",", ":"), ensure_ascii=False
        )

    @classmethod
    def from_checkpoint(cls, payload: Mapping[str, Any]) -> GoNowAgentState:
        _reject_forbidden_keys(payload)
        try:
            return cls.model_validate(dict(payload))
        except ValidationError as error:
            raise StateContractError() from error


class StateDelta(BaseModel):
    """Only fields that a graph node is authorized to propose."""

    model_config = ConfigDict(extra="forbid", frozen=True)

    evidence_refs: tuple[StateReference, ...] | None = None
    issue_refs: tuple[StateReference, ...] | None = None
    candidate_ref: StateReference | None = None
    workflow_stage: WorkflowStage | None = None
    step_count: int | None = Field(default=None, ge=0)
    model_call_count: int | None = Field(default=None, ge=0)
    tool_call_count: int | None = Field(default=None, ge=0)
    repair_rounds: int | None = Field(default=None, ge=0, le=2)
    no_progress_rounds: int | None = Field(default=None, ge=0)
    budget: BudgetSnapshot | None = None


def _reject_forbidden_keys(value: Any) -> None:
    if isinstance(value, Mapping):
        for raw_key, child in value.items():
            key = str(raw_key).casefold()
            if key in FORBIDDEN_STATE_KEYS or any(
                token in key for token in ("secret", "credential", "reasoning", "transcript")
            ):
                raise StateContractError()
            _reject_forbidden_keys(child)
    elif isinstance(value, (list, tuple)):
        for child in value:
            _reject_forbidden_keys(child)


SchemaValidator = Callable[[dict[str, Any]], None]


class StateGuard:
    """Validate a node delta before it can replace checkpoint state."""

    def __init__(self, schema_validator: SchemaValidator | None = None) -> None:
        self._schema_validator = schema_validator or (lambda _: None)

    @classmethod
    def unavailable(cls) -> StateGuard:
        def reject(_: dict[str, Any]) -> None:
            raise RuntimeError("schema dependency unavailable")

        return cls(reject)

    def apply(self, before: GoNowAgentState, raw_delta: Mapping[str, Any]) -> GoNowAgentState:
        try:
            _reject_forbidden_keys(raw_delta)
            delta = StateDelta.model_validate(dict(raw_delta))
            changes = delta.model_dump(exclude_none=True)
            candidate_payload = before.checkpoint_dict()
            candidate_payload.update(changes)
            self._schema_validator(candidate_payload)
            candidate = GoNowAgentState.from_checkpoint(candidate_payload)
            self._assert_monotonic(before, candidate)
            return candidate
        except StateContractError:
            raise
        except (RuntimeError, TypeError, ValueError, ValidationError) as error:
            raise StateContractError() from error

    @staticmethod
    def _assert_monotonic(before: GoNowAgentState, after: GoNowAgentState) -> None:
        for field_name in (
            "step_count",
            "model_call_count",
            "tool_call_count",
            "repair_rounds",
            "no_progress_rounds",
        ):
            if getattr(after, field_name) < getattr(before, field_name):
                raise StateContractError()
