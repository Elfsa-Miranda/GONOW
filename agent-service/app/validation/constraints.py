"""Typed, deterministic planning constraints for the Phase 7 validator."""

from __future__ import annotations

from typing import Annotated, Literal, Union

from pydantic import BaseModel, ConfigDict, Field, TypeAdapter, model_validator


class ConstraintContractError(ValueError):
    def __init__(self, code: str) -> None:
        self.code = code
        super().__init__(code)


class ConstraintSource(BaseModel):
    model_config = ConfigDict(extra="forbid", frozen=True)

    kind: Literal["user", "verified_tool", "approved_profile"]
    source_id: str = Field(pattern=r"^src_[a-z0-9_-]{1,80}$")
    evidence_status: Literal["self_asserted", "verified"]
    evidence_ref: str | None = Field(default=None, pattern=r"^ev_[a-z0-9_-]{1,120}$")

    @model_validator(mode="after")
    def require_verified_tool_evidence(self) -> ConstraintSource:
        if self.kind == "verified_tool" and (
            self.evidence_status != "verified" or self.evidence_ref is None
        ):
            raise ConstraintContractError("constraint.verified_source_required")
        return self


class ConstraintBase(BaseModel):
    model_config = ConfigDict(extra="forbid", frozen=True)

    constraint_id: str = Field(pattern=r"^constraint_[a-z0-9_-]{1,80}$")
    priority: Literal["hard", "preference"]
    source: ConstraintSource
    description: str = Field(min_length=1, max_length=240)


class TimeConstraint(ConstraintBase):
    kind: Literal["time"]
    day_number: int = Field(ge=1, le=31)
    start_minute: int = Field(ge=0, le=1_439)
    end_minute: int = Field(ge=1, le=1_440)

    @model_validator(mode="after")
    def require_forward_window(self) -> TimeConstraint:
        if self.start_minute >= self.end_minute:
            raise ConstraintContractError("constraint.time_window_invalid")
        return self


class CommuteConstraint(ConstraintBase):
    kind: Literal["commute"]
    from_place_id: str = Field(pattern=r"^place_[a-z0-9_-]{1,80}$")
    to_place_id: str = Field(pattern=r"^place_[a-z0-9_-]{1,80}$")
    max_minutes: int = Field(ge=0, le=480)
    allowed_modes: tuple[Literal["walk", "transit", "taxi", "drive"], ...] = Field(
        min_length=1, max_length=4
    )

    @model_validator(mode="after")
    def require_distinct_places(self) -> CommuteConstraint:
        if self.from_place_id == self.to_place_id:
            raise ConstraintContractError("constraint.commute_places_equal")
        return self


class OpeningHoursConstraint(ConstraintBase):
    kind: Literal["opening_hours"]
    place_id: str = Field(pattern=r"^place_[a-z0-9_-]{1,80}$")
    day_number: int = Field(ge=1, le=31)
    open_minute: int = Field(ge=0, le=1_439)
    close_minute: int = Field(ge=1, le=1_440)

    @model_validator(mode="after")
    def require_verified_forward_window(self) -> OpeningHoursConstraint:
        if self.source.kind != "verified_tool":
            raise ConstraintContractError("constraint.opening_hours_unverified")
        if self.open_minute >= self.close_minute:
            raise ConstraintContractError("constraint.opening_window_invalid")
        return self


class BudgetConstraint(ConstraintBase):
    kind: Literal["budget"]
    currency: str = Field(pattern=r"^[A-Z]{3}$")
    min_minor: int = Field(ge=0, le=1_000_000_000)
    max_minor: int = Field(ge=0, le=1_000_000_000)

    @model_validator(mode="after")
    def require_ordered_budget(self) -> BudgetConstraint:
        if self.min_minor > self.max_minor:
            raise ConstraintContractError("constraint.budget_range_invalid")
        return self


class PreferenceConstraint(ConstraintBase):
    kind: Literal["preference"]
    priority: Literal["preference"]
    preference_key: Literal["accessibility", "pace", "cuisine", "lodging", "activity"]
    preference_value: str = Field(min_length=1, max_length=80)
    weight: int = Field(ge=1, le=5)


Constraint = Annotated[
    Union[
        TimeConstraint,
        CommuteConstraint,
        OpeningHoursConstraint,
        BudgetConstraint,
        PreferenceConstraint,
    ],
    Field(discriminator="kind"),
]


class ConstraintEnvelope(BaseModel):
    model_config = ConfigDict(extra="forbid", frozen=True)

    schema_version: Literal["1.0"]
    constraints: tuple[Constraint, ...] = Field(min_length=1, max_length=100)

    @model_validator(mode="after")
    def require_unique_ids(self) -> ConstraintEnvelope:
        ids = [constraint.constraint_id for constraint in self.constraints]
        if len(ids) != len(set(ids)):
            raise ConstraintContractError("constraint.id_duplicate")
        return self


CONSTRAINT_ADAPTER = TypeAdapter(Constraint)
