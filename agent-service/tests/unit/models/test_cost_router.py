from __future__ import annotations

import dataclasses
import site
import sys
from decimal import Decimal
from pathlib import Path

import pytest


SERVICE_ROOT = Path(__file__).resolve().parents[3]
site.addsitedir(str(SERVICE_ROOT / ".venv" / "Lib" / "site-packages"))
sys.path.insert(0, str(SERVICE_ROOT))

from app.models.cost_router import (  # noqa: E402
    CostRoute,
    CostRouterError,
    PriceQuote,
    PrivacyClass,
    ProviderHealth,
    RouteHealth,
    RouteReason,
    RouteSnapshot,
    RoutingPolicy,
    RoutingRequest,
    evaluate_cost_route,
    policy_digest,
)


NOW = 1_800_000_000
DIGEST = "a" * 64


def _price(
    version: str, input_rate: str, output_rate: str, *, observed: int = NOW - 60
) -> PriceQuote:
    return PriceQuote(
        price_version=version,
        observed_at_epoch_seconds=observed,
        valid_for_seconds=3600,
        input_cache_miss_usd_per_million=Decimal(input_rate),
        input_cache_hit_usd_per_million=Decimal(input_rate) / 10,
        output_usd_per_million=Decimal(output_rate),
    )


def _snapshot(
    route_id: str,
    *,
    experimental: bool,
    price: PriceQuote,
    regions: frozenset[str] = frozenset({"global"}),
    privacy: frozenset[PrivacyClass] = frozenset(PrivacyClass),
    capabilities: frozenset[str] = frozenset({"itinerary_json"}),
    quality: int = 950_000,
    latency: int = 4_000,
    health: ProviderHealth = ProviderHealth.HEALTHY,
    health_observed: int = NOW - 60,
) -> RouteSnapshot:
    return RouteSnapshot(
        route=CostRoute(
            route_id=route_id,
            provider_id="deepseek" if experimental else "google",
            model_id="candidate" if experimental else "baseline",
            capabilities=capabilities,
            allowed_regions=regions,
            allowed_privacy_classes=privacy,
            certification_digest=DIGEST,
            quality_score_ppm=quality,
            latency_p95_ms=latency,
            price=price,
            experimental=experimental,
        ),
        health=RouteHealth(health, health_observed, 3600),
    )


def _request(**changes: object) -> RoutingRequest:
    values: dict[str, object] = {
        "task_class": "itinerary_generation",
        "required_capabilities": frozenset({"itinerary_json"}),
        "region": "global",
        "privacy_class": PrivacyClass.STANDARD,
        "quality_floor_ppm": 900_000,
        "latency_budget_ms": 5_000,
        "remaining_budget_microusd": 10_000,
        "estimated_input_tokens": 1_000,
        "max_output_tokens": 2_000,
        "as_of_epoch_seconds": NOW,
    }
    values.update(changes)
    return RoutingRequest(**values)  # type: ignore[arg-type]


def _policy(
    *,
    candidate: RouteSnapshot | None = None,
    baseline: RouteSnapshot | None = None,
    enabled: bool = True,
    kill_switch: bool = False,
    reverse: bool = False,
) -> RoutingPolicy:
    baseline = baseline or _snapshot(
        "gemini_baseline",
        experimental=False,
        price=_price("google-2026-08-04", "0.25", "1.50"),
    )
    candidate = candidate or _snapshot(
        "deepseek_candidate",
        experimental=True,
        price=_price("deepseek-2026-08-04", "0.14", "0.28"),
    )
    snapshots = (baseline, candidate)
    return RoutingPolicy(
        policy_version="p12b-v1",
        baseline_route_id=baseline.route.route_id,
        router_enabled=enabled,
        kill_switch=kill_switch,
        snapshots=tuple(reversed(snapshots)) if reverse else snapshots,
    )


def test_same_input_is_deterministic_and_policy_order_independent() -> None:
    request = _request()
    first = evaluate_cost_route(request=request, policy=_policy())
    second = evaluate_cost_route(request=request, policy=_policy(reverse=True))
    assert first == second
    assert first.selected_route_id == "deepseek_candidate"
    assert first.reason is RouteReason.CANDIDATE_LOWEST_COST
    assert first.fallback_route_id == "gemini_baseline"


def test_cost_uses_conservative_cache_miss_decimal_and_rounds_up() -> None:
    quote = _price("price-v1", "0.14", "0.28")
    assert quote.estimate_cache_miss_microusd(input_tokens=1, output_tokens=1) == 1
    assert quote.estimate_cache_miss_microusd(input_tokens=1000, output_tokens=2000) == 700


@pytest.mark.parametrize(
    ("candidate", "routing_request"),
    [
        (_snapshot("candidate_region", experimental=True, price=_price("p1", "0.01", "0.01"), regions=frozenset({"eu"})), _request()),
        (_snapshot("candidate_privacy", experimental=True, price=_price("p2", "0.01", "0.01"), privacy=frozenset({PrivacyClass.STANDARD})), _request(privacy_class=PrivacyClass.RESTRICTED)),
        (_snapshot("candidate_capability", experimental=True, price=_price("p3", "0.01", "0.01"), capabilities=frozenset({"text"})), _request()),
        (_snapshot("candidate_quality", experimental=True, price=_price("p4", "0.01", "0.01"), quality=899_999), _request()),
        (_snapshot("candidate_latency", experimental=True, price=_price("p5", "0.01", "0.01"), latency=5_001), _request()),
        (_snapshot("candidate_stale_price", experimental=True, price=_price("p6", "0.01", "0.01", observed=NOW - 3601)), _request()),
        (_snapshot("candidate_unknown", experimental=True, price=_price("p7", "0.01", "0.01"), health=ProviderHealth.UNKNOWN), _request()),
        (_snapshot("candidate_stale_health", experimental=True, price=_price("p8", "0.01", "0.01"), health_observed=NOW - 3601), _request()),
        (_snapshot("candidate_budget", experimental=True, price=_price("p9", "10", "10")), _request(remaining_budget_microusd=5_000)),
    ],
)
def test_guardrail_ineligible_candidate_never_selected(
    candidate: RouteSnapshot, routing_request: RoutingRequest
) -> None:
    decision = evaluate_cost_route(
        request=routing_request, policy=_policy(candidate=candidate)
    )
    assert decision.selected_route_id == "gemini_baseline"
    assert decision.fallback_route_id is None
    assert decision.reason is RouteReason.BASELINE_ONLY_ELIGIBLE


@pytest.mark.parametrize(
    ("enabled", "kill_switch", "reason"),
    [
        (False, False, RouteReason.BASELINE_ROUTER_DISABLED),
        (True, True, RouteReason.BASELINE_KILL_SWITCH),
    ],
)
def test_bypass_always_selects_safe_baseline(
    enabled: bool, kill_switch: bool, reason: RouteReason
) -> None:
    decision = evaluate_cost_route(
        request=_request(), policy=_policy(enabled=enabled, kill_switch=kill_switch)
    )
    assert decision.selected_route_id == "gemini_baseline"
    assert decision.fallback_route_id is None
    assert decision.reason is reason
    assert decision.bypassed


def test_unsafe_baseline_fails_closed_even_with_kill_switch() -> None:
    baseline = _snapshot(
        "gemini_baseline",
        experimental=False,
        price=_price("baseline", "0.25", "1.5"),
        health=ProviderHealth.UNAVAILABLE,
    )
    with pytest.raises(CostRouterError, match="router.no_safe_baseline"):
        evaluate_cost_route(
            request=_request(), policy=_policy(baseline=baseline, kill_switch=True)
        )


def test_tie_break_is_stable_route_id_not_input_order() -> None:
    same_price = _price("same-price", "0.25", "1.5")
    candidate = _snapshot("a_candidate", experimental=True, price=same_price)
    baseline = _snapshot("z_baseline", experimental=False, price=same_price)
    decision = evaluate_cost_route(
        request=_request(), policy=_policy(candidate=candidate, baseline=baseline, reverse=True)
    )
    assert decision.selected_route_id == "a_candidate"


def test_policy_digest_changes_with_versioned_price() -> None:
    changed = _snapshot(
        "deepseek_candidate",
        experimental=True,
        price=_price("deepseek-2026-08-05", "0.14", "0.28"),
    )
    assert policy_digest(_policy()) != policy_digest(_policy(candidate=changed))


def test_decision_and_request_schemas_have_no_sensitive_or_identity_fields() -> None:
    forbidden = {
        "prompt",
        "response",
        "reasoning",
        "secret",
        "credential",
        "tenant_id",
        "user_id",
        "principal_id",
    }
    field_names = {
        field.name
        for value_type in (RoutingRequest, type(evaluate_cost_route(request=_request(), policy=_policy())))
        for field in dataclasses.fields(value_type)
    }
    assert field_names.isdisjoint(forbidden)
    with pytest.raises(TypeError):
        RoutingRequest(**dataclasses.asdict(_request()), prompt="sensitive")  # type: ignore[call-arg]


def test_reason_vocabulary_is_finite_and_content_free() -> None:
    assert {reason.value for reason in RouteReason} == {
        "baseline_router_disabled",
        "baseline_kill_switch",
        "baseline_only_eligible",
        "baseline_lowest_cost",
        "candidate_lowest_cost",
    }
    assert all(len(reason.value) <= 32 for reason in RouteReason)


def test_experimental_fallback_is_exactly_one_hop_to_non_experimental_baseline() -> None:
    decision = evaluate_cost_route(request=_request(), policy=_policy())
    assert decision.selected_route_id != decision.fallback_route_id
    assert decision.fallback_route_id == "gemini_baseline"
    assert _policy().baseline_route_id == decision.fallback_route_id


def test_policy_rejects_experimental_or_missing_baseline() -> None:
    candidate = _snapshot(
        "deepseek_candidate", experimental=True, price=_price("candidate", "0.1", "0.2")
    )
    with pytest.raises(CostRouterError, match="router.policy_invalid"):
        RoutingPolicy("p12b-v1", "deepseek_candidate", True, False, (candidate,))
