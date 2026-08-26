"""Canonical, content-addressed itinerary Task Contract."""

from __future__ import annotations

import hashlib
import re
from datetime import date, timedelta
from typing import Annotated, Any, Literal

from pydantic import (
    BaseModel,
    ConfigDict,
    Field,
    StringConstraints,
    ValidationError,
)

from app.runtime.behavior_manifest import canonicalize_jcs
from app.runtime.state import StateReference


INPUT_REF_PATTERN = re.compile(r"^job-input://sha256/([0-9a-f]{64})$")
SAFE_PLACE = Annotated[
    str,
    StringConstraints(strip_whitespace=True, min_length=1, max_length=160),
]
SAFE_CONSTRAINT = Annotated[
    str,
    StringConstraints(strip_whitespace=True, min_length=1, max_length=160),
]

HARD_CONSTRAINT_SEMANTICS = {
    "no_overlap": (
        "within each day, every item's start_minute must be greater than or equal "
        "to the previous item's start_minute plus duration_minutes"
    ),
    "no_late_night": (
        "every item's start_minute plus duration_minutes must be at most 1320"
    ),
    "daylight_only": (
        "every item's start_minute must be at least 360 and start_minute plus "
        "duration_minutes must be at most 1200"
    ),
    "morning_start": (
        "each day must contain at least one item whose start_minute is at most 600"
    ),
    "max_3_items_per_day": "each day must contain at most three items",
}
UNIVERSAL_MACHINE_SEMANTICS = {
    "day_end_within_1440": (
        "every item must end at or before local minute 1440"
    ),
    "item_id_template": (
        "item_d{day_number}_{within-day ordinal starting at 1}"
    ),
    "unique_item_ids": "every item_id must be unique across all days",
}


class TaskContractError(ValueError):
    def __init__(self, code: str) -> None:
        self.code = code
        super().__init__(code)


class _ItineraryInput(BaseModel):
    model_config = ConfigDict(extra="forbid", frozen=True)

    schema_version: Literal["1.0"] = "1.0"
    origin: SAFE_PLACE
    destination: SAFE_PLACE
    starts_on: date
    days: int = Field(ge=1, le=31)
    budget_minor: int = Field(ge=0, le=1_000_000_000)
    currency: str = Field(pattern=r"^[A-Z]{3}$")
    locale: str = Field(pattern=r"^[a-z]{2}(?:-[A-Z]{2})?$")
    timezone: str = Field(
        min_length=1,
        max_length=64,
        pattern=r"^[A-Za-z0-9_+./-]+$",
    )
    hard_constraints: tuple[SAFE_CONSTRAINT, ...] = Field(
        default=(),
        max_length=20,
    )


class MachineHardSemantic(BaseModel):
    model_config = ConfigDict(extra="forbid", frozen=True)

    code: str = Field(pattern=r"^[a-z][a-z0-9_]{0,79}$")
    semantics: str = Field(min_length=1, max_length=300)


class ItineraryTaskContract(BaseModel):
    """Instruction-free business facts derived from one authorized input ref."""

    model_config = ConfigDict(extra="forbid", frozen=True)

    schema_version: Literal["2.0"] = "2.0"
    objective: Literal["build_travel_itinerary"] = "build_travel_itinerary"
    source_ref: str = Field(pattern=r"^job-input://sha256/[0-9a-f]{64}$")
    source_sha256: str = Field(pattern=r"^[0-9a-f]{64}$")
    origin: SAFE_PLACE
    destination: SAFE_PLACE
    starts_on: date
    ends_on: date
    days: int = Field(ge=1, le=31)
    budget_minor: int = Field(ge=0, le=1_000_000_000)
    currency: str = Field(pattern=r"^[A-Z]{3}$")
    locale: str = Field(pattern=r"^[a-z]{2}(?:-[A-Z]{2})?$")
    timezone: str = Field(
        min_length=1,
        max_length=64,
        pattern=r"^[A-Za-z0-9_+./-]+$",
    )
    machine_semantics: tuple[MachineHardSemantic, ...]
    hard_semantics: tuple[MachineHardSemantic, ...]
    untrusted_data_fields: tuple[Literal["origin", "destination"], ...] = (
        "origin",
        "destination",
    )

    @property
    def canonical_bytes(self) -> bytes:
        return canonicalize_jcs(self.model_dump(mode="json"))

    @property
    def canonical_json(self) -> str:
        return self.canonical_bytes.decode("utf-8")

    @property
    def sha256(self) -> str:
        return hashlib.sha256(self.canonical_bytes).hexdigest()

    @property
    def reference(self) -> StateReference:
        return StateReference(
            kind="requirement",
            uri=f"context://task-contract/sha256/{self.sha256}",
            sha256=self.sha256,
        )


class ItineraryPlanIntent(BaseModel):
    """Deterministic execution intent; never a hidden natural-language plan."""

    model_config = ConfigDict(extra="forbid", frozen=True)

    schema_version: Literal["1.0"] = "1.0"
    task_contract_sha256: str = Field(pattern=r"^[0-9a-f]{64}$")
    requested_days: int = Field(ge=1, le=31)
    evidence_mode: Literal["authorized_optional", "disabled"]
    logical_model_call_limit: Literal[1] = 1
    output_kind: Literal["validated_itinerary"] = "validated_itinerary"

    @property
    def canonical_bytes(self) -> bytes:
        return canonicalize_jcs(self.model_dump(mode="json"))

    @property
    def canonical_json(self) -> str:
        return self.canonical_bytes.decode("utf-8")

    @property
    def sha256(self) -> str:
        return hashlib.sha256(self.canonical_bytes).hexdigest()

    @property
    def reference(self) -> StateReference:
        return StateReference(
            kind="requirement",
            uri=f"context://plan-intent/sha256/{self.sha256}",
            sha256=self.sha256,
        )


def build_itinerary_plan_intent(
    task_contract: ItineraryTaskContract,
    *,
    evidence_enabled: bool,
) -> ItineraryPlanIntent:
    return ItineraryPlanIntent(
        task_contract_sha256=task_contract.sha256,
        requested_days=task_contract.days,
        evidence_mode=("authorized_optional" if evidence_enabled else "disabled"),
    )


def build_itinerary_task_contract(
    *,
    structured_input: dict[str, Any],
    input_ref: str,
    input_sha256: str,
) -> ItineraryTaskContract:
    match = INPUT_REF_PATTERN.fullmatch(input_ref)
    if match is None or match.group(1) != input_sha256:
        raise TaskContractError("task_contract.input_invalid")
    try:
        source = _ItineraryInput.model_validate(structured_input)
    except (TypeError, ValueError, ValidationError) as error:
        raise TaskContractError("task_contract.input_invalid") from error
    constraint_codes = tuple(source.hard_constraints)
    if len(constraint_codes) != len(set(constraint_codes)):
        raise TaskContractError("task_contract.input_invalid")
    unknown = set(constraint_codes) - set(HARD_CONSTRAINT_SEMANTICS)
    if unknown:
        raise TaskContractError("task_contract.constraint_unknown")
    semantics = tuple(
        MachineHardSemantic(
            code=code,
            semantics=HARD_CONSTRAINT_SEMANTICS[code],
        )
        for code in sorted(constraint_codes)
    )
    return ItineraryTaskContract(
        source_ref=input_ref,
        source_sha256=input_sha256,
        origin=source.origin,
        destination=source.destination,
        starts_on=source.starts_on,
        ends_on=source.starts_on + timedelta(days=source.days - 1),
        days=source.days,
        budget_minor=source.budget_minor,
        currency=source.currency,
        locale=source.locale,
        timezone=source.timezone,
        machine_semantics=tuple(
            MachineHardSemantic(code=code, semantics=semantics)
            for code, semantics in sorted(UNIVERSAL_MACHINE_SEMANTICS.items())
        ),
        hard_semantics=semantics,
    )
