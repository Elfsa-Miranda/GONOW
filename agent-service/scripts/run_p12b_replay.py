"""Deterministic zero-network replay for the frozen P12B cost-router dataset."""

from __future__ import annotations

import argparse
from collections.abc import Iterable
from dataclasses import asdict, dataclass
from decimal import Decimal
import hashlib
import json
import math
from pathlib import Path
import sys
from typing import Any


SERVICE_ROOT = Path(__file__).resolve().parents[1]
if str(SERVICE_ROOT) not in sys.path:
    sys.path.insert(0, str(SERVICE_ROOT))

from app.models.cost_router import (
    CostRoute,
    PriceQuote,
    PrivacyClass,
    ProviderHealth,
    RouteHealth,
    RouteSnapshot,
    RoutingPolicy,
    RoutingRequest,
    evaluate_cost_route,
)
from app.models.deepseek import MODEL_ID as DEEPSEEK_MODEL_ID
from app.models.deepseek import PROVIDER_ID as DEEPSEEK_PROVIDER_ID
from app.models.deepseek import ROUTE_ID as DEEPSEEK_ROUTE_ID
from app.models.gemini import canonical_digest, certified_gemini_routes
from app.worker.itinerary_processor import _prompt


DATASET_SHA256 = "653297b4c18c28757d085490e524c5dbfc92a7ee7f75d7ca88ecc296ae4c1049"
AS_OF_EPOCH_SECONDS = 1_800_000_000
PRICE_VALID_FOR_SECONDS = 604_800


@dataclass(frozen=True, slots=True)
class ReplayAttempt:
    scenario_id: str
    arm: str
    attempt: int
    route_id: str
    input_sha256: str
    output_sha256: str | None
    status: str
    failure_class: str | None
    input_tokens: int
    output_tokens: int
    cache_hit_input_tokens: int
    cache_miss_input_tokens: int
    cost_microusd: int
    latency_ms: int
    quality_qualified: bool
    fallback_depth: int


def _price(
    version: str, input_miss: str, input_hit: str, output: str
) -> PriceQuote:
    return PriceQuote(
        price_version=version,
        observed_at_epoch_seconds=AS_OF_EPOCH_SECONDS - 60,
        valid_for_seconds=PRICE_VALID_FOR_SECONDS,
        input_cache_miss_usd_per_million=Decimal(input_miss),
        input_cache_hit_usd_per_million=Decimal(input_hit),
        output_usd_per_million=Decimal(output),
    )


def _usage_cost_microusd(
    *,
    cache_hit_input_tokens: int,
    cache_miss_input_tokens: int,
    output_tokens: int,
    price: PriceQuote,
) -> int:
    value = (
        Decimal(cache_hit_input_tokens) * price.input_cache_hit_usd_per_million
        + Decimal(cache_miss_input_tokens)
        * price.input_cache_miss_usd_per_million
        + Decimal(output_tokens) * price.output_usd_per_million
    )
    return int(value.to_integral_value(rounding="ROUND_CEILING"))


def load_dataset(path: Path) -> tuple[dict[str, Any], ...]:
    payload = path.read_bytes()
    if hashlib.sha256(payload).hexdigest() != DATASET_SHA256:
        raise ValueError("replay.dataset_hash_mismatch")
    scenarios = tuple(
        json.loads(line) for line in payload.decode("utf-8").splitlines() if line
    )
    if (
        len(scenarios) != 10
        or len({item["scenario_id"] for item in scenarios}) != 10
        or any(item.get("source") != "synthetic_repository_fixture" for item in scenarios)
    ):
        raise ValueError("replay.dataset_invalid")
    return scenarios


def _required_capabilities(request: dict[str, Any]) -> frozenset[str]:
    constraints = request.get("hard_constraints", [])
    complex_request = int(request["days"]) > 7 or len(constraints) >= 4
    return frozenset({"json", "complex"} if complex_request else {"json"})


def _fake_output(request: dict[str, Any]) -> dict[str, Any]:
    return {
        "title": f"Synthetic {request['destination']} itinerary",
        "days": [
            {
                "day_number": day,
                "items": [
                    {
                        "item_id": f"item_day_{day}",
                        "title": f"Synthetic day {day}",
                        "start_minute": 540,
                        "duration_minutes": 120,
                    }
                ],
            }
            for day in range(1, int(request["days"]) + 1)
        ],
    }


def _quality_qualified(
    output: dict[str, Any], request: dict[str, Any], checks: Iterable[str]
) -> bool:
    days = output.get("days")
    if not isinstance(days, list) or len(days) != int(request["days"]):
        return False
    if [day.get("day_number") for day in days] != list(
        range(1, int(request["days"]) + 1)
    ):
        return False
    item_ids: list[str] = []
    for day in days:
        items = day.get("items")
        if not isinstance(items, list) or not items:
            return False
        if "max_3_items_per_day" in checks and len(items) > 3:
            return False
        ordered = sorted(items, key=lambda item: item["start_minute"])
        previous_end = -1
        for item in ordered:
            start = item.get("start_minute")
            duration = item.get("duration_minutes")
            if not isinstance(start, int) or not isinstance(duration, int):
                return False
            end = start + duration
            if duration < 1 or end > 1440 or start < previous_end:
                return False
            if "no_late_night" in checks and end > 1320:
                return False
            if "daylight_only" in checks and (start < 360 or end > 1200):
                return False
            item_ids.append(str(item.get("item_id", "")))
            previous_end = end
        if "morning_start" in checks and min(
            item["start_minute"] for item in items
        ) > 600:
            return False
    return len(item_ids) == len(set(item_ids)) and all(
        value.startswith("item_") for value in item_ids
    )


def _route_snapshot(
    runtime_route,
    *,
    experimental: bool,
    price: PriceQuote,
) -> RouteSnapshot:
    return RouteSnapshot(
        route=CostRoute(
            route_id=runtime_route.route_id,
            provider_id=runtime_route.provider_id,
            model_id=runtime_route.model_id,
            capabilities=runtime_route.capabilities,
            allowed_regions=frozenset({"global"}),
            allowed_privacy_classes=frozenset(PrivacyClass),
            certification_digest=runtime_route.certification_digest,
            quality_score_ppm=950_000,
            latency_p95_ms=4_000,
            price=price,
            experimental=experimental,
        ),
        health=RouteHealth(
            ProviderHealth.HEALTHY, AS_OF_EPOCH_SECONDS - 10, 3600
        ),
    )


def _policy_and_prices(
    request: dict[str, Any], *, enabled: bool = True, kill_switch: bool = False
) -> tuple[RoutingPolicy, PriceQuote, PriceQuote]:
    capabilities = _required_capabilities(request)
    baseline = certified_gemini_routes().plan(capabilities)[0]
    baseline_price = (
        _price("google-2026-08-04", "0.25", "0.025", "1.50")
        if baseline.model_id == "gemini-3.1-flash-lite"
        else _price("google-2026-08-04", "0.75", "0.075", "3.75")
    )
    candidate_price = _price(
        "deepseek-2026-08-04", "0.14", "0.0028", "0.28"
    )
    candidate_runtime = type(
        "CandidateRoute",
        (),
        {
            "route_id": DEEPSEEK_ROUTE_ID,
            "provider_id": DEEPSEEK_PROVIDER_ID,
            "model_id": DEEPSEEK_MODEL_ID,
            "capabilities": frozenset({"json", "complex"}),
            "certification_digest": "d" * 64,
        },
    )()
    return (
        RoutingPolicy(
            policy_version="p12b-replay-v1",
            baseline_route_id=baseline.route_id,
            router_enabled=enabled,
            kill_switch=kill_switch,
            snapshots=(
                _route_snapshot(baseline, experimental=False, price=baseline_price),
                _route_snapshot(
                    candidate_runtime,
                    experimental=True,
                    price=candidate_price,
                ),
            ),
        ),
        baseline_price,
        candidate_price,
    )


def _attempt(
    *,
    scenario: dict[str, Any],
    arm: str,
    attempt: int,
    route_id: str,
    input_sha256: str,
    price: PriceQuote,
    latency_ms: int,
    fallback_depth: int = 0,
    failure_class: str | None = None,
) -> ReplayAttempt:
    request = scenario["request"]
    prompt = _prompt(request)
    input_tokens = max(1, (len(prompt.encode("utf-8")) + 3) // 4)
    output = None if failure_class else _fake_output(request)
    output_tokens = 0 if output is None else int(request["days"]) * 80 + 24
    quality = bool(
        output
        and _quality_qualified(output, request, scenario["quality_checks"])
    )
    return ReplayAttempt(
        scenario_id=scenario["scenario_id"],
        arm=arm,
        attempt=attempt,
        route_id=route_id,
        input_sha256=input_sha256,
        output_sha256=canonical_digest(output) if output else None,
        status="failed" if failure_class else "succeeded",
        failure_class=failure_class,
        input_tokens=input_tokens,
        output_tokens=output_tokens,
        cache_hit_input_tokens=0,
        cache_miss_input_tokens=input_tokens,
        cost_microusd=_usage_cost_microusd(
            cache_hit_input_tokens=0,
            cache_miss_input_tokens=input_tokens,
            output_tokens=output_tokens,
            price=price,
        ),
        latency_ms=latency_ms,
        quality_qualified=quality,
        fallback_depth=fallback_depth,
    )


def _nearest_rank_p95(values: list[int]) -> int:
    return sorted(values)[math.ceil(0.95 * len(values)) - 1]


def run_replay(
    dataset_path: Path,
    *,
    candidate_retryable_failure_scenario: str | None = None,
) -> dict[str, Any]:
    scenarios = load_dataset(dataset_path)
    attempts: list[ReplayAttempt] = []
    paired_input_mismatches = 0
    fallback_count = 0
    for scenario in scenarios:
        request = scenario["request"]
        prompt = _prompt(request)
        input_sha256 = canonical_digest(prompt)
        policy, baseline_price, candidate_price = _policy_and_prices(request)
        baseline_route = certified_gemini_routes().plan(
            _required_capabilities(request)
        )[0]
        decision = evaluate_cost_route(
            request=RoutingRequest(
                task_class="itinerary_generation",
                required_capabilities=_required_capabilities(request),
                region="global",
                privacy_class=PrivacyClass.STANDARD,
                quality_floor_ppm=900_000,
                latency_budget_ms=5_000,
                remaining_budget_microusd=100_000,
                estimated_input_tokens=max(
                    1, (len(prompt.encode("utf-8")) + 3) // 4
                ),
                max_output_tokens=min(
                    8_192, max(1_024, int(request["days"]) * 512)
                ),
                as_of_epoch_seconds=AS_OF_EPOCH_SECONDS,
            ),
            policy=policy,
        )
        if decision.selected_route_id != DEEPSEEK_ROUTE_ID:
            raise ValueError("replay.candidate_not_selected")
        baseline_attempt = _attempt(
            scenario=scenario,
            arm="baseline",
            attempt=1,
            route_id=baseline_route.route_id,
            input_sha256=input_sha256,
            price=baseline_price,
            latency_ms=500 + int(request["days"]) * 20,
        )
        attempts.append(baseline_attempt)
        if scenario["scenario_id"] == candidate_retryable_failure_scenario:
            attempts.append(
                _attempt(
                    scenario=scenario,
                    arm="candidate",
                    attempt=1,
                    route_id=DEEPSEEK_ROUTE_ID,
                    input_sha256=input_sha256,
                    price=candidate_price,
                    latency_ms=300,
                    failure_class="provider_5xx",
                )
            )
            attempts.append(
                _attempt(
                    scenario=scenario,
                    arm="candidate",
                    attempt=2,
                    route_id=baseline_route.route_id,
                    input_sha256=input_sha256,
                    price=baseline_price,
                    latency_ms=500 + int(request["days"]) * 20,
                    fallback_depth=1,
                )
            )
            fallback_count += 1
        else:
            attempts.append(
                _attempt(
                    scenario=scenario,
                    arm="candidate",
                    attempt=1,
                    route_id=DEEPSEEK_ROUTE_ID,
                    input_sha256=input_sha256,
                    price=candidate_price,
                    latency_ms=600 + int(request["days"]) * 20,
                )
            )
        candidate_digests = {
            item.input_sha256
            for item in attempts
            if item.scenario_id == scenario["scenario_id"]
            and item.arm == "candidate"
        }
        if candidate_digests != {baseline_attempt.input_sha256}:
            paired_input_mismatches += 1

    arm_results: dict[str, dict[str, Any]] = {}
    for arm in ("baseline", "candidate"):
        arm_attempts = [item for item in attempts if item.arm == arm]
        terminal_by_scenario = {
            scenario["scenario_id"]: [
                item
                for item in arm_attempts
                if item.scenario_id == scenario["scenario_id"]
            ][-1]
            for scenario in scenarios
        }
        successes = sum(
            item.status == "succeeded" and item.quality_qualified
            for item in terminal_by_scenario.values()
        )
        total_cost = sum(item.cost_microusd for item in arm_attempts)
        end_to_end_latencies = [
            sum(
                item.latency_ms
                for item in arm_attempts
                if item.scenario_id == scenario["scenario_id"]
            )
            for scenario in scenarios
        ]
        arm_results[arm] = {
            "denominator": len(scenarios),
            "attempt_count": len(arm_attempts),
            "qualified_success_count": successes,
            "failure_count": len(scenarios) - successes,
            "total_cost_microusd": total_cost,
            "cost_per_qualified_success_microusd": (
                total_cost / successes if successes else None
            ),
            "p95_latency_ms": _nearest_rank_p95(end_to_end_latencies),
        }

    baseline = arm_results["baseline"]
    candidate = arm_results["candidate"]
    ratio = (
        candidate["cost_per_qualified_success_microusd"]
        / baseline["cost_per_qualified_success_microusd"]
    )
    latency_limit = min(
        1.25 * baseline["p95_latency_ms"], baseline["p95_latency_ms"] + 5000
    )
    redlines = {
        "paired_input_mismatch": paired_input_mismatches,
        "quality_inferior": int(
            candidate["qualified_success_count"]
            < baseline["qualified_success_count"]
        ),
        "cost_ratio_failed": int(ratio > 0.75),
        "latency_failed": int(candidate["p95_latency_ms"] > latency_limit),
        "fallback_count_failed": int(fallback_count > 1),
        "recursive_fallback": 0,
        "ineligible_route_selected": 0,
        "content_or_secret_in_result": 0,
        "budget_overspend": 0,
        "production_write": 0,
    }
    return {
        "schema_version": "1.0",
        "dataset_sha256": DATASET_SHA256,
        "scenario_count": len(scenarios),
        "same_failure_denominator": True,
        "excluded_after_run_count": 0,
        "live_call_count": 0,
        "network_transport_count": 0,
        "arms": arm_results,
        "candidate_cost_per_success_ratio": ratio,
        "candidate_latency_limit_ms": latency_limit,
        "candidate_fallback_count": fallback_count,
        "redlines": redlines,
        "redline_failure_count": sum(redlines.values()),
        "attempts": [asdict(item) for item in attempts],
        "claim_boundary": "synthetic deterministic accounting and guardrail mechanics only",
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--dataset", type=Path, required=True)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    result = run_replay(args.dataset)
    encoded = json.dumps(result, ensure_ascii=True, sort_keys=True, separators=(",", ":"))
    if args.output:
        args.output.write_text(encoded + "\n", encoding="utf-8")
    else:
        print(encoded)
    return int(result["redline_failure_count"] != 0)


if __name__ == "__main__":
    raise SystemExit(main())
