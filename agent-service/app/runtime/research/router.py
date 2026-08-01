"""Single-graph-first router for bounded offline research experiments."""

from __future__ import annotations

from collections.abc import Callable
from enum import StrEnum
from typing import Generic, TypeVar

from pydantic import BaseModel, ConfigDict

from app.runtime.research.flags import ResearchExperimentFlags, ResearchExperimentMode


OutputT = TypeVar("OutputT")


class ResearchAudience(StrEnum):
    ACTIVE_USER = "active_user"
    OFFLINE = "offline"
    REPLAY = "replay"
    SHADOW = "shadow"


class ResearchRoute(StrEnum):
    PHASE_7_SINGLE_GRAPH = "phase_7_single_graph"
    RESEARCH_BRANCH = "research_branch"


class ResearchRouteAudit(BaseModel):
    model_config = ConfigDict(extra="forbid", frozen=True)

    route: ResearchRoute
    reason_code: str
    experiment_mode: ResearchExperimentMode
    active_output_count: int
    branch_runtime_call_count: int


class ResearchRouteResult(BaseModel, Generic[OutputT]):
    model_config = ConfigDict(extra="forbid", frozen=True, arbitrary_types_allowed=True)

    output: OutputT
    audit: ResearchRouteAudit


class ResearchExperimentRouter:
    """Route active or disabled traffic directly to the Phase 7 implementation."""

    def route(
        self,
        *,
        flags: ResearchExperimentFlags,
        audience: ResearchAudience,
        phase_7_single_graph: Callable[[], OutputT],
        research_branch: Callable[[], OutputT],
    ) -> ResearchRouteResult[OutputT]:
        reason = self._single_graph_reason(flags=flags, audience=audience)
        if reason is not None:
            output = phase_7_single_graph()
            return ResearchRouteResult(
                output=output,
                audit=ResearchRouteAudit(
                    route=ResearchRoute.PHASE_7_SINGLE_GRAPH,
                    reason_code=reason,
                    experiment_mode=flags.mode,
                    active_output_count=1 if audience is ResearchAudience.ACTIVE_USER else 0,
                    branch_runtime_call_count=0,
                ),
            )
        output = research_branch()
        return ResearchRouteResult(
            output=output,
            audit=ResearchRouteAudit(
                route=ResearchRoute.RESEARCH_BRANCH,
                reason_code="research.experiment_eligible",
                experiment_mode=flags.mode,
                active_output_count=0,
                branch_runtime_call_count=1,
            ),
        )

    @staticmethod
    def _single_graph_reason(
        *, flags: ResearchExperimentFlags, audience: ResearchAudience
    ) -> str | None:
        if flags.kill_switch:
            return "research.kill_switch"
        if not flags.enabled:
            return "research.flag_off"
        if audience is ResearchAudience.ACTIVE_USER:
            return "research.active_user_forbidden"
        if audience.value != flags.mode.value:
            return "research.audience_mode_mismatch"
        return None
