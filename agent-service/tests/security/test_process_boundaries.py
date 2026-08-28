from __future__ import annotations

import ast
import asyncio
import json
import site
import socket
import sys
from pathlib import Path

import pytest


SERVICE_ROOT = Path(__file__).resolve().parents[2]
REPO_ROOT = SERVICE_ROOT.parent
site.addsitedir(str(SERVICE_ROOT / ".venv" / "Lib" / "site-packages"))
sys.path.insert(0, str(SERVICE_ROOT))

from app.api.main import check_lifecycle as check_api_lifecycle  # noqa: E402
from app.api.main import create_app  # noqa: E402
from app.worker.main import WorkerRuntime  # noqa: E402
from app.worker.main import check_lifecycle as check_worker_lifecycle  # noqa: E402


APP_ROOT = SERVICE_ROOT / "app"


def _trees() -> list[tuple[Path, ast.AST]]:
    return [(path, ast.parse(path.read_text(encoding="utf-8"), filename=str(path))) for path in APP_ROOT.rglob("*.py")]


def test_api_and_worker_have_distinct_entrypoints() -> None:
    api = APP_ROOT / "api" / "main.py"
    worker = APP_ROOT / "worker" / "main.py"
    assert api != worker
    assert 'if __name__ == "__main__"' in api.read_text(encoding="utf-8")
    assert 'if __name__ == "__main__"' in worker.read_text(encoding="utf-8")


@pytest.mark.asyncio
async def test_lifecycle_checks_need_no_network(monkeypatch: pytest.MonkeyPatch) -> None:
    def deny_connect(*args: object, **kwargs: object) -> None:
        raise AssertionError("network access is outside the Phase 2 lifecycle boundary")

    monkeypatch.setattr(socket.socket, "connect", deny_connect)
    await check_api_lifecycle(create_app())
    await check_worker_lifecycle(WorkerRuntime())


def test_service_does_not_spawn_child_processes() -> None:
    forbidden = {"Popen", "run", "call", "check_call", "check_output"}
    findings: list[str] = []
    for path, tree in _trees():
        for node in ast.walk(tree):
            if isinstance(node, ast.Attribute) and isinstance(node.value, ast.Name):
                if node.value.id == "subprocess" and node.attr in forbidden:
                    findings.append(f"{path.name}:{node.lineno}")
    assert findings == []


def test_public_run_contract_is_the_exact_approved_additive_surface() -> None:
    specification = json.loads(
        (REPO_ROOT / "contracts" / "openapi" / "agent-api.yaml").read_text(encoding="utf-8")
    )
    run_paths = {
        path: set(methods)
        for path, methods in specification["paths"].items()
        if path.startswith("/v1/runs")
    }
    assert run_paths == {
        "/v1/runs": {"post"},
        "/v1/runs/{run_id}/events": {"get"},
        "/v1/runs/{run_id}/resume": {"post"},
        "/v1/runs/{run_id}/cancel": {"post"},
        "/v1/runs/{run_id}/candidate": {"get"},
    }
    assert "/v1/contracts/{name}/{major}" in specification["paths"]


def test_worker_runtime_exposes_no_job_claim_method() -> None:
    public_methods = {
        node.name
        for node in ast.walk(ast.parse((APP_ROOT / "worker" / "main.py").read_text(encoding="utf-8")))
        if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)) and not node.name.startswith("_")
    }
    assert not public_methods & {"claim", "lease", "execute_job", "run_job"}


def test_entrypoints_do_not_import_each_other() -> None:
    api = (APP_ROOT / "api" / "main.py").read_text(encoding="utf-8")
    worker = (APP_ROOT / "worker" / "main.py").read_text(encoding="utf-8")
    assert "app.worker" not in api
    assert "app.api" not in worker
