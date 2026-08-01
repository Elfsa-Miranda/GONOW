from __future__ import annotations

import asyncio
import site
import sys
from pathlib import Path

import pytest
from fastapi import FastAPI
from httpx import ASGITransport, AsyncClient


SERVICE_ROOT = Path(__file__).resolve().parents[2]
site.addsitedir(str(SERVICE_ROOT / ".venv" / "Lib" / "site-packages"))
sys.path.insert(0, str(SERVICE_ROOT))

from app.api.health import (  # noqa: E402
    DependencySnapshot,
    HealthService,
    create_health_router,
    evaluate_health,
)
from app.api.lifecycle import ApiLifecycle, LifecycleRejected  # noqa: E402
from app.worker.lifecycle import WorkerLifecycle  # noqa: E402


def _snapshot(offset: float = 0.0, *, jwks: bool = True, database: bool = True) -> DependencySnapshot:
    return DependencySnapshot(jwks_ready=jwks, database_ready=database, clock_offset_seconds=offset)


@pytest.mark.parametrize("missing", ["jwks", "database"])
def test_missing_dependency_makes_readiness_false(missing: str) -> None:
    decision = evaluate_health(_snapshot(jwks=missing != "jwks", database=missing != "database"))
    assert decision.ready is False
    assert decision.new_run_allowed is False
    assert decision.high_risk_write_allowed is False


@pytest.mark.parametrize(
    ("offset", "warning", "ready"),
    [(1.0, False, True), (1.01, True, True), (5.0, True, True), (5.01, True, False)],
)
def test_clock_offset_boundaries_are_exact(offset: float, warning: bool, ready: bool) -> None:
    decision = evaluate_health(_snapshot(offset))
    assert decision.clock_warning is warning
    assert decision.ready is ready
    assert decision.new_run_allowed is ready
    assert decision.high_risk_write_allowed is ready
    assert decision.drain_allowed is True
    assert decision.cancel_allowed is True


@pytest.mark.asyncio
async def test_probe_schema_does_not_expose_configuration() -> None:
    service = HealthService(lambda: _snapshot(jwks=False))
    app = FastAPI()
    app.include_router(create_health_router(service))
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
        live = await client.get("/health/live")
        ready = await client.get("/health/ready")
    assert live.status_code == 200
    assert ready.status_code == 503
    assert set(ready.json()) == {"status", "reason_codes"}
    assert "jwks_url" not in ready.text
    assert "database_host" not in ready.text


@pytest.mark.asyncio
async def test_unsafe_clock_rejects_new_work_but_allows_drain_and_cancel() -> None:
    decision = evaluate_health(_snapshot(5.01))
    lifecycle = ApiLifecycle()
    with pytest.raises(LifecycleRejected):
        await lifecycle.admit("new-1", "new_run", decision)
    with pytest.raises(LifecycleRejected):
        await lifecycle.admit("write-1", "high_risk_write", decision)
    drain = await lifecycle.admit("drain-1", "drain", decision)
    cancel = await lifecycle.admit("cancel-1", "cancel", decision)
    await drain.release()
    await cancel.release()


@pytest.mark.asyncio
async def test_api_shutdown_drains_inflight_requests_gracefully() -> None:
    lifecycle = ApiLifecycle()
    lease = await lifecycle.admit("read-1", "read", evaluate_health(_snapshot()))
    shutdown = asyncio.create_task(lifecycle.shutdown(0.5))
    await asyncio.sleep(0)
    assert lifecycle.draining is True
    await lease.release()
    result = await shutdown
    assert result.graceful is True
    assert result.active_remaining == 0


@pytest.mark.asyncio
async def test_api_shutdown_timeout_is_explicit_and_bounded() -> None:
    lifecycle = ApiLifecycle()
    await lifecycle.admit("read-1", "read", evaluate_health(_snapshot()))
    result = await lifecycle.shutdown(0.001)
    assert result.graceful is False
    assert result.active_remaining == 1


@pytest.mark.asyncio
async def test_worker_shutdown_stops_new_operations_and_drains_existing() -> None:
    lifecycle = WorkerLifecycle()
    lifecycle.operation_started()
    shutdown = asyncio.create_task(lifecycle.shutdown(0.5))
    await asyncio.sleep(0)
    assert lifecycle.accepting_operations is False
    lifecycle.operation_finished()
    result = await shutdown
    assert result.graceful is True
    assert result.active_operations == 0
