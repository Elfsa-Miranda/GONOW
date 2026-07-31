"""Minimal liveness and fail-closed readiness decisions."""

from __future__ import annotations

from collections.abc import Callable

from fastapi import APIRouter
from fastapi.responses import JSONResponse
from pydantic import BaseModel, ConfigDict


CLOCK_WARNING_SECONDS = 1.0
CLOCK_UNSAFE_SECONDS = 5.0


class DependencySnapshot(BaseModel):
    model_config = ConfigDict(extra="forbid", frozen=True)

    jwks_ready: bool
    database_ready: bool
    clock_offset_seconds: float


class HealthDecision(BaseModel):
    model_config = ConfigDict(extra="forbid", frozen=True)

    live: bool
    ready: bool
    clock_warning: bool
    new_run_allowed: bool
    high_risk_write_allowed: bool
    drain_allowed: bool
    cancel_allowed: bool
    reason_codes: tuple[str, ...]


class ProbePayload(BaseModel):
    """Public probe schema deliberately excludes dependency configuration."""

    model_config = ConfigDict(extra="forbid", frozen=True)

    status: str
    reason_codes: tuple[str, ...] = ()


def evaluate_health(snapshot: DependencySnapshot, *, draining: bool = False) -> HealthDecision:
    reasons: list[str] = []
    offset = abs(snapshot.clock_offset_seconds)
    clock_warning = offset > CLOCK_WARNING_SECONDS
    clock_safe = offset <= CLOCK_UNSAFE_SECONDS
    if not snapshot.jwks_ready:
        reasons.append("dependency.jwks_unavailable")
    if not snapshot.database_ready:
        reasons.append("dependency.database_unavailable")
    if not clock_safe:
        reasons.append("clock.unsafe")
    elif clock_warning:
        reasons.append("clock.warning")
    if draining:
        reasons.append("lifecycle.draining")
    ready = snapshot.jwks_ready and snapshot.database_ready and clock_safe and not draining
    return HealthDecision(
        live=True,
        ready=ready,
        clock_warning=clock_warning,
        new_run_allowed=ready,
        high_risk_write_allowed=ready,
        drain_allowed=True,
        cancel_allowed=True,
        reason_codes=tuple(reasons),
    )


class HealthService:
    def __init__(self, snapshot_provider: Callable[[], DependencySnapshot]) -> None:
        self._snapshot_provider = snapshot_provider
        self.draining = False

    def liveness(self) -> tuple[int, ProbePayload]:
        return 200, ProbePayload(status="live")

    def readiness(self) -> tuple[int, ProbePayload]:
        decision = evaluate_health(self._snapshot_provider(), draining=self.draining)
        return (
            200 if decision.ready else 503,
            ProbePayload(status="ready" if decision.ready else "not_ready", reason_codes=decision.reason_codes),
        )


def create_health_router(service: HealthService) -> APIRouter:
    router = APIRouter(include_in_schema=False)

    @router.get("/health/live")
    async def liveness() -> JSONResponse:
        status, payload = service.liveness()
        return JSONResponse(status_code=status, content=payload.model_dump(mode="json"))

    @router.get("/health/ready")
    async def readiness() -> JSONResponse:
        status, payload = service.readiness()
        return JSONResponse(status_code=status, content=payload.model_dump(mode="json"))

    return router
