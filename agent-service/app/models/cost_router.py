"""Pure, deterministic and content-free cost-routing policy.

The policy deliberately receives time, prices, health and budget as immutable
inputs.  It performs no I/O and cannot inspect prompts, model output or tenant
identity.  Eligibility guardrails are evaluated before cost ordering.
"""

from __future__ import annotations

import hashlib
import json
import re
from dataclasses import dataclass
from decimal import Decimal, ROUND_CEILING
from enum import StrEnum
from typing import Any


_SHA256 = re.compile(r"^[0-9a-f]{64}$")
_IDENTIFIER = re.compile(r"^[a-z0-9][a-z0-9._:-]{0,127}$")
_ONE_MILLION = 1_000_000


class CostRouterError(ValueError):
    """A stable, content-free policy failure."""

    def __init__(self, code: str) -> None:
        self.code = code
        super().__init__(code)


class PrivacyClass(StrEnum):
    STANDARD = "standard"
    RESTRICTED = "restricted"


class ProviderHealth(StrEnum):
    HEALTHY = "healthy"
    DEGRADED = "degraded"
    UNAVAILABLE = "unavailable"
    UNKNOWN = "unknown"


class RouteReason(StrEnum):
    BASELINE_ROUTER_DISABLED = "baseline_router_disabled"
    BASELINE_KILL_SWITCH = "baseline_kill_switch"
    BASELINE_ONLY_ELIGIBLE = "baseline_only_eligible"
    BASELINE_LOWEST_COST = "baseline_lowest_cost"
    CANDIDATE_LOWEST_COST = "candidate_lowest_cost"


@dataclass(frozen=True, slots=True)
class PriceQuote:
    price_version: str
    observed_at_epoch_seconds: int
    valid_for_seconds: int
    input_cache_miss_usd_per_million: Decimal
    input_cache_hit_usd_per_million: Decimal
    output_usd_per_million: Decimal

    def __post_init__(self) -> None:
        rates = (
            self.input_cache_miss_usd_per_million,
            self.input_cache_hit_usd_per_million,
            self.output_usd_per_million,
        )
        if (
            _IDENTIFIER.fullmatch(self.price_version) is None
            or self.observed_at_epoch_seconds < 0
            or self.valid_for_seconds <= 0
            or any(not rate.is_finite() or rate < 0 for rate in rates)
        ):
            raise CostRouterError("router.price_invalid")

    def is_fresh(self, as_of_epoch_seconds: int) -> bool:
        return (
            self.observed_at_epoch_seconds <= as_of_epoch_seconds
            < self.observed_at_epoch_seconds + self.valid_for_seconds
        )

    def estimate_cache_miss_microusd(
        self, *, input_tokens: int, output_tokens: int
    ) -> int:
        if input_tokens < 0 or output_tokens < 0:
            raise CostRouterError("router.token_estimate_invalid")
        # USD / million-token numerically equals micro-USD / token.
        estimate = (
            Decimal(input_tokens) * self.input_cache_miss_usd_per_million
            + Decimal(output_tokens) * self.output_usd_per_million
        )
        return int(estimate.to_integral_value(rounding=ROUND_CEILING))


@dataclass(frozen=True, slots=True)
class CostRoute:
    route_id: str
    provider_id: str
    model_id: str
    capabilities: frozenset[str]
    allowed_regions: frozenset[str]
    allowed_privacy_classes: frozenset[PrivacyClass]
    certification_digest: str
    quality_score_ppm: int
    latency_p95_ms: int
    price: PriceQuote
    experimental: bool

    def __post_init__(self) -> None:
        identifiers = (self.route_id, self.provider_id, self.model_id)
        if (
            any(_IDENTIFIER.fullmatch(value) is None for value in identifiers)
            or not self.capabilities
            or not self.allowed_regions
            or not self.allowed_privacy_classes
            or any(_IDENTIFIER.fullmatch(value) is None for value in self.capabilities)
            or any(_IDENTIFIER.fullmatch(value) is None for value in self.allowed_regions)
            or _SHA256.fullmatch(self.certification_digest) is None
            or not 0 <= self.quality_score_ppm <= _ONE_MILLION
            or self.latency_p95_ms <= 0
        ):
            raise CostRouterError("router.route_invalid")


@dataclass(frozen=True, slots=True)
class RouteHealth:
    state: ProviderHealth
    observed_at_epoch_seconds: int
    valid_for_seconds: int

    def __post_init__(self) -> None:
        if self.observed_at_epoch_seconds < 0 or self.valid_for_seconds <= 0:
            raise CostRouterError("router.health_invalid")

    def is_fresh(self, as_of_epoch_seconds: int) -> bool:
        return (
            self.observed_at_epoch_seconds <= as_of_epoch_seconds
            < self.observed_at_epoch_seconds + self.valid_for_seconds
        )


@dataclass(frozen=True, slots=True)
class RouteSnapshot:
    route: CostRoute
    health: RouteHealth


@dataclass(frozen=True, slots=True)
class RoutingRequest:
    task_class: str
    required_capabilities: frozenset[str]
    region: str
    privacy_class: PrivacyClass
    quality_floor_ppm: int
    latency_budget_ms: int
    remaining_budget_microusd: int
    estimated_input_tokens: int
    max_output_tokens: int
    as_of_epoch_seconds: int

    def __post_init__(self) -> None:
        if (
            _IDENTIFIER.fullmatch(self.task_class) is None
            or _IDENTIFIER.fullmatch(self.region) is None
            or not self.required_capabilities
            or any(
                _IDENTIFIER.fullmatch(value) is None
                for value in self.required_capabilities
            )
            or not 0 <= self.quality_floor_ppm <= _ONE_MILLION
            or self.latency_budget_ms <= 0
            or self.remaining_budget_microusd < 0
            or self.estimated_input_tokens < 0
            or self.max_output_tokens <= 0
            or self.as_of_epoch_seconds < 0
        ):
            raise CostRouterError("router.request_invalid")


@dataclass(frozen=True, slots=True)
class RoutingPolicy:
    policy_version: str
    baseline_route_id: str
    router_enabled: bool
    kill_switch: bool
    snapshots: tuple[RouteSnapshot, ...]

    def __post_init__(self) -> None:
        route_ids = tuple(snapshot.route.route_id for snapshot in self.snapshots)
        baseline = tuple(
            snapshot.route
            for snapshot in self.snapshots
            if snapshot.route.route_id == self.baseline_route_id
        )
        if (
            _IDENTIFIER.fullmatch(self.policy_version) is None
            or _IDENTIFIER.fullmatch(self.baseline_route_id) is None
            or not self.snapshots
            or len(route_ids) != len(set(route_ids))
            or len(baseline) != 1
            or baseline[0].experimental
        ):
            raise CostRouterError("router.policy_invalid")


@dataclass(frozen=True, slots=True)
class CostRouteDecision:
    selected_route_id: str
    fallback_route_id: str | None
    reason: RouteReason
    policy_digest: str
    input_class_digest: str
    price_version: str
    estimated_cost_microusd: int
    eligible_route_count: int
    bypassed: bool


def _canonical(value: Any) -> Any:
    if isinstance(value, Decimal):
        return format(value, "f")
    if isinstance(value, StrEnum):
        return value.value
    if isinstance(value, frozenset):
        return sorted(_canonical(item) for item in value)
    if isinstance(value, tuple):
        return [_canonical(item) for item in value]
    if hasattr(value, "__dataclass_fields__"):
        return {
            name: _canonical(getattr(value, name))
            for name in value.__dataclass_fields__
        }
    return value


def _digest(value: Any) -> str:
    payload = json.dumps(
        _canonical(value), ensure_ascii=True, sort_keys=True, separators=(",", ":")
    ).encode("utf-8")
    return hashlib.sha256(payload).hexdigest()


def policy_digest(policy: RoutingPolicy) -> str:
    """Return an ordering-independent digest of the immutable policy snapshot."""

    ordered = RoutingPolicy(
        policy_version=policy.policy_version,
        baseline_route_id=policy.baseline_route_id,
        router_enabled=policy.router_enabled,
        kill_switch=policy.kill_switch,
        snapshots=tuple(
            sorted(policy.snapshots, key=lambda item: item.route.route_id)
        ),
    )
    return _digest(ordered)


def input_class_digest(request: RoutingRequest) -> str:
    """Digest only the closed, typed routing factors (never content or identity)."""

    return _digest(request)


def _estimated_cost(snapshot: RouteSnapshot, request: RoutingRequest) -> int:
    return snapshot.route.price.estimate_cache_miss_microusd(
        input_tokens=request.estimated_input_tokens,
        output_tokens=request.max_output_tokens,
    )


def _eligible(snapshot: RouteSnapshot, request: RoutingRequest) -> bool:
    route = snapshot.route
    cost = _estimated_cost(snapshot, request)
    return (
        request.required_capabilities.issubset(route.capabilities)
        and request.region in route.allowed_regions
        and request.privacy_class in route.allowed_privacy_classes
        and route.quality_score_ppm >= request.quality_floor_ppm
        and route.latency_p95_ms <= request.latency_budget_ms
        and route.price.is_fresh(request.as_of_epoch_seconds)
        and snapshot.health.state is ProviderHealth.HEALTHY
        and snapshot.health.is_fresh(request.as_of_epoch_seconds)
        and cost <= request.remaining_budget_microusd
    )


def evaluate_cost_route(
    *, request: RoutingRequest, policy: RoutingPolicy
) -> CostRouteDecision:
    """Select a certified route deterministically or fail closed.

    The baseline must satisfy every guardrail even when the router is bypassed.
    Experimental fallback is exactly one hop to that baseline.
    """

    by_id = {snapshot.route.route_id: snapshot for snapshot in policy.snapshots}
    baseline = by_id[policy.baseline_route_id]
    if not _eligible(baseline, request):
        raise CostRouterError("router.no_safe_baseline")

    eligible = tuple(
        snapshot for snapshot in policy.snapshots if _eligible(snapshot, request)
    )
    if not policy.router_enabled:
        selected = baseline
        reason = RouteReason.BASELINE_ROUTER_DISABLED
        bypassed = True
    elif policy.kill_switch:
        selected = baseline
        reason = RouteReason.BASELINE_KILL_SWITCH
        bypassed = True
    else:
        ranked = sorted(
            eligible,
            key=lambda snapshot: (
                _estimated_cost(snapshot, request),
                snapshot.route.route_id,
            ),
        )
        selected = ranked[0]
        bypassed = False
        if len(eligible) == 1:
            reason = RouteReason.BASELINE_ONLY_ELIGIBLE
        elif selected is baseline:
            reason = RouteReason.BASELINE_LOWEST_COST
        else:
            reason = RouteReason.CANDIDATE_LOWEST_COST

    route = selected.route
    return CostRouteDecision(
        selected_route_id=route.route_id,
        fallback_route_id=(baseline.route.route_id if route.experimental else None),
        reason=reason,
        policy_digest=policy_digest(policy),
        input_class_digest=input_class_digest(request),
        price_version=route.price.price_version,
        estimated_cost_microusd=_estimated_cost(selected, request),
        eligible_route_count=len(eligible),
        bypassed=bypassed,
    )
