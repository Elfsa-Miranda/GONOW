"""Fail-closed feature flags for offline-only research branch experiments."""

from __future__ import annotations

from enum import StrEnum
from typing import Literal

from pydantic import BaseModel, ConfigDict, model_validator


class ResearchExperimentMode(StrEnum):
    OFF = "off"
    OFFLINE = "offline"
    REPLAY = "replay"
    SHADOW = "shadow"


class ResearchExperimentFlags(BaseModel):
    model_config = ConfigDict(extra="forbid", frozen=True)

    enabled: bool = False
    mode: ResearchExperimentMode = ResearchExperimentMode.OFF
    kill_switch: bool = False
    active_cohort_allowed: Literal[False] = False
    max_branches: Literal[1, 2] = 2

    @model_validator(mode="after")
    def _enabled_mode_is_explicit(self) -> ResearchExperimentFlags:
        if self.enabled is (self.mode is ResearchExperimentMode.OFF):
            raise ValueError("research_flags.enabled_mode_mismatch")
        return self

    @property
    def experiment_available(self) -> bool:
        return self.enabled and not self.kill_switch
