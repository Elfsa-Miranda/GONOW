from __future__ import annotations

import site
import sys
from dataclasses import dataclass
from pathlib import Path


SERVICE_ROOT = Path(__file__).resolve().parents[3]
site.addsitedir(str(SERVICE_ROOT / ".venv" / "Lib" / "site-packages"))
sys.path.insert(0, str(SERVICE_ROOT))

from app.api.routing import (  # noqa: E402
    FeatureFlagSnapshot,
    FeatureRouter,
    RouteIntent,
    SelectedRoute,
)
from app.auth.context import RequestContext  # noqa: E402


@dataclass
class Store:
    snapshot: FeatureFlagSnapshot | None

    def resolve(self, *, tenant_id: str, principal_id: str) -> FeatureFlagSnapshot:
        if self.snapshot is None:
            raise RuntimeError("synthetic store failure")
        return self.snapshot


def _context() -> RequestContext:
    return RequestContext(
        principal_id="principal-synthetic",
        tenant_id="tenant-synthetic",
        permissions=(),
        locale="en",
        timezone="UTC",
        trace_id="trace-synthetic",
    )


def test_31_feature_flags_s_on_and_off_choose_deterministic_routes() -> None:
    enabled = FeatureRouter(Store(FeatureFlagSnapshot(True, False, 1, "a" * 64))).decide(
        RouteIntent.ITINERARY_AGENT, _context()
    )
    disabled = FeatureRouter(Store(FeatureFlagSnapshot(False, False, 2, None))).decide(
        RouteIntent.ITINERARY_AGENT, _context()
    )
    assert enabled.selected_route is SelectedRoute.AGENT_ITINERARY
    assert disabled.selected_route is SelectedRoute.LEGACY_ITINERARY


def test_31_feature_flags_i_kill_switch_has_priority() -> None:
    decision = FeatureRouter(Store(FeatureFlagSnapshot(True, True, 3, "b" * 64))).decide(
        RouteIntent.ITINERARY_AGENT, _context(), pinned_behavior_digest="c" * 64
    )
    assert decision.selected_route is SelectedRoute.LEGACY_ITINERARY
    assert decision.agent_call_allowed is False
    assert decision.reason == "kill_switch"


def test_31_feature_flags_i_running_manifest_digest_is_immutable() -> None:
    pinned = "d" * 64
    decision = FeatureRouter(Store(FeatureFlagSnapshot(False, False, 4, "e" * 64))).decide(
        RouteIntent.ITINERARY_AGENT, _context(), pinned_behavior_digest=pinned
    )
    assert decision.selected_route is SelectedRoute.AGENT_ITINERARY
    assert decision.behavior_digest == pinned


def test_31_feature_flags_d_store_failure_closes_agent_and_preserves_legacy() -> None:
    decision = FeatureRouter(Store(None)).decide(RouteIntent.ITINERARY_AGENT, _context())
    assert decision.selected_route is SelectedRoute.LEGACY_ITINERARY
    assert decision.agent_call_allowed is False
    assert decision.reason == "flag_store_unavailable"
