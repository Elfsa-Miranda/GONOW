from __future__ import annotations

import asyncio
from pathlib import Path
import site
import sys

import pytest


SERVICE_ROOT = Path(__file__).resolve().parents[2]
site.addsitedir(str(SERVICE_ROOT / ".venv" / "Lib" / "site-packages"))
sys.path.insert(0, str(SERVICE_ROOT))

from app.worker.composition import (  # noqa: E402
    StaticTenantWorkSource,
    WorkerCompositionError,
    build_worker_runtime_from_environment,
)
from app.worker.main import check_lifecycle  # noqa: E402


def test_worker_composition_fails_closed_when_required_inputs_are_missing(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    for name in ("GONOW_DATABASE_URL", "GONOW_WORKER_TENANTS", "GEMINI_API_KEY"):
        monkeypatch.delenv(name, raising=False)
    with pytest.raises(WorkerCompositionError):
        build_worker_runtime_from_environment()


def test_worker_composition_accepts_only_fixed_postgresql_and_tenant_scope(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setenv(
        "GONOW_DATABASE_URL",
        "postgresql+pg8000://worker@127.0.0.1:55432/gonow_p03_test",
    )
    monkeypatch.setenv("GONOW_WORKER_TENANTS", "tenant-b,tenant-a")
    monkeypatch.setenv("GEMINI_API_KEY", "synthetic-gemini-credential")
    runtime = build_worker_runtime_from_environment()
    asyncio.run(check_lifecycle(runtime))
    assert runtime.started is False


@pytest.mark.parametrize(
    "tenant_ids",
    [(), ("*",), ("tenant-a", "tenant-a"), ("tenant a",)],
)
def test_static_tenant_source_rejects_wildcard_duplicate_or_invalid_scope(
    tenant_ids: tuple[str, ...],
) -> None:
    with pytest.raises(WorkerCompositionError):
        StaticTenantWorkSource(tenant_ids)


def test_static_tenant_source_is_deterministic() -> None:
    assert StaticTenantWorkSource(("tenant-b", "tenant-a")).ready_tenants() == (
        "tenant-a",
        "tenant-b",
    )
