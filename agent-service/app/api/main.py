"""GoNow Agent API process entrypoint.

Phase 2 intentionally provides only a process boundary. Model, graph, tool, and
domain-write behavior is out of scope until the corresponding later phases.
"""

from __future__ import annotations

import argparse
import asyncio
from collections.abc import AsyncIterator, Sequence
from contextlib import asynccontextmanager

import uvicorn
from fastapi import FastAPI


@asynccontextmanager
async def lifespan(application: FastAPI) -> AsyncIterator[None]:
    """Own API startup and shutdown without relying on module side effects."""

    application.state.runtime_started = True
    try:
        yield
    finally:
        application.state.runtime_started = False


def create_app() -> FastAPI:
    """Build an isolated API application instance."""

    application = FastAPI(
        title="GoNow Agent Service",
        version="0.1.0",
        lifespan=lifespan,
    )
    application.state.runtime_started = False
    return application


app = create_app()


async def check_lifecycle(application: FastAPI = app) -> None:
    """Run one complete lifecycle for build and container smoke checks."""

    async with application.router.lifespan_context(application):
        if application.state.runtime_started is not True:
            raise RuntimeError("API startup contract was not established")
    if application.state.runtime_started is not False:
        raise RuntimeError("API shutdown contract was not completed")


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Run the GoNow Agent API")
    parser.add_argument("--check", action="store_true", help="validate startup/shutdown and exit")
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8080)
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    if args.check:
        asyncio.run(check_lifecycle())
        return 0

    uvicorn.run(app, host=args.host, port=args.port, log_config=None)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

