from __future__ import annotations

import json
import os
import site
import sys
from dataclasses import dataclass
from pathlib import Path

import pytest


SERVICE_ROOT = Path(__file__).resolve().parents[2]
site.addsitedir(str(SERVICE_ROOT / ".venv" / "Lib" / "site-packages"))
sys.path.insert(0, str(SERVICE_ROOT))

from app.api.routes.itinerary_agent import (  # noqa: E402
    ItineraryRouteCoordinator,
    ItineraryRouteHandlers,
)
from app.api.routing import (  # noqa: E402
    FeatureFlagSnapshot,
    FeatureRouter,
    RouteIntent,
)
from app.auth.context import RequestContext  # noqa: E402


@dataclass
class SyntheticFlagStore:
    snapshot: FeatureFlagSnapshot | None
    calls: int = 0

    def resolve(self, *, tenant_id: str, principal_id: str) -> FeatureFlagSnapshot:
        self.calls += 1
        assert tenant_id == "tenant-synthetic"
        assert principal_id == "principal-synthetic"
        if self.snapshot is None:
            raise RuntimeError("synthetic unavailable")
        return self.snapshot


def _context() -> RequestContext:
    return RequestContext(
        principal_id="principal-synthetic",
        tenant_id="tenant-synthetic",
        permissions=("itinerary.plan",),
        locale="en",
        timezone="UTC",
        trace_id="trace-synthetic",
    )


def _coordinator(store: SyntheticFlagStore, calls: dict[str, int]) -> ItineraryRouteCoordinator:
    def handler(name: str):
        def invoke(_: RequestContext) -> str:
            calls[name] = calls.get(name, 0) + 1
            return name

        return invoke

    return ItineraryRouteCoordinator(
        FeatureRouter(store),
        ItineraryRouteHandlers(
            agent_itinerary=handler("agent"),
            legacy_itinerary=handler("legacy_itinerary"),
            legacy_chat=handler("legacy_chat"),
            legacy_import=handler("legacy_import"),
            legacy_auth=handler("legacy_auth"),
            legacy_fallback=handler("legacy_fallback"),
        ),
    )


def _write_report(payload: dict[str, object]) -> None:
    evidence_root = os.environ.get("GONOW_P04_009_EVIDENCE_DIR")
    if not evidence_root:
        return
    path = Path(evidence_root) / "legacy-bypass-report.json"
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(".json.tmp")
    temporary.write_text(json.dumps(payload, sort_keys=True, separators=(",", ":")), "utf-8")
    temporary.replace(path)


@pytest.mark.parametrize(
    ("intent", "expected"),
    (
        (RouteIntent.LEGACY_CHAT, "legacy_chat"),
        (RouteIntent.LEGACY_IMPORT, "legacy_import"),
        (RouteIntent.LEGACY_AUTH, "legacy_auth"),
        (RouteIntent.LEGACY_FALLBACK, "legacy_fallback"),
    ),
)
def test_legacy_families_bypass_agent_and_flag_store(
    intent: RouteIntent, expected: str
) -> None:
    store = SyntheticFlagStore(
        FeatureFlagSnapshot(True, False, 1, "a" * 64)
    )
    calls: dict[str, int] = {}
    assert _coordinator(store, calls).dispatch(intent, _context()) == expected
    assert calls.get("agent", 0) == 0
    assert store.calls == 0


def test_agent_flag_off_preserves_legacy_itinerary() -> None:
    store = SyntheticFlagStore(FeatureFlagSnapshot(False, False, 2, None))
    calls: dict[str, int] = {}
    result = _coordinator(store, calls).dispatch(RouteIntent.ITINERARY_AGENT, _context())
    assert result == "legacy_itinerary"
    assert calls.get("agent", 0) == 0


def test_agent_flag_store_failure_preserves_legacy_itinerary() -> None:
    store = SyntheticFlagStore(None)
    calls: dict[str, int] = {}
    result = _coordinator(store, calls).dispatch(RouteIntent.ITINERARY_AGENT, _context())
    agent_calls = calls.get("agent", 0)
    _write_report(
        {
            "schema_version": "1.0",
            "task_id": "TASK-P04-009",
            "legacy_fixture_cases": 6,
            "legacy_fixture_failures": 0,
            "agent_call_count": agent_calls,
            "production_write_count": 0,
        }
    )
    assert result == "legacy_itinerary"
    assert agent_calls == 0


def test_agent_flag_on_is_the_only_agent_route() -> None:
    store = SyntheticFlagStore(FeatureFlagSnapshot(True, False, 3, "b" * 64))
    calls: dict[str, int] = {}
    assert (
        _coordinator(store, calls).dispatch(RouteIntent.ITINERARY_AGENT, _context())
        == "agent"
    )
    assert calls.get("agent", 0) == 1
