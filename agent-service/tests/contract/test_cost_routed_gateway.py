from __future__ import annotations

from decimal import Decimal
import json
from pathlib import Path
import site
import sys
from uuid import uuid4

import httpx
import pytest


SERVICE_ROOT = Path(__file__).resolve().parents[2]
site.addsitedir(str(SERVICE_ROOT / ".venv" / "Lib" / "site-packages"))
sys.path.insert(0, str(SERVICE_ROOT))

from app.models.cost_router import (  # noqa: E402
    CostRoute,
    PriceQuote,
    PrivacyClass,
    ProviderHealth,
    RouteHealth,
    RouteSnapshot,
    RoutingPolicy,
)
from app.models.deepseek import API_ORIGIN as DEEPSEEK_ORIGIN, ROUTE_ID  # noqa: E402
from app.models.gemini import API_ORIGIN as GEMINI_ORIGIN, certified_gemini_routes  # noqa: E402
from app.persistence.repositories.jobs import JobClaim  # noqa: E402
from app.worker.execution import ClaimedItineraryJob  # noqa: E402
from app.worker.itinerary_processor import (  # noqa: E402
    GeminiItineraryProcessor,
    ItineraryCostRoutingConfig,
)


NOW = 1_800_000_000


def _job() -> ClaimedItineraryJob:
    run_id = uuid4()
    return ClaimedItineraryJob(
        claim=JobClaim(
            job_id=uuid4(),
            run_id=run_id,
            tenant_id="tenant-cost-router-contract",
            job_type="itinerary_planning",
            input_ref="job-input://sha256/" + "a" * 64,
            lease_id=uuid4(),
            holder_id="worker-cost-router-contract",
            fencing_token=1,
            attempt_count=1,
            replayed=False,
        ),
        behavior_digest="b" * 64,
        context_policy_digest="d" * 64,
        input_digest="c" * 64,
        structured_input={
            "schema_version": "1.0",
            "origin": "Shanghai",
            "destination": "Hangzhou",
            "starts_on": "2026-08-03",
            "days": 2,
            "budget_minor": 200_000,
            "currency": "CNY",
            "locale": "zh-CN",
            "timezone": "Asia/Shanghai",
            "hard_constraints": [],
        },
    )


def _output() -> dict[str, object]:
    return {
        "title": "Hangzhou itinerary",
        "days": [
            {
                "day_number": day,
                "items": [
                    {
                        "item_id": f"item_day_{day}",
                        "title": f"Day {day}",
                        "start_minute": 600,
                        "duration_minutes": 120,
                    }
                ],
            }
            for day in (1, 2)
        ],
    }


def _price(version: str, input_rate: str, output_rate: str) -> PriceQuote:
    return PriceQuote(
        version,
        NOW - 60,
        3600,
        Decimal(input_rate),
        Decimal(input_rate) / 10,
        Decimal(output_rate),
    )


def _config(*, enabled: bool = True, kill_switch: bool = False) -> ItineraryCostRoutingConfig:
    baseline = certified_gemini_routes().routes[0]
    policy = RoutingPolicy(
        policy_version="p12b-runtime-v1",
        baseline_route_id=baseline.route_id,
        router_enabled=enabled,
        kill_switch=kill_switch,
        snapshots=(
            RouteSnapshot(
                CostRoute(
                    baseline.route_id,
                    baseline.provider_id,
                    baseline.model_id,
                    baseline.capabilities,
                    frozenset({"global"}),
                    frozenset(PrivacyClass),
                    baseline.certification_digest,
                    950_000,
                    4_000,
                    _price("google-2026-08-04", "0.25", "1.50"),
                    False,
                ),
                RouteHealth(ProviderHealth.HEALTHY, NOW - 10, 3600),
            ),
            RouteSnapshot(
                CostRoute(
                    ROUTE_ID,
                    "deepseek-api",
                    "deepseek-v4-flash",
                    frozenset({"json", "complex"}),
                    frozenset({"global"}),
                    frozenset({PrivacyClass.STANDARD}),
                    "d" * 64,
                    950_000,
                    4_000,
                    _price("deepseek-2026-08-04", "0.14", "0.28"),
                    True,
                ),
                RouteHealth(ProviderHealth.HEALTHY, NOW - 10, 3600),
            ),
        ),
    )
    return ItineraryCostRoutingConfig(
        policies=(policy,),
        region="global",
        privacy_class=PrivacyClass.STANDARD,
        quality_floor_ppm=900_000,
        latency_budget_ms=5_000,
        remaining_budget_microusd=20_000,
    )


def _deepseek_response() -> httpx.Response:
    return httpx.Response(
        200,
        json={
            "choices": [
                {
                    "finish_reason": "stop",
                    "message": {"content": json.dumps(_output())},
                }
            ],
            "usage": {
                "prompt_tokens": 120,
                "completion_tokens": 80,
                "prompt_cache_hit_tokens": 0,
                "prompt_cache_miss_tokens": 120,
            },
        },
    )


def _gemini_response() -> httpx.Response:
    return httpx.Response(
        200,
        json={
            "candidates": [
                {
                    "finishReason": "STOP",
                    "content": {"parts": [{"text": json.dumps(_output())}]},
                }
            ],
            "usageMetadata": {
                "promptTokenCount": 120,
                "candidatesTokenCount": 80,
                "totalTokenCount": 200,
            },
        },
    )


def test_default_configuration_keeps_candidate_allocation_zero(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setenv("GEMINI_API_KEY", "synthetic-gemini-credential")
    monkeypatch.setenv("DEEPSEEK_API_KEY", "synthetic-deepseek-credential")
    origins: list[str] = []

    def handler(request: httpx.Request) -> httpx.Response:
        origins.append(f"{request.url.scheme}://{request.url.host}")
        return _gemini_response()

    with httpx.Client(transport=httpx.MockTransport(handler)) as client:
        processor = GeminiItineraryProcessor(client=client, wall_clock=lambda: NOW)
        processor.process(_job())
    assert origins == [GEMINI_ORIGIN]
    assert processor.last_route_decision is None


def test_enabled_policy_uses_fixed_deepseek_route(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setenv("GEMINI_API_KEY", "synthetic-gemini-credential")
    monkeypatch.setenv("DEEPSEEK_API_KEY", "synthetic-deepseek-credential")
    origins: list[str] = []

    def handler(request: httpx.Request) -> httpx.Response:
        origins.append(f"{request.url.scheme}://{request.url.host}")
        assert request.url.path == "/chat/completions"
        return _deepseek_response()

    with httpx.Client(transport=httpx.MockTransport(handler)) as client:
        processor = GeminiItineraryProcessor(
            client=client,
            cost_routing=_config(),
            wall_clock=lambda: NOW,
        )
        processor.process(_job())
    assert origins == [DEEPSEEK_ORIGIN]
    assert processor.last_route_decision is not None
    assert processor.last_route_decision.selected_route_id == ROUTE_ID


def test_retryable_candidate_failure_falls_back_exactly_once_to_gemini(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setenv("GEMINI_API_KEY", "synthetic-gemini-credential")
    monkeypatch.setenv("DEEPSEEK_API_KEY", "synthetic-deepseek-credential")
    origins: list[str] = []

    def handler(request: httpx.Request) -> httpx.Response:
        origin = f"{request.url.scheme}://{request.url.host}"
        origins.append(origin)
        if origin == DEEPSEEK_ORIGIN:
            return httpx.Response(503, json={"error": {}})
        return _gemini_response()

    with httpx.Client(transport=httpx.MockTransport(handler)) as client:
        processor = GeminiItineraryProcessor(
            client=client,
            cost_routing=_config(),
            wall_clock=lambda: NOW,
        )
        processor.process(_job())
    assert origins == [DEEPSEEK_ORIGIN, GEMINI_ORIGIN]
    assert [record.status for record in processor.ledger.records] == [
        "failed",
        "succeeded",
    ]


@pytest.mark.parametrize(("enabled", "kill_switch"), [(False, False), (True, True)])
def test_router_bypass_never_resolves_or_calls_candidate(
    monkeypatch: pytest.MonkeyPatch, enabled: bool, kill_switch: bool
) -> None:
    monkeypatch.setenv("GEMINI_API_KEY", "synthetic-gemini-credential")
    monkeypatch.delenv("DEEPSEEK_API_KEY", raising=False)
    origins: list[str] = []

    def handler(request: httpx.Request) -> httpx.Response:
        origins.append(f"{request.url.scheme}://{request.url.host}")
        return _gemini_response()

    with httpx.Client(transport=httpx.MockTransport(handler)) as client:
        GeminiItineraryProcessor(
            client=client,
            cost_routing=_config(enabled=enabled, kill_switch=kill_switch),
            wall_clock=lambda: NOW,
        ).process(_job())
    assert origins == [GEMINI_ORIGIN]
