from __future__ import annotations

from dataclasses import replace
from decimal import Decimal
from pathlib import Path
import site
import socket
import sys

import pytest


SERVICE_ROOT = Path(__file__).resolve().parents[2]
site.addsitedir(str(SERVICE_ROOT / ".venv" / "Lib" / "site-packages"))
sys.path.insert(0, str(SERVICE_ROOT))

from app.models.cost_ledger import (  # noqa: E402
    CostLedgerError,
    CostReservationRequest,
    LocalCostLedger,
)
from app.models.cost_router import (  # noqa: E402
    CostRoute,
    CostRouterError,
    PriceQuote,
    PrivacyClass,
    ProviderHealth,
    RouteHealth,
    RouteSnapshot,
    RoutingPolicy,
    RoutingRequest,
    evaluate_cost_route,
)
from scripts.run_p12b_replay import (  # noqa: E402
    AS_OF_EPOCH_SECONDS,
    DATASET_SHA256,
    _policy_and_prices,
    _required_capabilities,
    load_dataset,
    run_replay,
)


DATASET = SERVICE_ROOT / "tests" / "eval" / "datasets" / "cost-router" / "v1" / "scenarios.jsonl"


def _routing_request(scenario: dict, **changes: object) -> RoutingRequest:
    request = scenario["request"]
    values: dict[str, object] = {
        "task_class": "itinerary_generation",
        "required_capabilities": _required_capabilities(request),
        "region": "global",
        "privacy_class": PrivacyClass.STANDARD,
        "quality_floor_ppm": 900_000,
        "latency_budget_ms": 5_000,
        "remaining_budget_microusd": 100_000,
        "estimated_input_tokens": 500,
        "max_output_tokens": 1024,
        "as_of_epoch_seconds": AS_OF_EPOCH_SECONDS,
    }
    values.update(changes)
    return RoutingRequest(**values)  # type: ignore[arg-type]


def _replace_candidate(policy: RoutingPolicy, **changes: object) -> RoutingPolicy:
    baseline, candidate = policy.snapshots
    route = replace(candidate.route, **changes)
    return replace(policy, snapshots=(baseline, replace(candidate, route=route)))


def test_frozen_ten_scenario_paired_replay_has_zero_network_and_redlines(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    def forbidden_connect(*_: object, **__: object) -> None:
        raise AssertionError("network forbidden in replay")

    monkeypatch.setattr(socket.socket, "connect", forbidden_connect)
    result = run_replay(DATASET)
    assert result["dataset_sha256"] == DATASET_SHA256
    assert result["scenario_count"] == 10
    assert result["live_call_count"] == 0
    assert result["network_transport_count"] == 0
    assert result["arms"]["baseline"]["denominator"] == 10
    assert result["arms"]["candidate"]["denominator"] == 10
    assert result["arms"]["baseline"]["qualified_success_count"] == 10
    assert result["arms"]["candidate"]["qualified_success_count"] == 10
    assert result["candidate_cost_per_success_ratio"] <= 0.75
    assert result["redline_failure_count"] == 0


def test_one_retryable_candidate_failure_has_one_costed_fallback_hop() -> None:
    result = run_replay(
        DATASET, candidate_retryable_failure_scenario="CR-V1-001"
    )
    assert result["candidate_fallback_count"] == 1
    assert result["arms"]["candidate"]["attempt_count"] == 11
    assert result["arms"]["candidate"]["denominator"] == 10
    assert result["redlines"]["recursive_fallback"] == 0
    assert result["redline_failure_count"] == 0


@pytest.mark.parametrize(
    "mutation",
    ["stale_price", "unknown_health", "wrong_region", "restricted_privacy", "quality_floor", "budget"],
)
def test_ineligible_candidate_is_removed_before_cost(mutation: str) -> None:
    scenario = load_dataset(DATASET)[0]
    policy, _, _ = _policy_and_prices(scenario["request"])
    request = _routing_request(scenario)
    if mutation == "stale_price":
        stale = replace(
            policy.snapshots[1].route.price,
            observed_at_epoch_seconds=AS_OF_EPOCH_SECONDS - 604_801,
        )
        policy = _replace_candidate(policy, price=stale)
    elif mutation == "unknown_health":
        baseline, candidate = policy.snapshots
        policy = replace(
            policy,
            snapshots=(
                baseline,
                replace(
                    candidate,
                    health=replace(candidate.health, state=ProviderHealth.UNKNOWN),
                ),
            ),
        )
    elif mutation == "wrong_region":
        policy = _replace_candidate(policy, allowed_regions=frozenset({"eu"}))
    elif mutation == "restricted_privacy":
        policy = _replace_candidate(
            policy,
            allowed_privacy_classes=frozenset({PrivacyClass.STANDARD}),
        )
        request = _routing_request(scenario, privacy_class=PrivacyClass.RESTRICTED)
    elif mutation == "quality_floor":
        policy = _replace_candidate(policy, quality_score_ppm=899_999)
    else:
        expensive = PriceQuote(
            "candidate-expensive",
            AS_OF_EPOCH_SECONDS - 60,
            3600,
            Decimal("10"),
            Decimal("1"),
            Decimal("10"),
        )
        policy = _replace_candidate(policy, price=expensive)
        request = _routing_request(scenario, remaining_budget_microusd=5_000)
    decision = evaluate_cost_route(request=request, policy=policy)
    assert decision.selected_route_id == policy.baseline_route_id
    assert decision.fallback_route_id is None


@pytest.mark.parametrize(("enabled", "kill_switch"), [(False, False), (True, True)])
def test_disabled_or_kill_switch_bypasses_candidate(
    enabled: bool, kill_switch: bool
) -> None:
    scenario = load_dataset(DATASET)[0]
    policy, _, _ = _policy_and_prices(
        scenario["request"], enabled=enabled, kill_switch=kill_switch
    )
    decision = evaluate_cost_route(request=_routing_request(scenario), policy=policy)
    assert decision.selected_route_id == policy.baseline_route_id
    assert decision.bypassed


def test_unsafe_baseline_fails_closed_instead_of_buying_availability() -> None:
    scenario = load_dataset(DATASET)[0]
    policy, _, _ = _policy_and_prices(scenario["request"])
    baseline, candidate = policy.snapshots
    policy = replace(
        policy,
        snapshots=(
            replace(
                baseline,
                health=replace(baseline.health, state=ProviderHealth.UNAVAILABLE),
            ),
            candidate,
        ),
    )
    with pytest.raises(CostRouterError, match="router.no_safe_baseline"):
        evaluate_cost_route(request=_routing_request(scenario), policy=policy)


def test_budget_collision_and_overspend_have_zero_effect() -> None:
    ledger = LocalCostLedger(
        budget_scope_digest="a" * 64, budget_limit_microusd=10
    )
    request = CostReservationRequest(
        "replay-reservation",
        "replay-run",
        "a" * 64,
        "deepseek-v4-flash-candidate-v1",
        "b" * 64,
        "deepseek-2026-08-04",
        10,
    )
    ledger.reserve(request)
    before = ledger.snapshot()
    with pytest.raises(CostLedgerError, match="cost_ledger.idempotency_collision"):
        ledger.reserve(replace(request, estimated_microusd=9))
    with pytest.raises(CostLedgerError, match="cost_ledger.budget_exhausted"):
        ledger.reserve(replace(request, idempotency_key="replay-second"))
    assert ledger.snapshot() == before
