"""Versioned, typed interrupt contracts with fail-closed parsing."""

from __future__ import annotations

import json
import re
from collections.abc import Mapping
from datetime import datetime
from enum import StrEnum
from typing import Annotated, Any, Literal
from uuid import UUID

from pydantic import BaseModel, ConfigDict, Field, TypeAdapter, ValidationError, field_validator


REF_PATTERN = r"^[a-z][a-z0-9+.-]*://[^\s]{1,500}$"
KEY_PATTERN = r"^[a-z][a-z0-9_.-]{1,127}$"


class InterruptContractError(ValueError):
    """Stable error returned before an invalid interrupt can be persisted."""

    def __init__(self, code: str = "interrupt.invalid") -> None:
        self.code = code
        super().__init__(code)


class MissingInfoInputKind(StrEnum):
    TEXT = "text"
    DATE = "date"
    TIME = "time"
    LOCATION = "location"
    CHOICE = "choice"


class RiskSeverity(StrEnum):
    LOW = "low"
    MEDIUM = "medium"
    HIGH = "high"


class MissingInfoRequest(BaseModel):
    model_config = ConfigDict(extra="forbid", frozen=True)

    field_key: str = Field(pattern=KEY_PATTERN, max_length=128)
    label_key: str = Field(pattern=KEY_PATTERN, max_length=128)
    input_kind: MissingInfoInputKind
    required: Literal[True] = True
    option_keys: tuple[str, ...] = Field(default=(), max_length=20)

    @field_validator("option_keys")
    @classmethod
    def _choice_options_are_typed(
        cls, value: tuple[str, ...], info: Any
    ) -> tuple[str, ...]:
        input_kind = info.data.get("input_kind")
        if input_kind == MissingInfoInputKind.CHOICE:
            if not value or len(set(value)) != len(value):
                raise ValueError("interrupt.choice_options_invalid")
        elif value:
            raise ValueError("interrupt.non_choice_options_forbidden")
        if any(not option or len(option) > 128 for option in value):
            raise ValueError("interrupt.choice_options_invalid")
        return value


class _InterruptBase(BaseModel):
    model_config = ConfigDict(extra="forbid", frozen=True)

    schema_version: Literal["1.0"] = "1.0"
    interrupt_id: UUID
    run_id: UUID
    created_at: datetime
    ui_message_key: str = Field(pattern=KEY_PATTERN, max_length=128)

    @field_validator("created_at")
    @classmethod
    def _created_at_has_timezone(cls, value: datetime) -> datetime:
        if value.tzinfo is None or value.utcoffset() is None:
            raise ValueError("interrupt.created_at_timezone_required")
        return value


class MissingInfoInterrupt(_InterruptBase):
    kind: Literal["missing_info"]
    requests: tuple[MissingInfoRequest, ...] = Field(min_length=1, max_length=20)


class RiskConfirmationInterrupt(_InterruptBase):
    kind: Literal["risk_confirmation"]
    risk_code: str = Field(pattern=KEY_PATTERN, max_length=128)
    severity: RiskSeverity
    evidence_refs: tuple[str, ...] = Field(min_length=1, max_length=20)
    explicit_confirmation_required: Literal[True] = True

    @field_validator("evidence_refs")
    @classmethod
    def _evidence_refs_are_safe(cls, value: tuple[str, ...]) -> tuple[str, ...]:
        if len(set(value)) != len(value):
            raise ValueError("interrupt.duplicate_evidence_ref")
        for reference in value:
            if len(reference) > 512:
                raise ValueError("interrupt.evidence_ref_invalid")
            if re.fullmatch(REF_PATTERN, reference) is None:
                raise ValueError("interrupt.evidence_ref_invalid")
        return value


class ApprovalInterrupt(_InterruptBase):
    kind: Literal["approval"]
    action_code: str = Field(pattern=KEY_PATTERN, max_length=128)
    resource_ref: str = Field(pattern=REF_PATTERN, max_length=512)
    diff_ref: str = Field(pattern=REF_PATTERN, max_length=512)
    explicit_approval_required: Literal[True] = True
    audit_receipt_required: Literal[True] = True


Interrupt = Annotated[
    MissingInfoInterrupt | RiskConfirmationInterrupt | ApprovalInterrupt,
    Field(discriminator="kind"),
]
_INTERRUPT_ADAPTER = TypeAdapter(Interrupt)


def parse_interrupt(payload: Mapping[str, Any]) -> Interrupt:
    """Parse a supported interrupt version without performing any write."""

    if payload.get("schema_version") != "1.0":
        raise InterruptContractError("schema.unsupported_version")
    try:
        return _INTERRUPT_ADAPTER.validate_python(dict(payload))
    except (TypeError, ValueError, ValidationError) as error:
        raise InterruptContractError() from error


def interrupt_json(value: Interrupt) -> str:
    """Return a deterministic public payload with no opaque prompt or reasoning."""

    payload = _INTERRUPT_ADAPTER.dump_python(value, mode="json")
    return json.dumps(payload, sort_keys=True, separators=(",", ":"), ensure_ascii=False)
