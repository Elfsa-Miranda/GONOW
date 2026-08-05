"""Worker drain coordination without claiming or executing jobs."""

from __future__ import annotations

import asyncio

from pydantic import BaseModel, ConfigDict, Field


class WorkerShutdownResult(BaseModel):
    model_config = ConfigDict(extra="forbid", frozen=True)

    graceful: bool
    active_operations: int = Field(ge=0)


class WorkerLifecycle:
    """Track only already-started operations; job leasing belongs to Phase 5."""

    def __init__(self) -> None:
        self._active_operations = 0
        self._drained = asyncio.Event()
        self._drained.set()
        self.accepting_operations = True

    @property
    def active_operations(self) -> int:
        return self._active_operations

    def operation_started(self) -> None:
        if not self.accepting_operations:
            raise RuntimeError("worker.draining")
        self._active_operations += 1
        self._drained.clear()

    def operation_finished(self) -> None:
        if self._active_operations < 1:
            raise RuntimeError("worker.operation_underflow")
        self._active_operations -= 1
        if self._active_operations == 0:
            self._drained.set()

    async def shutdown(self, grace_seconds: float) -> WorkerShutdownResult:
        if grace_seconds < 0:
            raise ValueError("grace_seconds cannot be negative")
        self.accepting_operations = False
        try:
            await asyncio.wait_for(self._drained.wait(), timeout=grace_seconds)
        except TimeoutError:
            return WorkerShutdownResult(graceful=False, active_operations=self._active_operations)
        return WorkerShutdownResult(graceful=True, active_operations=0)
