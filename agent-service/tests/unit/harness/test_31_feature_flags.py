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
from app.runtime.feature_flags import (  # noqa: E402
    FeatureFlagCasConflict,
    FeatureFlagControlPlane,
    RuntimeFeatureSnapshot,
    decide_new_run,
)
from app.runtime.kill_switch import KillSwitch, KillSwitchController  # noqa: E402


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


def _runtime_control_plane() -> FeatureFlagControlPlane:
    return FeatureFlagControlPlane(
        RuntimeFeatureSnapshot(
            tenant_id="tenant-synthetic",
            generation=1,
            behavior_enabled=True,
            route_enabled=True,
            enabled_cohorts=frozenset({"stable"}),
            active_behavior_digest="f" * 64,
        )
    )


def _operator() -> RequestContext:
    return RequestContext(
        principal_id="operator-synthetic",
        tenant_id="tenant-synthetic",
        permissions=("feature_flags.write",),
        locale="en",
        timezone="UTC",
        trace_id="trace-synthetic",
    )


def test_31_feature_flags_s_independent_behavior_cut_preserves_legacy() -> None:
    control_plane = _runtime_control_plane()
    KillSwitch(KillSwitchController(control_plane)).cut_behavior(
        _operator(), expected_generation=1, approval_valid=True
    )
    decision = decide_new_run(control_plane.resolve(), cohort="stable")
    assert decision.agent_run_allowed is False
    assert decision.old_path_available is True


def test_31_feature_flags_i_generation_cas_precedes_atomic_propagation() -> None:
    control_plane = _runtime_control_plane()
    replica = control_plane.register_replica("worker")
    switch = KillSwitch(KillSwitchController(control_plane))
    changed = switch.cut_route(_operator(), expected_generation=1, approval_valid=True)
    assert replica.resolve() == changed
    try:
        switch.cut_route(_operator(), expected_generation=1, approval_valid=True)
    except FeatureFlagCasConflict:
        pass
    else:
        raise AssertionError("stale generation unexpectedly committed")
    assert replica.resolve().generation == 2


def test_31_feature_flags_i_audit_binds_old_and_new_generations() -> None:
    control_plane = _runtime_control_plane()
    KillSwitch(KillSwitchController(control_plane)).cut_cohort(
        _operator(), "stable", expected_generation=1, approval_valid=True
    )
    receipt = control_plane.receipts()[0]
    assert receipt.previous_generation == 1
    assert receipt.generation == 2
    assert receipt.scope == "cohort"


def test_31_feature_flags_d_default_snapshot_fails_closed() -> None:
    snapshot = RuntimeFeatureSnapshot.fail_closed("tenant-synthetic")
    decision = decide_new_run(snapshot, cohort="stable")
    assert decision.agent_run_allowed is False
    assert decision.old_path_available is True
    assert decision.reason == "behavior_disabled"
