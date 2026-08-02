"""GoNow Agent API process entrypoint.

Phase 2 intentionally provides only a process boundary. Model, graph, tool, and
domain-write behavior is out of scope until the corresponding later phases.
"""

from __future__ import annotations

import argparse
import asyncio
from collections.abc import AsyncIterator, Sequence
from contextlib import asynccontextmanager
from dataclasses import dataclass
from pathlib import Path
from typing import Any
from uuid import uuid4

import uvicorn
from fastapi import FastAPI, HTTPException, Request
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse
from starlette.exceptions import HTTPException as StarletteHTTPException

from app.api.errors import SafeApiError, build_error_envelope, error_response_payload
from app.api.health import DependencySnapshot, HealthService, create_health_router
from app.api.routes.cancel import create_cancel_router
from app.api.routes.candidates import create_candidates_router
from app.api.routes.contracts import SchemaRegistry, create_contract_router
from app.api.routes.events import create_events_router
from app.api.routes.resume import create_resume_router
from app.api.routes.runs import create_runs_router


REPOSITORY_ROOT = Path(__file__).resolve().parents[3]
SPECIFICATION_PATH = REPOSITORY_ROOT / "contracts" / "openapi" / "agent-api.yaml"


class RuntimeDependencyUnavailable(RuntimeError):
    code = "service.unavailable"

    def __init__(self) -> None:
        super().__init__(self.code)


async def _unavailable_context(_: Request):
    raise HTTPException(status_code=503, detail=RuntimeDependencyUnavailable.code)


class _UnavailableService:
    def __getattr__(self, _: str) -> Any:
        def reject(*_args: Any, **_kwargs: Any) -> Any:
            raise RuntimeDependencyUnavailable()

        return reject


@dataclass(frozen=True, slots=True)
class ApiDependencies:
    """All stateful adapters are explicit; the API process owns no hidden singleton."""

    health: HealthService
    contracts: SchemaRegistry
    run_start: Any
    candidate_read: Any
    events: Any
    resume_capabilities: Any
    cancellation: Any
    context_resolver: Any
    resume_handler: Any
    audit_receipt_resolver: Any

    @classmethod
    def unavailable(cls) -> "ApiDependencies":
        unavailable = _UnavailableService()
        return cls(
            health=HealthService(
                lambda: DependencySnapshot(
                    jwks_ready=False,
                    database_ready=False,
                    clock_offset_seconds=0,
                )
            ),
            contracts=SchemaRegistry(SPECIFICATION_PATH),
            run_start=unavailable,
            candidate_read=unavailable,
            events=unavailable,
            resume_capabilities=unavailable,
            cancellation=unavailable,
            context_resolver=_unavailable_context,
            resume_handler=unavailable,
            audit_receipt_resolver=unavailable,
        )


@asynccontextmanager
async def lifespan(application: FastAPI) -> AsyncIterator[None]:
    """Own API startup and shutdown without relying on module side effects."""

    application.state.runtime_started = True
    try:
        yield
    finally:
        application.state.runtime_started = False


def create_app(dependencies: ApiDependencies | None = None) -> FastAPI:
    """Build an isolated, fully routed API with explicit fail-closed adapters."""

    selected = dependencies or ApiDependencies.unavailable()
    application = FastAPI(
        title="GoNow Agent Service",
        version="0.1.0",
        lifespan=lifespan,
    )
    application.state.runtime_started = False
    application.state.dependencies = selected

    def request_id(request: Request) -> str:
        supplied = request.headers.get("x-trace-id", "")
        return supplied if supplied else f"req-{uuid4()}"

    @application.exception_handler(StarletteHTTPException)
    async def http_error(request: Request, error: StarletteHTTPException) -> JSONResponse:
        try:
            safe_error: BaseException = SafeApiError(str(error.detail))
        except ValueError:
            safe_error = RuntimeError()
        status, envelope = build_error_envelope(
            safe_error,
            request_id=request_id(request),
            status_code=error.status_code,
        )
        return JSONResponse(status_code=status, content=error_response_payload(envelope))

    @application.exception_handler(RequestValidationError)
    async def validation_error(request: Request, _: RequestValidationError) -> JSONResponse:
        status, envelope = build_error_envelope(
            SafeApiError("context.invalid"),
            request_id=request_id(request),
        )
        return JSONResponse(status_code=status, content=error_response_payload(envelope))

    @application.exception_handler(Exception)
    async def unhandled_error(request: Request, error: Exception) -> JSONResponse:
        status, envelope = build_error_envelope(error, request_id=request_id(request))
        return JSONResponse(status_code=status, content=error_response_payload(envelope))

    application.include_router(create_health_router(selected.health))
    application.include_router(create_contract_router(selected.contracts))
    application.include_router(
        create_runs_router(selected.run_start, selected.context_resolver)
    )
    application.include_router(
        create_candidates_router(selected.candidate_read, selected.context_resolver)
    )
    application.include_router(
        create_events_router(selected.events, selected.context_resolver)
    )
    application.include_router(
        create_resume_router(
            selected.resume_capabilities,
            selected.context_resolver,
            selected.resume_handler,
        )
    )
    application.include_router(
        create_cancel_router(
            selected.cancellation,
            selected.context_resolver,
            selected.audit_receipt_resolver,
        )
    )
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
