"""Independent API and Worker entrypoint contract tests."""

from __future__ import annotations

import asyncio
import os
import subprocess
import sys
from pathlib import Path

import pytest

from app.api.main import check_lifecycle as check_api_lifecycle
from app.api.main import create_app
from app.worker.main import WorkerRuntime
from app.worker.main import check_lifecycle as check_worker_lifecycle


SERVICE_ROOT = Path(__file__).resolve().parents[1]


def _run_module(module_name: str) -> subprocess.CompletedProcess[str]:
    environment = os.environ.copy()
    environment["PYTHONPATH"] = str(SERVICE_ROOT)
    return subprocess.run(
        [sys.executable, "-m", module_name, "--check"],
        cwd=SERVICE_ROOT,
        env=environment,
        capture_output=True,
        check=False,
        text=True,
        timeout=30,
    )


@pytest.mark.asyncio
async def test_api_lifecycle_starts_and_stops_independently() -> None:
    application = create_app()

    await check_api_lifecycle(application)

    assert application.state.runtime_started is False


@pytest.mark.asyncio
async def test_worker_lifecycle_starts_and_stops_independently() -> None:
    runtime = WorkerRuntime()

    await check_worker_lifecycle(runtime)

    assert runtime.started is False


class FailingWorker(WorkerRuntime):
    async def startup(self) -> None:
        raise RuntimeError("synthetic startup failure")


def test_worker_startup_failure_returns_nonzero_to_the_process_boundary() -> None:
    command = (
        "import asyncio; "
        "from tests.test_entrypoints import FailingWorker; "
        "asyncio.run(FailingWorker().startup())"
    )
    completed = subprocess.run(
        [sys.executable, "-c", command],
        cwd=SERVICE_ROOT,
        capture_output=True,
        check=False,
        text=True,
        timeout=30,
    )

    assert completed.returncode != 0
    assert "synthetic startup failure" in completed.stderr


@pytest.mark.parametrize("module_name", ["app.api.main", "app.worker.main"])
def test_process_check_entrypoint_exits_cleanly(module_name: str) -> None:
    completed = _run_module(module_name)

    assert completed.returncode == 0, completed.stderr
    assert completed.stdout == ""


def test_duplicate_worker_start_is_rejected() -> None:
    runtime = WorkerRuntime()
    asyncio.run(runtime.startup())
    try:
        with pytest.raises(RuntimeError, match="already started"):
            asyncio.run(runtime.startup())
    finally:
        asyncio.run(runtime.shutdown())
