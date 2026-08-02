"""Real Flutter generated-client -> HTTP API -> PostgreSQL -> Worker journey."""

from __future__ import annotations

import json
import os
from pathlib import Path
import socket
import subprocess
from threading import Event, Thread
import time

import pytest
import uvicorn

from tests.integration.test_runtime_composition import (
    TENANT_A,
    _CandidateProcessor,
    _PinProvider,
    _app,
    _pin,
    runtime_database,
)
from app.worker.execution import DurableWorkerExecutor


REPOSITORY_ROOT = Path(__file__).resolve().parents[3]
PROBE = REPOSITORY_ROOT / "tool" / "runtime_journey_probe.dart"
EXPECTED_SPEC_SHA256 = (
    "bc067228d99196391b9a0cdb9c687fadb5b0c2947418afe8687eca53e78e3fc0"
)


def _loopback_port() -> int:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as listener:
        listener.bind(("127.0.0.1", 0))
        return int(listener.getsockname()[1])


def _wait_until(predicate, *, timeout: float, message: str) -> None:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if predicate():
            return
        time.sleep(0.02)
    raise AssertionError(message)


def test_flutter_http_postgres_worker_candidate_journey(runtime_database) -> None:
    _, _, api_factory, worker_factory = runtime_database
    app = _app(api_factory, _PinProvider(_pin("9")))
    port = _loopback_port()
    server = uvicorn.Server(
        uvicorn.Config(
            app,
            host="127.0.0.1",
            port=port,
            log_config=None,
            access_log=False,
        )
    )
    api_thread = Thread(target=server.run, name="p10-api", daemon=True)
    stop_worker = Event()
    worker_failures: list[BaseException] = []

    def worker_loop() -> None:
        executor = DurableWorkerExecutor(
            worker_factory,
            processor=_CandidateProcessor(),
        )
        try:
            while not stop_worker.is_set():
                result = executor.execute_once(
                    tenant_id=TENANT_A,
                    holder_id="worker-p10-flutter-journey",
                    audit_receipt_id="audit-worker-p10-flutter-journey",
                )
                if result.state.value == "empty":
                    stop_worker.wait(0.02)
        except BaseException as error:  # captured and asserted in the parent
            worker_failures.append(error)
            stop_worker.set()

    worker_thread = Thread(target=worker_loop, name="p10-worker", daemon=True)
    api_thread.start()
    try:
        _wait_until(
            lambda: server.started,
            timeout=5,
            message="loopback API did not start",
        )
        worker_thread.start()
        dart = os.environ.get("GONOW_DART_EXECUTABLE", "").strip()
        assert dart, "GONOW_DART_EXECUTABLE must point to the locked Dart SDK"
        environment = os.environ.copy()
        environment["GONOW_RUNTIME_JOURNEY_TOKEN"] = "tenant-a-token"
        completed = subprocess.run(
            [
                dart,
                "run",
                str(PROBE),
                f"--base-url=http://127.0.0.1:{port}",
            ],
            cwd=REPOSITORY_ROOT,
            env=environment,
            capture_output=True,
            text=True,
            timeout=60,
            check=False,
        )
        assert completed.returncode == 0, completed.stderr[-4_000:]
        marker = '{"status":"passed"'
        marker_offset = completed.stdout.rfind(marker)
        assert marker_offset >= 0, completed.stdout[-4_000:]
        payload = json.loads(completed.stdout[marker_offset:].strip())
        assert payload == {
            "status": "passed",
            "run_id": payload["run_id"],
            "thread_id": payload["thread_id"],
            "candidate_id": payload["candidate_id"],
            "candidate_run_matches": True,
            "behavior_digest_matches": True,
            "candidate_read_attempts": payload["candidate_read_attempts"],
            "contract_sha256": EXPECTED_SPEC_SHA256,
        }
        assert 1 <= payload["candidate_read_attempts"] <= 100
        assert not worker_failures
    finally:
        stop_worker.set()
        server.should_exit = True
        worker_thread.join(timeout=5)
        api_thread.join(timeout=5)
        assert not worker_thread.is_alive()
        assert not api_thread.is_alive()
