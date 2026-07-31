"""GoNow Agent Worker process entrypoint.

The worker owns its lifecycle independently from the API process. Durable job
execution is added in Phase 5; this phase establishes the failure-safe boundary.
"""

from __future__ import annotations

import argparse
import asyncio
import signal
from collections.abc import Sequence


class WorkerRuntime:
    """Minimal independently controlled worker lifecycle."""

    def __init__(self) -> None:
        self._stop_requested = asyncio.Event()
        self.started = False

    async def startup(self) -> None:
        if self.started:
            raise RuntimeError("worker is already started")
        self.started = True

    async def shutdown(self) -> None:
        self._stop_requested.set()
        self.started = False

    async def run(self) -> None:
        await self.startup()
        try:
            await self._stop_requested.wait()
        finally:
            await self.shutdown()


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
    selected = runtime or WorkerRuntime()
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

