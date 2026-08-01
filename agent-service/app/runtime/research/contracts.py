"""Typed, read-only contracts for bounded Phase 8 research branches."""

from __future__ import annotations

from collections.abc import Mapping
from enum import StrEnum
from typing import Any, Literal, TypeAlias
from uuid import UUID

from pydantic import BaseModel, ConfigDict, Field, ValidationError, field_validator, model_validator


SHA256_PATTERN = r"^[0-9a-f]{64}$"
REFERENCE_PATTERN = r"^[a-z][a-z0-9+.-]*://[^\s]{1,500}$"
CODE_PATTERN = r"^[a-z][a-z0-9_.-]{1,127}$"
_WRITE_KEYS = frozenset(
    {
        "command",
        "domain_command",
        "mutation",
        "production_write",
        "sql",
        "write",
        "write_intent",
    }
)
_WRITE_OPERATION_TOKENS = frozenset(
    {"create", "delete", "insert", "mutate", "patch", "publish", "update", "write"}
)


class ResearchContractError(ValueError):
    """Stable fail-closed error for an unsafe or unsupported research contract."""

    def __init__(self, code: str = "research_contract.invalid") -> None:
        self.code = code
        super().__init__(code)


class ResearchContractKind(StrEnum):
    REQUEST = "research_request"
    BUNDLE = "evidence_bundle"
    DECISION = "merge_decision"


class ResearchBranchId(StrEnum):
    A = "branch_a"
    B = "branch_b"


class ReadOperation(StrEnum):
    SEARCH = "evidence.search"
    RETRIEVE = "evidence.retrieve"


class EvidenceAssessment(StrEnum):
    VERIFIED = "verified"
    WARNING = "warning"
    UNVERIFIED = "unverified"


class MergeOutcome(StrEnum):
    MERGED = "merged"
    INSUFFICIENT_EVIDENCE = "insufficient_evidence"
    REJECTED = "rejected"


class ResearchReference(BaseModel):
    """Opaque, content-bound reference; research payloads never embed source bodies."""

    model_config = ConfigDict(extra="forbid", frozen=True)

    kind: Literal["objective", "requirement", "source", "evidence", "candidate"]
    uri: str = Field(pattern=REFERENCE_PATTERN, max_length=512)
    sha256: str = Field(pattern=SHA256_PATTERN)


class ResearchRequest(BaseModel):
    """A single bounded, read-only branch assignment."""

    model_config = ConfigDict(extra="forbid", frozen=True)

    schema_version: Literal["1.0"] = "1.0"
    contract_kind: Literal[ResearchContractKind.REQUEST] = ResearchContractKind.REQUEST
    request_id: UUID
    run_id: UUID
    branch_id: ResearchBranchId
    objective_ref: ResearchReference
    requirement_refs: tuple[ResearchReference, ...] = Field(default=(), max_length=50)
    permission: Literal["read_only"] = "read_only"
    allowed_operations: tuple[ReadOperation, ...] = Field(min_length=1, max_length=2)
    output_contract: Literal["evidence_bundle_v1"] = "evidence_bundle_v1"

    @field_validator("objective_ref")
    @classmethod
    def _objective_kind(cls, value: ResearchReference) -> ResearchReference:
        if value.kind != "objective":
            raise ValueError("research_contract.objective_ref_kind")
        return value

    @field_validator("requirement_refs")
    @classmethod
    def _requirement_kinds(
        cls, value: tuple[ResearchReference, ...]
    ) -> tuple[ResearchReference, ...]:
        if any(reference.kind != "requirement" for reference in value):
            raise ValueError("research_contract.requirement_ref_kind")
        if len({reference.uri for reference in value}) != len(value):
            raise ValueError("research_contract.duplicate_requirement_ref")
        return value

    @field_validator("allowed_operations")
    @classmethod
    def _unique_operations(
        cls, value: tuple[ReadOperation, ...]
    ) -> tuple[ReadOperation, ...]:
        if len(set(value)) != len(value):
            raise ValueError("research_contract.duplicate_operation")
        return value


class ResearchFinding(BaseModel):
    """A coded claim whose support remains external and content-addressed."""

    model_config = ConfigDict(extra="forbid", frozen=True)

    finding_code: str = Field(pattern=CODE_PATTERN, max_length=128)
    assessment: EvidenceAssessment
    evidence_refs: tuple[ResearchReference, ...] = Field(min_length=1, max_length=20)

    @field_validator("evidence_refs")
    @classmethod
    def _evidence_kinds(
        cls, value: tuple[ResearchReference, ...]
    ) -> tuple[ResearchReference, ...]:
        if any(reference.kind not in {"source", "evidence"} for reference in value):
            raise ValueError("research_contract.evidence_ref_kind")
        if len({reference.uri for reference in value}) != len(value):
            raise ValueError("research_contract.duplicate_evidence_ref")
        return value


class EvidenceBundle(BaseModel):
    """Read-only branch output containing references and coded findings only."""

    model_config = ConfigDict(extra="forbid", frozen=True)

    schema_version: Literal["1.0"] = "1.0"
    contract_kind: Literal[ResearchContractKind.BUNDLE] = ResearchContractKind.BUNDLE
    bundle_id: UUID
    request_id: UUID
    run_id: UUID
    branch_id: ResearchBranchId
    findings: tuple[ResearchFinding, ...] = Field(max_length=50)
    completion: Literal["complete", "partial"]
    domain_write_authorized: Literal[False] = False

    @field_validator("findings")
    @classmethod
    def _unique_findings(
        cls, value: tuple[ResearchFinding, ...]
    ) -> tuple[ResearchFinding, ...]:
        if len({finding.finding_code for finding in value}) != len(value):
            raise ValueError("research_contract.duplicate_finding")
        return value


class MergeDecision(BaseModel):
    """Deterministic merge disposition; it never grants a domain write."""

    model_config = ConfigDict(extra="forbid", frozen=True)

    schema_version: Literal["1.0"] = "1.0"
    contract_kind: Literal[ResearchContractKind.DECISION] = ResearchContractKind.DECISION
    decision_id: UUID
    run_id: UUID
    bundle_ids: tuple[UUID, ...] = Field(min_length=1, max_length=2)
    outcome: MergeOutcome
    selected_finding_codes: tuple[str, ...] = Field(max_length=100)
    rationale_codes: tuple[str, ...] = Field(min_length=1, max_length=20)
    candidate_ref: ResearchReference | None = None
    domain_write_authorized: Literal[False] = False

    @field_validator("bundle_ids")
    @classmethod
    def _unique_bundles(cls, value: tuple[UUID, ...]) -> tuple[UUID, ...]:
        if len(set(value)) != len(value):
            raise ValueError("research_contract.duplicate_bundle")
        return value

    @field_validator("selected_finding_codes", "rationale_codes")
    @classmethod
    def _unique_codes(cls, value: tuple[str, ...]) -> tuple[str, ...]:
        if len(set(value)) != len(value):
            raise ValueError("research_contract.duplicate_code")
        if any(not code or len(code) > 128 for code in value):
            raise ValueError("research_contract.invalid_code")
        return value

    @model_validator(mode="after")
    def _decision_shape(self) -> MergeDecision:
        if self.candidate_ref is not None and self.candidate_ref.kind != "candidate":
            raise ValueError("research_contract.candidate_ref_kind")
        if self.outcome is MergeOutcome.MERGED:
            if not self.selected_finding_codes or self.candidate_ref is None:
                raise ValueError("research_contract.merged_output_required")
        elif self.selected_finding_codes or self.candidate_ref is not None:
            raise ValueError("research_contract.nonmerge_output_forbidden")
        return self


ResearchContract: TypeAlias = ResearchRequest | EvidenceBundle | MergeDecision

_MODEL_BY_KIND: dict[ResearchContractKind, type[BaseModel]] = {
    ResearchContractKind.REQUEST: ResearchRequest,
    ResearchContractKind.BUNDLE: EvidenceBundle,
    ResearchContractKind.DECISION: MergeDecision,
}


def parse_research_contract(
    payload: Mapping[str, Any],
    *,
    expected_kind: ResearchContractKind | None = None,
) -> ResearchContract:
    """Validate a contract without guessing versions or widening permissions."""

    raw = dict(payload)
    _reject_write_attempt(raw)
    if raw.get("schema_version") != "1.0":
        raise ResearchContractError("research_contract.unknown_version")
    try:
        kind = ResearchContractKind(raw.get("contract_kind"))
    except (TypeError, ValueError) as error:
        raise ResearchContractError("research_contract.unknown_kind") from error
    if expected_kind is not None and kind is not expected_kind:
        raise ResearchContractError("research_contract.kind_mismatch")
    model = _MODEL_BY_KIND[kind]
    try:
        return model.model_validate(raw)  # type: ignore[return-value]
    except ValidationError as error:
        raise ResearchContractError() from error


def _reject_write_attempt(value: Any) -> None:
    if isinstance(value, Mapping):
        for raw_key, child in value.items():
            key = str(raw_key).casefold()
            if key in _WRITE_KEYS:
                raise ResearchContractError("research_contract.write_forbidden")
            if key == "permission" and child != "read_only":
                raise ResearchContractError("research_contract.write_forbidden")
            if key == "domain_write_authorized" and child is not False:
                raise ResearchContractError("research_contract.write_forbidden")
            if key == "allowed_operations" and isinstance(child, (list, tuple)):
                for operation in child:
                    tokens = set(str(operation).casefold().replace("-", ".").split("."))
                    if tokens & _WRITE_OPERATION_TOKENS:
                        raise ResearchContractError("research_contract.write_forbidden")
            _reject_write_attempt(child)
    elif isinstance(value, (list, tuple)):
        for child in value:
            _reject_write_attempt(child)
