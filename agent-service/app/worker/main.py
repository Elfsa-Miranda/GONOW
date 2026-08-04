"""GoNow Agent Worker process entrypoint.

The worker owns its lifecycle independently from the API process. Durable job
execution is added in Phase 5; this phase establishes the failure-safe boundary.
"""

from __future__ import annotations

import argparse
import asyncio
import signal
from collections.abc import Sequence
from collections.abc import Callable
from typing import Protocol
from uuid import uuid4

from app.worker.execution import DurableWorkerExecutor, WorkerExecutionState


class TenantWorkSource(Protocol):
    def ready_tenants(self) -> tuple[str, ...]: ...


class WorkerRuntime:
    """Minimal independently controlled worker lifecycle."""

    def __init__(
        self,
        *,
        executor: DurableWorkerExecutor | None = None,
        tenant_source: TenantWorkSource | None = None,
        worker_id: str = "worker-unconfigured",
        poll_interval_seconds: float = 0.25,
        resource_closer: Callable[[], None] | None = None,
    ) -> None:
        if poll_interval_seconds <= 0 or poll_interval_seconds > 30:
            raise ValueError("worker poll interval is invalid")
        self._stop_requested = asyncio.Event()
        self._executor = executor
        self._tenant_source = tenant_source
        self._worker_id = worker_id
        self._poll_interval_seconds = poll_interval_seconds
        self._resource_closer = resource_closer
        self._resources_closed = False
        self.started = False

    async def startup(self) -> None:
        if self.started:
            raise RuntimeError("worker is already started")
        self.started = True

    async def shutdown(self) -> None:
        self._stop_requested.set()
        self.started = False
        if self._resource_closer is not None and not self._resources_closed:
            await asyncio.to_thread(self._resource_closer)
            self._resources_closed = True

    async def run(self) -> None:
        await self.startup()
        try:
            if self._executor is None or self._tenant_source is None:
                raise RuntimeError("worker.dependencies_unavailable")
            while not self._stop_requested.is_set():
                processed = await self.poll_once()
                if processed == 0:
                    try:
                        await asyncio.wait_for(
                            self._stop_requested.wait(),
                            timeout=self._poll_interval_seconds,
                        )
                    except TimeoutError:
                        pass
        finally:
            await self.shutdown()

    async def poll_once(self) -> int:
        if self._executor is None or self._tenant_source is None:
            raise RuntimeError("worker.dependencies_unavailable")
        processed = 0
        for tenant_id in self._tenant_source.ready_tenants():
            attempt_id = uuid4()
            result = await asyncio.to_thread(
                self._executor.execute_once,
                tenant_id=tenant_id,
                holder_id=f"{self._worker_id}:{attempt_id}",
                audit_receipt_id=f"worker:{attempt_id}",
            )
            if result.state is not WorkerExecutionState.EMPTY:
                processed += 1
        return processed


async def check_lifecycle(runtime: WorkerRuntime | None = None) -> None:
    """Run a complete worker lifecycle without waiting for a signal."""

    selected = runtime or WorkerRuntime()
    await selected.startup()
    if selected.started is not True:
        raise RuntimeError("worker startup contract was not established")
    await selected.shutdown()
    if selected.started is not False:
        raise RuntimeError("worker shutdown contract was not completed")


async def run_worker(runtime: WorkerRuntime | None = None) -> None:
    if runtime is None:
        from app.worker.composition import build_worker_runtime_from_environment

        selected = build_worker_runtime_from_environment()
    else:
        selected = runtime
    loop = asyncio.get_running_loop()
    installed_signals: list[signal.Signals] = []

    for handled_signal in (signal.SIGINT, signal.SIGTERM):
        try:
            loop.add_signal_handler(handled_signal, selected._stop_requested.set)
            installed_signals.append(handled_signal)
        except (NotImplementedError, RuntimeError):
            # Windows' default event loop may not implement signal handlers.
            pass

    try:
        await selected.run()
    finally:
        for handled_signal in installed_signals:
            loop.remove_signal_handler(handled_signal)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Run the GoNow Agent Worker")
    parser.add_argument("--check", action="store_true", help="validate startup/shutdown and exit")
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    if args.check:
        asyncio.run(check_lifecycle())
    else:
        asyncio.run(run_worker())
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
