"""API admission and bounded graceful-shutdown coordination."""

from __future__ import annotations

import asyncio
from dataclasses import dataclass
from typing import Literal

from pydantic import BaseModel, ConfigDict, Field

from app.api.health import HealthDecision


OperationKind = Literal["new_run", "high_risk_write", "drain", "cancel", "read"]


class LifecycleRejected(RuntimeError):
    code = "lifecycle.not_accepting"

    def __init__(self) -> None:
        super().__init__(self.code)


class ShutdownResult(BaseModel):
    model_config = ConfigDict(extra="forbid", frozen=True)

    graceful: bool
    active_remaining: int = Field(ge=0)


@dataclass(slots=True)
class RequestLease:
    controller: "ApiLifecycle"
    request_id: str
    _released: bool = False

    async def release(self) -> None:
        if not self._released:
            self._released = True
            await self.controller.release(self.request_id)

    async def __aenter__(self) -> "RequestLease":
        return self

    async def __aexit__(self, exc_type: object, exc: object, traceback: object) -> None:
        await self.release()


class ApiLifecycle:
    def __init__(self) -> None:
        self._active: set[str] = set()
        self._lock = asyncio.Lock()
        self._drained = asyncio.Event()
        self._drained.set()
        self.draining = False

    @property
    def active_count(self) -> int:
        return len(self._active)

    async def admit(
        self,
        request_id: str,
        operation: OperationKind,
        decision: HealthDecision,
    ) -> RequestLease:
        allowed = {
            "new_run": decision.new_run_allowed and not self.draining,
            "high_risk_write": decision.high_risk_write_allowed and not self.draining,
            "drain": decision.drain_allowed,
            "cancel": decision.cancel_allowed,
            "read": decision.ready and not self.draining,
        }[operation]
        if not allowed:
            raise LifecycleRejected()
        async with self._lock:
            if request_id in self._active:
                raise LifecycleRejected()
            self._active.add(request_id)
            self._drained.clear()
        return RequestLease(controller=self, request_id=request_id)

    async def release(self, request_id: str) -> None:
        async with self._lock:
            self._active.discard(request_id)
            if not self._active:
                self._drained.set()

    async def shutdown(self, grace_seconds: float) -> ShutdownResult:
        if grace_seconds < 0:
            raise ValueError("grace_seconds cannot be negative")
        self.draining = True
        try:
            await asyncio.wait_for(self._drained.wait(), timeout=grace_seconds)
        except TimeoutError:
            return ShutdownResult(graceful=False, active_remaining=self.active_count)
        return ShutdownResult(graceful=True, active_remaining=0)
