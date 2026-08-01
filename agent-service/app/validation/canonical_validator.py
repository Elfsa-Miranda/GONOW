"""Deterministic classification of typed itinerary constraints."""

from __future__ import annotations

from typing import Literal

from pydantic import BaseModel, ConfigDict, Field, model_validator

from app.validation.constraints import (
    BudgetConstraint,
    CommuteConstraint,
    ConstraintEnvelope,
    OpeningHoursConstraint,
    PreferenceConstraint,
    TimeConstraint,
)


Classification = Literal["hard", "warning", "unverified", "verified"]
IssueClassification = Literal["hard", "warning", "unverified"]
TravelMode = Literal["walk", "transit", "taxi", "drive"]
EvidenceState = Literal["verified", "stale", "missing"]


class TimeObservation(BaseModel):
    model_config = ConfigDict(extra="forbid", frozen=True)

    constraint_id: str
    day_number: int = Field(ge=1, le=31)
    start_minute: int = Field(ge=0, le=1_439)
    end_minute: int = Field(ge=1, le=1_440)


class CommuteObservation(BaseModel):
    model_config = ConfigDict(extra="forbid", frozen=True)

    constraint_id: str
    minutes: int | None = Field(default=None, ge=0, le=1_440)
    mode: TravelMode | None = None


class OpeningHoursObservation(BaseModel):
    model_config = ConfigDict(extra="forbid", frozen=True)

    constraint_id: str
    is_open: bool | None
    evidence_state: EvidenceState


class BudgetObservation(BaseModel):
    model_config = ConfigDict(extra="forbid", frozen=True)

    constraint_id: str
    currency: str | None = Field(default=None, pattern=r"^[A-Z]{3}$")
    total_minor: int | None = Field(default=None, ge=0, le=1_000_000_000)


class PreferenceObservation(BaseModel):
    model_config = ConfigDict(extra="forbid", frozen=True)

    constraint_id: str
    matched: bool | None


class ItineraryObservations(BaseModel):
    model_config = ConfigDict(extra="forbid", frozen=True)

    time: tuple[TimeObservation, ...] = ()
    commute: tuple[CommuteObservation, ...] = ()
    opening_hours: tuple[OpeningHoursObservation, ...] = ()
    budget: tuple[BudgetObservation, ...] = ()
    preference: tuple[PreferenceObservation, ...] = ()

    @model_validator(mode="after")
    def require_unique_constraint_ids(self) -> ItineraryObservations:
        ids = [
            observation.constraint_id
            for observations in (
                self.time,
                self.commute,
                self.opening_hours,
                self.budget,
                self.preference,
            )
            for observation in observations
        ]
        if len(ids) != len(set(ids)):
            raise ValueError("validation.observation_duplicate")
        return self


class ValidationIssue(BaseModel):
    model_config = ConfigDict(extra="forbid", frozen=True)

    constraint_id: str
    classification: IssueClassification
    code: str = Field(pattern=r"^constraint\.[a-z0-9_.-]{1,100}$")
    explanation_key: str = Field(pattern=r"^validation\.[a-z0-9_.-]{1,120}$")


class CanonicalValidationResult(BaseModel):
    model_config = ConfigDict(extra="forbid", frozen=True)

    schema_version: Literal["1.0"] = "1.0"
    classification: Classification
    issues: tuple[ValidationIssue, ...]
    hard_conflict_count: int = Field(ge=0)
    warning_count: int = Field(ge=0)
    unverified_count: int = Field(ge=0)


def _issue_classification(priority: str) -> Literal["hard", "warning"]:
    return "hard" if priority == "hard" else "warning"


def _issue(
    constraint_id: str,
    classification: IssueClassification,
    code: str,
) -> ValidationIssue:
    return ValidationIssue(
        constraint_id=constraint_id,
        classification=classification,
        code=code,
        explanation_key=f"validation.{code}",
    )


class CanonicalValidator:
    """Pure validator: equal typed inputs always produce equal ordered issues."""

    def validate(
        self,
        *,
        constraints: ConstraintEnvelope,
        observations: ItineraryObservations,
    ) -> CanonicalValidationResult:
        indexes = {
            "time": {item.constraint_id: item for item in observations.time},
            "commute": {item.constraint_id: item for item in observations.commute},
            "opening_hours": {
                item.constraint_id: item for item in observations.opening_hours
            },
            "budget": {item.constraint_id: item for item in observations.budget},
            "preference": {
                item.constraint_id: item for item in observations.preference
            },
        }
        issues: list[ValidationIssue] = []
        for constraint in constraints.constraints:
            observation = indexes[constraint.kind].get(constraint.constraint_id)
            if observation is None:
                issues.append(
                    _issue(
                        constraint.constraint_id,
                        "unverified",
                        "constraint.fact_missing",
                    )
                )
                continue
            if isinstance(constraint, TimeConstraint):
                assert isinstance(observation, TimeObservation)
                if (
                    observation.day_number != constraint.day_number
                    or observation.start_minute < constraint.start_minute
                    or observation.end_minute > constraint.end_minute
                ):
                    issues.append(
                        _issue(
                            constraint.constraint_id,
                            _issue_classification(constraint.priority),
                            "constraint.time_outside_window",
                        )
                    )
            elif isinstance(constraint, CommuteConstraint):
                assert isinstance(observation, CommuteObservation)
                if observation.minutes is None or observation.mode is None:
                    issues.append(
                        _issue(
                            constraint.constraint_id,
                            "unverified",
                            "constraint.commute_unverified",
                        )
                    )
                elif (
                    observation.minutes > constraint.max_minutes
                    or observation.mode not in constraint.allowed_modes
                ):
                    issues.append(
                        _issue(
                            constraint.constraint_id,
                            _issue_classification(constraint.priority),
                            "constraint.commute_exceeded",
                        )
                    )
            elif isinstance(constraint, OpeningHoursConstraint):
                assert isinstance(observation, OpeningHoursObservation)
                if (
                    observation.evidence_state != "verified"
                    or observation.is_open is None
                ):
                    issues.append(
                        _issue(
                            constraint.constraint_id,
                            "unverified",
                            "constraint.opening_hours_unverified",
                        )
                    )
                elif not observation.is_open:
                    issues.append(
                        _issue(
                            constraint.constraint_id,
                            _issue_classification(constraint.priority),
                            "constraint.venue_closed",
                        )
                    )
            elif isinstance(constraint, BudgetConstraint):
                assert isinstance(observation, BudgetObservation)
                if observation.currency is None or observation.total_minor is None:
                    issues.append(
                        _issue(
                            constraint.constraint_id,
                            "unverified",
                            "constraint.budget_unverified",
                        )
                    )
                elif (
                    observation.currency != constraint.currency
                    or observation.total_minor < constraint.min_minor
                    or observation.total_minor > constraint.max_minor
                ):
                    issues.append(
                        _issue(
                            constraint.constraint_id,
                            _issue_classification(constraint.priority),
                            "constraint.budget_exceeded",
                        )
                    )
            elif isinstance(constraint, PreferenceConstraint):
                assert isinstance(observation, PreferenceObservation)
                if observation.matched is None:
                    issues.append(
                        _issue(
                            constraint.constraint_id,
                            "unverified",
                            "constraint.preference_unverified",
                        )
                    )
                elif not observation.matched:
                    issues.append(
                        _issue(
                            constraint.constraint_id,
                            "warning",
                            "constraint.preference_unmet",
                        )
                    )

        ordered = tuple(
            sorted(issues, key=lambda item: (item.constraint_id, item.code))
        )
        counts = {
            classification: sum(
                issue.classification == classification for issue in ordered
            )
            for classification in ("hard", "warning", "unverified")
        }
        overall: Classification
        if counts["hard"]:
            overall = "hard"
        elif counts["warning"]:
            overall = "warning"
        elif counts["unverified"]:
            overall = "unverified"
        else:
            overall = "verified"
        return CanonicalValidationResult(
            classification=overall,
            issues=ordered,
            hard_conflict_count=counts["hard"],
            warning_count=counts["warning"],
            unverified_count=counts["unverified"],
        )
