"""Behavior-bound Context planning for the itinerary model boundary."""

from __future__ import annotations

import hashlib
import json
import re
from collections.abc import Callable
from dataclasses import dataclass
from enum import StrEnum

from app.runtime.context_compiler import (
    ContextCompiler,
    ContextCompilerError,
    ContextKind,
    ContextSlice,
    TransformRecord,
)
from app.runtime.state import WorkflowStage


SHA256_PATTERN = re.compile(r"^[0-9a-f]{64}$")
CLAIM_ID_PATTERN = re.compile(r"^knowledge_[0-9a-f]{16}$")
ARTIFACT_ID_PATTERN = re.compile(r"^[a-z][a-z0-9_.:\-]{0,127}$")
REFERENCE_PATTERN = re.compile(r"^[a-z][a-z0-9+.-]*://[^\s]{1,500}$")


class ContextArtifactKind(StrEnum):
    TASK_CONTRACT = "task_contract"
    EVIDENCE = "evidence"


class ContextDecisionStatus(StrEnum):
    COMPILED = "compiled"
    BLOCKED = "blocked"


def deterministic_token_count(value: str) -> int:
    """Deterministic conservative estimator bound to the v2 policy identity."""

    encoded = value.encode("utf-8")
    return max(1, (len(encoded) + 3) // 4)


@dataclass(frozen=True, slots=True)
class ContextBudgetEnvelope:
    model_context_tokens: int
    reserved_instruction_tokens: int
    reserved_schema_tokens: int
    reserved_output_tokens: int
    reserved_safety_tokens: int

    def __post_init__(self) -> None:
        values = (
            self.model_context_tokens,
            self.reserved_instruction_tokens,
            self.reserved_schema_tokens,
            self.reserved_output_tokens,
            self.reserved_safety_tokens,
        )
        if any(isinstance(value, bool) or not isinstance(value, int) for value in values):
            raise ValueError("context.budget_invalid")
        if self.model_context_tokens < 1 or any(value < 0 for value in values[1:]):
            raise ValueError("context.budget_invalid")
        if self.working_context_tokens < 1:
            raise ValueError("context.budget_invalid")

    @property
    def working_context_tokens(self) -> int:
        return self.model_context_tokens - sum(
            (
                self.reserved_instruction_tokens,
                self.reserved_schema_tokens,
                self.reserved_output_tokens,
                self.reserved_safety_tokens,
            )
        )


@dataclass(frozen=True, slots=True)
class ContextArtifact:
    artifact_id: str
    kind: ContextArtifactKind
    content: str
    sha256: str
    priority: int
    required: bool
    provenance_ref: str
    claim_ids: tuple[str, ...] = ()

    def __post_init__(self) -> None:
        content_digest = hashlib.sha256(self.content.encode("utf-8")).hexdigest()
        if (
            ARTIFACT_ID_PATTERN.fullmatch(self.artifact_id) is None
            or not self.content
            or len(self.content) > 6_000
            or SHA256_PATTERN.fullmatch(self.sha256) is None
            or self.sha256 != content_digest
            or isinstance(self.priority, bool)
            or not isinstance(self.priority, int)
            or not 0 <= self.priority <= 100
            or not isinstance(self.required, bool)
            or REFERENCE_PATTERN.fullmatch(self.provenance_ref) is None
            or len(self.claim_ids) != len(set(self.claim_ids))
            or tuple(sorted(self.claim_ids)) != self.claim_ids
            or any(CLAIM_ID_PATTERN.fullmatch(value) is None for value in self.claim_ids)
            or (
                self.kind is ContextArtifactKind.TASK_CONTRACT
                and bool(self.claim_ids)
            )
        ):
            raise ValueError("context.artifact_invalid")

    def canonical_json(self) -> str:
        return json.dumps(
            {
                "artifact_id": self.artifact_id,
                "claim_ids": list(self.claim_ids),
                "content": self.content,
                "kind": self.kind.value,
                "provenance_ref": self.provenance_ref,
                "required": self.required,
                "sha256": self.sha256,
            },
            allow_nan=False,
            ensure_ascii=False,
            separators=(",", ":"),
            sort_keys=True,
        )


@dataclass(frozen=True, slots=True)
class ContextPlannerPolicy:
    policy_id: str
    tokenizer_id: str
    supported_stages: tuple[WorkflowStage, ...]
    required_kinds: tuple[ContextArtifactKind, ...]
    schema_version: str = "2.0"

    def __post_init__(self) -> None:
        if (
            ARTIFACT_ID_PATTERN.fullmatch(self.policy_id) is None
            or ARTIFACT_ID_PATTERN.fullmatch(self.tokenizer_id) is None
            or not self.supported_stages
            or len(self.supported_stages) != len(set(self.supported_stages))
            or not self.required_kinds
            or len(self.required_kinds) != len(set(self.required_kinds))
            or self.schema_version != "2.0"
        ):
            raise ValueError("context.policy_invalid")

    @property
    def digest(self) -> str:
        canonical = json.dumps(
            {
                "policy_id": self.policy_id,
                "required_kinds": sorted(item.value for item in self.required_kinds),
                "schema_version": self.schema_version,
                "supported_stages": sorted(item.value for item in self.supported_stages),
                "tokenizer_id": self.tokenizer_id,
            },
            ensure_ascii=False,
            separators=(",", ":"),
            sort_keys=True,
        ).encode("utf-8")
        return hashlib.sha256(canonical).hexdigest()


DEFAULT_CONTEXT_POLICY = ContextPlannerPolicy(
    policy_id="itinerary-compose-v2",
    tokenizer_id="utf8-ceil-div4-v1",
    supported_stages=(WorkflowStage.COMPOSE,),
    required_kinds=(ContextArtifactKind.TASK_CONTRACT,),
)


@dataclass(frozen=True, slots=True)
class ContextPlanRequest:
    stage: WorkflowStage
    policy_digest: str
    artifacts: tuple[ContextArtifact, ...]
    budget: ContextBudgetEnvelope


@dataclass(frozen=True, slots=True)
class ContextDecision:
    status: ContextDecisionStatus
    policy_digest: str
    stage: WorkflowStage
    reason_code: str | None
    working_context: str | None
    included_artifact_ids: tuple[str, ...]
    omitted_artifact_ids: tuple[str, ...]
    included_claim_ids: tuple[str, ...]
    transform_log: tuple[TransformRecord, ...]
    token_count: int
    token_limit: int
    digest: str


TokenCounter = Callable[[str], int]


class ContextPlanner:
    """Compile only Behavior-bound artifacts into one bounded Working Context."""

    def __init__(
        self,
        policy: ContextPlannerPolicy = DEFAULT_CONTEXT_POLICY,
        *,
        token_counter: TokenCounter = deterministic_token_count,
    ) -> None:
        self._policy = policy
        self._token_counter = token_counter
        self._compiler = ContextCompiler(token_counter)

    @property
    def policy_digest(self) -> str:
        return self._policy.digest

    @property
    def policy_id(self) -> str:
        return self._policy.policy_id

    def plan(self, request: ContextPlanRequest) -> ContextDecision:
        if request.policy_digest != self.policy_digest:
            return self._blocked(request, "context.policy_mismatch")
        if request.stage not in self._policy.supported_stages:
            return self._blocked(request, "context.stage_unsupported")
        artifact_ids = tuple(item.artifact_id for item in request.artifacts)
        kinds = {item.kind for item in request.artifacts}
        if (
            not request.artifacts
            or len(artifact_ids) != len(set(artifact_ids))
            or not set(self._policy.required_kinds).issubset(kinds)
        ):
            return self._blocked(request, "context.input_invalid")

        rendered = {item.artifact_id: item.canonical_json() for item in request.artifacts}
        empty_wrapper = self._working_context(request.stage, ())
        try:
            wrapper_tokens = self._count_tokens(empty_wrapper)
        except ContextCompilerError as error:
            return self._blocked(request, error.code)
        token_limit = request.budget.working_context_tokens - wrapper_tokens
        if token_limit < 1:
            return self._blocked(request, "context.required_slice_missing")
        kind_mapping = {
            ContextArtifactKind.TASK_CONTRACT: ContextKind.REQUEST,
            ContextArtifactKind.EVIDENCE: ContextKind.TOOL_EVIDENCE,
        }
        required_kinds = frozenset(kind_mapping[item] for item in self._policy.required_kinds)
        try:
            compiled = self._compiler.compile(
                (
                    ContextSlice(
                        slice_id=item.artifact_id,
                        kind=kind_mapping[item.kind],
                        content=rendered[item.artifact_id],
                        priority=item.priority,
                        required=item.required,
                    )
                    for item in request.artifacts
                ),
                token_limit=token_limit,
                required_kinds=required_kinds,
            )
            working_context = self._working_context(
                request.stage,
                tuple(item.content for item in compiled.slices),
            )
            actual_tokens = self._count_tokens(working_context)
        except ContextCompilerError as error:
            return self._blocked(request, error.code)
        if actual_tokens > request.budget.working_context_tokens:
            return self._blocked(request, "context.required_slice_missing")

        by_id = {item.artifact_id: item for item in request.artifacts}
        included_ids = tuple(item.slice_id for item in compiled.slices)
        omitted_ids = tuple(
            item.slice_id for item in compiled.transform_log if item.action == "omitted"
        )
        included_claim_ids = tuple(
            sorted(
                {
                    claim_id
                    for artifact_id in included_ids
                    for claim_id in by_id[artifact_id].claim_ids
                }
            )
        )
        return ContextDecision(
            status=ContextDecisionStatus.COMPILED,
            policy_digest=self.policy_digest,
            stage=request.stage,
            reason_code=None,
            working_context=working_context,
            included_artifact_ids=included_ids,
            omitted_artifact_ids=omitted_ids,
            included_claim_ids=included_claim_ids,
            transform_log=compiled.transform_log,
            token_count=actual_tokens,
            token_limit=request.budget.working_context_tokens,
            digest=self._decision_digest(
                status=ContextDecisionStatus.COMPILED,
                stage=request.stage,
                reason_code=None,
                working_context=working_context,
                included_ids=included_ids,
                omitted_ids=omitted_ids,
                included_claim_ids=included_claim_ids,
            ),
        )

    def _blocked(self, request: ContextPlanRequest, reason_code: str) -> ContextDecision:
        return ContextDecision(
            status=ContextDecisionStatus.BLOCKED,
            policy_digest=self.policy_digest,
            stage=request.stage,
            reason_code=reason_code,
            working_context=None,
            included_artifact_ids=(),
            omitted_artifact_ids=(),
            included_claim_ids=(),
            transform_log=(),
            token_count=0,
            token_limit=request.budget.working_context_tokens,
            digest=self._decision_digest(
                status=ContextDecisionStatus.BLOCKED,
                stage=request.stage,
                reason_code=reason_code,
                working_context=None,
                included_ids=(),
                omitted_ids=(),
                included_claim_ids=(),
            ),
        )

    def _count_tokens(self, value: str) -> int:
        try:
            count = self._token_counter(value)
        except Exception as error:
            raise ContextCompilerError("context.tokenizer_unavailable") from error
        if isinstance(count, bool) or not isinstance(count, int) or count < 1:
            raise ContextCompilerError("context.tokenizer_unavailable")
        return count

    @staticmethod
    def _working_context(stage: WorkflowStage, artifacts: tuple[str, ...]) -> str:
        return (
            '{"artifacts":['
            + ",".join(artifacts)
            + '],"schema_version":"2.0","stage":'
            + json.dumps(stage.value)
            + "}"
        )

    def _decision_digest(
        self,
        *,
        status: ContextDecisionStatus,
        stage: WorkflowStage,
        reason_code: str | None,
        working_context: str | None,
        included_ids: tuple[str, ...],
        omitted_ids: tuple[str, ...],
        included_claim_ids: tuple[str, ...],
    ) -> str:
        canonical = json.dumps(
            {
                "included_artifact_ids": list(included_ids),
                "included_claim_ids": list(included_claim_ids),
                "omitted_artifact_ids": list(omitted_ids),
                "policy_digest": self.policy_digest,
                "reason_code": reason_code,
                "stage": stage.value,
                "status": status.value,
                "working_context_sha256": (
                    hashlib.sha256(working_context.encode("utf-8")).hexdigest()
                    if working_context is not None
                    else None
                ),
            },
            ensure_ascii=False,
            separators=(",", ":"),
            sort_keys=True,
        ).encode("utf-8")
        return hashlib.sha256(canonical).hexdigest()
