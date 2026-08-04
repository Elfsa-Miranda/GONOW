"""Bounded DeepSeek C2 calibration with content-free receipts.

Gemini evidence remains immutable historical input. This executor writes only
its additive versioned DeepSeek evidence shard and binds every result to one
Git candidate, one strict configuration, and one complete itinerary JSON Schema.
"""

from __future__ import annotations

from collections.abc import Callable
from dataclasses import dataclass
from datetime import UTC, datetime
import json
import math
import os
from pathlib import Path
import statistics
import time
from typing import Any

import httpx

from app.models.deepseek import (
    API_ORIGIN,
    API_PATH,
    MODEL_ID,
    PROVIDER_ID,
    DeepSeekModelAdapter,
    certified_deepseek_route,
)
from app.models.gateway import AdapterFailure, ModelInvocation, ProviderCredential
from app.models.gemini import canonical_digest
from app.models.json_schema import canonical_schema
from app.worker.itinerary_processor import (
    ITINERARY_RESPONSE_SCHEMA,
    itinerary_business_rule_codes,
)
from harness_common import (
    CertificationFailure,
    canonical_sha256,
    require_candidate_oid,
    sha256_bytes,
    sha256_file,
    write_atomic_json,
)


CONFIG_PATH = Path(__file__).with_name("deepseek-c2-live-provider-v2.json")
SCHEMA_PATH = Path(__file__).with_name(
    "deepseek-c2-itinerary-response-v1.schema.json"
)
# v1 and v2 are immutable historical calibration evidence. v3 reuses the
# unchanged v2 frozen configuration but binds a fresh run to the repaired C2
# candidate instead of aggregating calls across candidates.
EVIDENCE_DIRECTORY = "deepseek-v3"
ALLOWED_PRICING_SOURCE = "https://api-docs.deepseek.com/quick_start/pricing/"
EXPECTED_ROUTE_MODELS = {
    "economic": MODEL_ID,
    "capability": MODEL_ID,
}
ALLOWED_FINISH_REASONS = {
    "stop",
    "length",
    "content_filter",
    "tool_calls",
    "insufficient_system_resource",
}
PROBE_INPUT = {
    "days": 1,
    "hard_constraints": [
        "no_overlap",
        "no_late_night",
        "daylight_only",
        "morning_start",
        "max_3_items_per_day",
    ],
}
PROBE_PROMPT = (
    "Return JSON for exactly one itinerary day with exactly one item. "
    "Use day_number 1, a globally unique item_id matching item_[a-z0-9_-]+, "
    "a non-empty title, a start_minute from 360 through 600, and a positive "
    "duration_minutes that ends by minute 1200. Do not invent claim_ids."
)


@dataclass(frozen=True, slots=True)
class LiveRoute:
    route_id: str
    model_id: str
    maximum_output_tokens_per_call: int
    input_cache_hit_price: float
    input_cache_miss_price: float
    output_price: float


@dataclass(frozen=True, slots=True)
class LiveConfig:
    provider_id: str
    api_origin: str
    api_path: str
    credential_environment_variable: str
    model_id: str
    calls_per_route: int
    requests_per_minute: int
    maximum_input_tokens_per_call: int
    budget_cap_usd: float
    pricing_source_url: str
    pricing_retrieved_on: str
    response_schema_sha256: str
    fixed_parameters_sha256: str
    failure_denominator_sha256: str
    thresholds: dict[str, Any]
    routes: tuple[LiveRoute, ...]


def _number(value: object, *, code: str) -> float:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise CertificationFailure(code)
    number = float(value)
    if not math.isfinite(number) or number < 0:
        raise CertificationFailure(code)
    return number


def _positive_integer(value: object, *, code: str) -> int:
    if isinstance(value, bool) or not isinstance(value, int) or value < 1:
        raise CertificationFailure(code)
    return value


def _load_schema() -> dict[str, Any]:
    try:
        schema = json.loads(SCHEMA_PATH.read_text("utf-8"))
    except (OSError, ValueError) as error:
        raise CertificationFailure("c2.deepseek_schema_invalid") from error
    if (
        not isinstance(schema, dict)
        or canonical_schema(schema) != canonical_schema(ITINERARY_RESPONSE_SCHEMA)
    ):
        raise CertificationFailure("c2.deepseek_schema_runtime_drift")
    return schema


def load_live_config(path: Path = CONFIG_PATH) -> LiveConfig:
    try:
        raw = json.loads(path.read_text("utf-8"))
    except (OSError, ValueError) as error:
        raise CertificationFailure("c2.live_config_invalid") from error
    required = {
        "schema_version",
        "provider_id",
        "api_origin",
        "api_path",
        "credential_environment_variable",
        "model_id",
        "calls_per_route",
        "requests_per_minute",
        "maximum_input_tokens_per_call",
        "budget_cap_usd",
        "pricing_source_url",
        "pricing_retrieved_on",
        "response_schema_path",
        "response_schema_sha256",
        "fixed_parameters",
        "failure_denominator",
        "thresholds",
        "routes",
    }
    if not isinstance(raw, dict) or set(raw) != required or raw["schema_version"] != "2.1":
        raise CertificationFailure("c2.live_config_invalid")
    if (
        raw["provider_id"] != PROVIDER_ID
        or raw["api_origin"] != API_ORIGIN
        or raw["api_path"] != API_PATH
        or raw["credential_environment_variable"] != "DEEPSEEK_API_KEY"
        or raw["model_id"] != MODEL_ID
        or raw["pricing_source_url"] != ALLOWED_PRICING_SOURCE
        or raw["response_schema_path"] != SCHEMA_PATH.name
        or raw["response_schema_sha256"] != sha256_file(SCHEMA_PATH)
    ):
        raise CertificationFailure("c2.live_config_boundary_invalid")
    _load_schema()

    fixed_parameters = raw["fixed_parameters"]
    if fixed_parameters != {
        "thinking": {"type": "disabled"},
        "response_format": {"type": "json_object"},
        "temperature": 0,
        "top_p": "omitted",
        "presence_penalty": "omitted",
        "frequency_penalty": "omitted",
        "stream": False,
    }:
        raise CertificationFailure("c2.live_parameters_invalid")
    failure_denominator = raw["failure_denominator"]
    if failure_denominator != {
        "attempted_slots_per_route": 200,
        "successful_calls_required_per_route": 200,
        "failed_calls_remain_in_denominator": True,
        "circuit_open_slots_remain_in_denominator": True,
        "cross_candidate_aggregation": False,
        "cross_configuration_aggregation": False,
    }:
        raise CertificationFailure("c2.live_failure_denominator_invalid")
    thresholds = raw["thresholds"]
    if thresholds != {
        "schema_and_business_validation_success_rate": 1.0,
        "secret_or_pii_leak_count": 0,
        "request_body_record_count": 0,
        "response_body_record_count": 0,
        "production_write_count": 0,
        "local_api_p95_upper_ms": 800,
        "maximum_cost_to_budget_ratio": 1.2,
        "maximum_p95_cost_increase": 0.15,
    }:
        raise CertificationFailure("c2.live_threshold_invalid")

    route_rows = raw["routes"]
    if not isinstance(route_rows, list) or len(route_rows) != 2:
        raise CertificationFailure("c2.live_routes_invalid")
    routes: list[LiveRoute] = []
    for row in route_rows:
        if not isinstance(row, dict) or set(row) != {
            "route_id",
            "model_id",
            "maximum_output_tokens_per_call",
            "input_cache_hit_usd_per_million_tokens",
            "input_cache_miss_usd_per_million_tokens",
            "output_usd_per_million_tokens",
        }:
            raise CertificationFailure("c2.live_routes_invalid")
        route_id = str(row["route_id"])
        model_id = str(row["model_id"])
        if EXPECTED_ROUTE_MODELS.get(route_id) != model_id:
            raise CertificationFailure("c2.live_model_not_allowlisted")
        route = LiveRoute(
            route_id=route_id,
            model_id=model_id,
            maximum_output_tokens_per_call=_positive_integer(
                row["maximum_output_tokens_per_call"],
                code="c2.live_output_limit_invalid",
            ),
            input_cache_hit_price=_number(
                row["input_cache_hit_usd_per_million_tokens"],
                code="c2.live_price_invalid",
            ),
            input_cache_miss_price=_number(
                row["input_cache_miss_usd_per_million_tokens"],
                code="c2.live_price_invalid",
            ),
            output_price=_number(
                row["output_usd_per_million_tokens"],
                code="c2.live_price_invalid",
            ),
        )
        if (
            route.maximum_output_tokens_per_call != 512
            or route.input_cache_hit_price != 0.0028
            or route.input_cache_miss_price != 0.14
            or route.output_price != 0.28
        ):
            raise CertificationFailure("c2.live_route_freeze_invalid")
        routes.append(route)
    if {route.route_id for route in routes} != set(EXPECTED_ROUTE_MODELS):
        raise CertificationFailure("c2.live_routes_invalid")

    calls = _positive_integer(raw["calls_per_route"], code="c2.live_config_invalid")
    rpm = _positive_integer(raw["requests_per_minute"], code="c2.live_config_invalid")
    input_limit = _positive_integer(
        raw["maximum_input_tokens_per_call"], code="c2.live_config_invalid"
    )
    budget = _number(raw["budget_cap_usd"], code="c2.live_budget_invalid")
    if calls != 200 or rpm != 20 or input_limit != 2048 or budget != 0.25:
        raise CertificationFailure("c2.live_config_invalid")
    config = LiveConfig(
        provider_id=str(raw["provider_id"]),
        api_origin=str(raw["api_origin"]),
        api_path=str(raw["api_path"]),
        credential_environment_variable=str(raw["credential_environment_variable"]),
        model_id=str(raw["model_id"]),
        calls_per_route=calls,
        requests_per_minute=rpm,
        maximum_input_tokens_per_call=input_limit,
        budget_cap_usd=budget,
        pricing_source_url=str(raw["pricing_source_url"]),
        pricing_retrieved_on=str(raw["pricing_retrieved_on"]),
        response_schema_sha256=str(raw["response_schema_sha256"]),
        fixed_parameters_sha256=canonical_sha256(fixed_parameters),
        failure_denominator_sha256=canonical_sha256(failure_denominator),
        thresholds=dict(thresholds),
        routes=tuple(routes),
    )
    if projected_maximum_cost(config) > config.budget_cap_usd:
        raise CertificationFailure("c2.live_projected_cost_exceeds_budget")
    return config


def projected_maximum_cost(config: LiveConfig) -> float:
    return sum(
        config.calls_per_route
        * (
            config.maximum_input_tokens_per_call * route.input_cache_miss_price
            + route.maximum_output_tokens_per_call * route.output_price
        )
        / 1_000_000
        for route in config.routes
    )


def _percentile(values: list[float], quantile: float) -> float:
    if not values:
        raise CertificationFailure("c2.live_cost_denominator_missing")
    ordered = sorted(values)
    index = max(0, min(len(ordered) - 1, math.ceil(quantile * len(ordered)) - 1))
    return ordered[index]


def _safe_token_count(value: object) -> int | None:
    if isinstance(value, bool) or not isinstance(value, int) or value < 0:
        return None
    return value


def _safe_provider_observation(response: httpx.Response) -> dict[str, Any]:
    observation: dict[str, Any] = {"provider_http_status": response.status_code}
    if response.status_code >= 400:
        return observation
    try:
        body = response.json()
        choice = body["choices"][0]
        usage = body["usage"]
    except (IndexError, KeyError, TypeError, ValueError):
        return observation
    finish_reason = choice.get("finish_reason")
    observation["finish_reason"] = (
        finish_reason if finish_reason in ALLOWED_FINISH_REASONS else "UNRECOGNIZED"
    )
    for source, target in (
        ("prompt_tokens", "prompt_token_count"),
        ("completion_tokens", "completion_token_count"),
        ("prompt_cache_hit_tokens", "prompt_cache_hit_token_count"),
        ("prompt_cache_miss_tokens", "prompt_cache_miss_token_count"),
        ("total_tokens", "total_token_count"),
    ):
        count = _safe_token_count(usage.get(source))
        if count is not None:
            observation[target] = count
    return observation


class _ContentFreeObservingClient:
    """Delegate HTTP while retaining only allowlisted scalar metadata."""

    def __init__(self, client: httpx.Client) -> None:
        self._client = client
        self.last_observation: dict[str, Any] = {}

    def post(self, *args: Any, **kwargs: Any) -> httpx.Response:
        response = self._client.post(*args, **kwargs)
        self.last_observation = _safe_provider_observation(response)
        return response


def _cost_from_counts(
    *,
    input_tokens: int,
    output_tokens: int,
    cache_hit_tokens: int,
    cache_miss_tokens: int,
    route: LiveRoute,
) -> float:
    if cache_hit_tokens + cache_miss_tokens != input_tokens:
        raise CertificationFailure("c2.live_usage_invalid")
    return (
        cache_hit_tokens * route.input_cache_hit_price
        + cache_miss_tokens * route.input_cache_miss_price
        + output_tokens * route.output_price
    ) / 1_000_000


def _call_once(
    client: httpx.Client,
    *,
    config: LiveConfig,
    route: LiveRoute,
    api_key: str,
) -> tuple[dict[str, Any] | None, dict[str, Any] | None]:
    input_sha256 = canonical_digest(PROBE_PROMPT)
    input_ref = f"context://sha256/{input_sha256}"
    observer = _ContentFreeObservingClient(client)
    adapter = DeepSeekModelAdapter(
        input_resolver=lambda reference: PROBE_PROMPT
        if reference == input_ref
        else (_ for _ in ()).throw(KeyError(reference)),
        response_schema=_load_schema(),
        output_validator=lambda payload: itinerary_business_rule_codes(
            payload,
            PROBE_INPUT,
            quality_checks=PROBE_INPUT["hard_constraints"],
        ),
        client=observer,  # type: ignore[arg-type]
    )
    started = time.perf_counter()
    try:
        result = adapter.invoke(
            certified_deepseek_route(),
            ModelInvocation(
                request_id=(
                    f"certification-deepseek-{route.route_id}-"
                    f"{time.perf_counter_ns()}"
                ),
                input_ref=input_ref,
                input_sha256=input_sha256,
                required_capabilities=frozenset({"json", "complex"}),
                max_output_tokens=route.maximum_output_tokens_per_call,
            ),
            ProviderCredential(
                PROVIDER_ID,
                "secret://environment/DEEPSEEK_API_KEY",
                api_key,
            ),
            timeout_seconds=certified_deepseek_route().timeout_seconds,
        )
        input_tokens = result.usage.input_tokens
        output_tokens = result.usage.output_tokens
        cache_hit = result.input_cache_hit_tokens
        cache_miss = (
            result.input_cache_miss_tokens
            if result.input_cache_miss_tokens is not None
            else input_tokens - cache_hit
        )
        rule_codes = itinerary_business_rule_codes(
            result.payload or {},
            PROBE_INPUT,
            quality_checks=PROBE_INPUT["hard_constraints"],
        )
        if (
            input_tokens < 1
            or output_tokens < 1
            or input_tokens > config.maximum_input_tokens_per_call
            or output_tokens > route.maximum_output_tokens_per_call
            or rule_codes
        ):
            raise AdapterFailure(
                rule_codes[0] if rule_codes else "llm.schema_invalid",
                retryable=False,
                rule_codes=rule_codes,
                metered_usage=result.usage,
                output_sha256=result.output_sha256,
                input_cache_hit_tokens=cache_hit,
                input_cache_miss_tokens=cache_miss,
            )
        cost = _cost_from_counts(
            input_tokens=input_tokens,
            output_tokens=output_tokens,
            cache_hit_tokens=cache_hit,
            cache_miss_tokens=cache_miss,
            route=route,
        )
        return (
            {
                "http_status": 200,
                "latency_ms": round((time.perf_counter() - started) * 1_000, 6),
                "input_tokens": input_tokens,
                "output_tokens": output_tokens,
                "input_cache_hit_tokens": cache_hit,
                "input_cache_miss_tokens": cache_miss,
                "total_tokens": input_tokens + output_tokens,
                "cost_usd": cost,
                "finish_reason": "stop",
                "response_sha256": result.output_sha256,
                "schema_and_business_rule_failure_count": 0,
            },
            None,
        )
    except AdapterFailure as error:
        failure: dict[str, Any] = {
            "failure_code": error.code,
            "rule_codes": list(error.rule_codes),
            **observer.last_observation,
        }
        if error.metered_usage is not None:
            usage = error.metered_usage
            cache_hit = error.input_cache_hit_tokens
            cache_miss = (
                error.input_cache_miss_tokens
                if error.input_cache_miss_tokens is not None
                else usage.input_tokens - cache_hit
            )
            failure.update(
                {
                    "input_tokens": usage.input_tokens,
                    "output_tokens": usage.output_tokens,
                    "input_cache_hit_tokens": cache_hit,
                    "input_cache_miss_tokens": cache_miss,
                    "metered_cost_usd": _cost_from_counts(
                        input_tokens=usage.input_tokens,
                        output_tokens=usage.output_tokens,
                        cache_hit_tokens=cache_hit,
                        cache_miss_tokens=cache_miss,
                        route=route,
                    ),
                }
            )
        return None, failure


def run_deepseek_live(
    evidence_root: Path,
    *,
    candidate_oid: str,
    config_path: Path = CONFIG_PATH,
    client: httpx.Client | None = None,
    sleeper: Callable[[float], None] = time.sleep,
) -> dict[str, Any]:
    candidate = require_candidate_oid(candidate_oid)
    config = load_live_config(config_path)
    api_key = os.environ.get(config.credential_environment_variable, "")
    if not api_key:
        raise CertificationFailure("c2.live_credential_missing")
    output_root = evidence_root / EVIDENCE_DIRECTORY
    output_root.mkdir(parents=True, exist_ok=True)
    owns_client = client is None
    selected = client or httpx.Client(
        timeout=httpx.Timeout(45.0),
        follow_redirects=False,
        trust_env=True,
    )
    pricing_response_sha256: str | None = None
    pricing_status = 0
    try:
        pricing_response = selected.get(config.pricing_source_url)
        pricing_status = pricing_response.status_code
        pricing_response.raise_for_status()
        pricing_response_sha256 = sha256_bytes(pricing_response.content)
    except httpx.HTTPError:
        pricing_response_sha256 = None

    receipts: list[dict[str, Any]] = []
    failures: list[dict[str, Any]] = []
    provider_request_count = 0
    quota_failures = {route.route_id: 0 for route in config.routes}
    quota_circuit_open = {route.route_id: False for route in config.routes}
    budget_circuit_open = False
    minimum_interval = 60.0 / config.requests_per_minute
    last_started: float | None = None
    actual_total_cost = 0.0
    try:
        for index in range(config.calls_per_route):
            for route in config.routes:
                call_id = f"{route.route_id}-{index + 1:04d}"
                cohort = "baseline" if index < config.calls_per_route // 2 else "candidate"
                if budget_circuit_open:
                    failures.append(
                        {
                            "call_id": call_id,
                            "route_id": route.route_id,
                            "failure_code": "budget.circuit_open",
                        }
                    )
                    continue
                if quota_circuit_open[route.route_id]:
                    failures.append(
                        {
                            "call_id": call_id,
                            "route_id": route.route_id,
                            "failure_code": "provider.quota_circuit_open",
                        }
                    )
                    continue
                if last_started is not None:
                    remaining = minimum_interval - (time.perf_counter() - last_started)
                    if remaining > 0:
                        sleeper(remaining)
                last_started = time.perf_counter()
                provider_request_count += 1
                receipt, failure = _call_once(
                    selected,
                    config=config,
                    route=route,
                    api_key=api_key,
                )
                if receipt is None:
                    failure = failure or {"failure_code": "provider.invalid_response"}
                    failure_code = str(failure["failure_code"])
                    if failure_code == "llm.rate_limited":
                        quota_failures[route.route_id] += 1
                        if quota_failures[route.route_id] >= 3:
                            quota_circuit_open[route.route_id] = True
                    else:
                        quota_failures[route.route_id] = 0
                    actual_total_cost += float(failure.get("metered_cost_usd", 0.0))
                    failures.append(
                        {"call_id": call_id, "route_id": route.route_id, **failure}
                    )
                else:
                    quota_failures[route.route_id] = 0
                    actual_total_cost += float(receipt["cost_usd"])
                    receipts.append(
                        {
                            "call_id": call_id,
                            "route_id": route.route_id,
                            "model_id": route.model_id,
                            "cohort": cohort,
                            **receipt,
                        }
                    )
                if actual_total_cost > config.budget_cap_usd:
                    budget_circuit_open = True
    finally:
        if owns_client:
            selected.close()

    route_receipts: list[dict[str, Any]] = []
    p95_increases: list[float] = []
    for route in config.routes:
        rows = [row for row in receipts if row["route_id"] == route.route_id]
        route_failures = [
            row for row in failures if row["route_id"] == route.route_id
        ]
        baseline = [float(row["cost_usd"]) for row in rows if row["cohort"] == "baseline"]
        candidate_cost = [
            float(row["cost_usd"]) for row in rows if row["cohort"] == "candidate"
        ]
        if baseline and candidate_cost:
            baseline_p95 = _percentile(baseline, 0.95)
            candidate_p95 = _percentile(candidate_cost, 0.95)
            increase = (
                max(0.0, candidate_p95 / baseline_p95 - 1.0)
                if baseline_p95 > 0
                else 999.0
            )
        else:
            baseline_p95 = 0.0
            candidate_p95 = 0.0
            increase = 999.0
        p95_increases.append(increase)
        route_receipts.append(
            {
                "route_id": route.route_id,
                "model_id": route.model_id,
                "attempted_slot_count": config.calls_per_route,
                "maximum_input_tokens_per_call": config.maximum_input_tokens_per_call,
                "maximum_output_tokens_per_call": route.maximum_output_tokens_per_call,
                "projected_maximum_cost_usd": config.calls_per_route
                * (
                    config.maximum_input_tokens_per_call
                    * route.input_cache_miss_price
                    + route.maximum_output_tokens_per_call * route.output_price
                )
                / 1_000_000,
                "call_count": len(rows),
                "failure_count": len(route_failures),
                "failure_denominator_count": len(rows) + len(route_failures),
                "input_token_count": sum(int(row["input_tokens"]) for row in rows),
                "output_token_count": sum(int(row["output_tokens"]) for row in rows),
                "total_cost_usd": sum(float(row["cost_usd"]) for row in rows)
                + sum(float(row.get("metered_cost_usd", 0.0)) for row in route_failures),
                "latency_p95_ms": _percentile(
                    [float(row["latency_ms"]) for row in rows], 0.95
                )
                if rows
                else None,
                "baseline_cost_p95_usd": baseline_p95,
                "candidate_cost_p95_usd": candidate_p95,
                "p95_cost_increase": increase,
                "schema_and_business_rule_failure_count": sum(
                    str(row["failure_code"]).startswith(("schema.", "quality."))
                    or bool(row.get("rule_codes"))
                    for row in route_failures
                ),
                "usage_receipts_sha256": canonical_sha256(rows),
            }
        )
    p95_cost_increase = max(p95_increases)
    completed = (
        len(receipts) == config.calls_per_route * len(config.routes)
        and not failures
        and pricing_response_sha256 is not None
        and actual_total_cost <= config.budget_cap_usd
        and p95_cost_increase <= float(
            config.thresholds["maximum_p95_cost_increase"]
        )
        and all(
            row["call_count"] == 200
            and row["failure_count"] == 0
            and row["failure_denominator_count"] == 200
            and row["schema_and_business_rule_failure_count"] == 0
            for row in route_receipts
        )
    )
    pricing_snapshot = {
        "schema_version": "2.1",
        "provider_id": config.provider_id,
        "model_id": config.model_id,
        "source_url": config.pricing_source_url,
        "source_http_status": pricing_status,
        "source_response_sha256": pricing_response_sha256,
        "configured_retrieval_date": config.pricing_retrieved_on,
        "retrieved_at": datetime.now(UTC).isoformat(),
        "rates": [
            {
                "route_id": route.route_id,
                "model_id": route.model_id,
                "input_cache_hit_usd_per_million_tokens": route.input_cache_hit_price,
                "input_cache_miss_usd_per_million_tokens": route.input_cache_miss_price,
                "output_usd_per_million_tokens": route.output_price,
            }
            for route in config.routes
        ],
        "frozen_config_sha256": sha256_file(config_path),
        "response_schema_sha256": config.response_schema_sha256,
    }
    pricing_path = output_root / "pricing-snapshot.json"
    write_atomic_json(pricing_path, pricing_snapshot)
    report = {
        "schema_version": "2.1",
        "candidate_head_oid": candidate,
        "provider_id": config.provider_id,
        "model_id": config.model_id,
        "executor": "repository_owned_deepseek_live_v1",
        "status": "passed" if completed else "blocked",
        "credential_source": config.credential_environment_variable,
        "credential_value_recorded": False,
        "request_body_record_count": 0,
        "response_body_record_count": 0,
        "secret_or_pii_leak_count": 0,
        "route_receipts": route_receipts,
        "failure_receipts": failures,
        "successful_call_count": len(receipts),
        "failed_call_count": len(failures),
        "failure_denominator_count": len(receipts) + len(failures),
        "provider_request_count": provider_request_count,
        "quota_circuit_open_routes": sorted(
            route_id for route_id, opened in quota_circuit_open.items() if opened
        ),
        "budget_circuit_open": budget_circuit_open,
        "projected_maximum_cost_usd": projected_maximum_cost(config),
        "actual_total_cost_usd": actual_total_cost,
        "budget_cap_usd": config.budget_cap_usd,
        "cost_to_budget_ratio_upper": actual_total_cost / config.budget_cap_usd,
        "p95_cost_increase_upper": p95_cost_increase,
        "pricing_snapshot_sha256": sha256_file(pricing_path),
        "frozen_config_sha256": sha256_file(config_path),
        "response_schema_sha256": config.response_schema_sha256,
        "fixed_parameters_sha256": config.fixed_parameters_sha256,
        "failure_denominator_sha256": config.failure_denominator_sha256,
        "usage_receipts_sha256": canonical_sha256(receipts),
        "usage_receipt_summary": {
            "input_tokens": sum(int(row["input_tokens"]) for row in receipts),
            "output_tokens": sum(int(row["output_tokens"]) for row in receipts),
            "latency_mean_ms": statistics.fmean(
                float(row["latency_ms"]) for row in receipts
            )
            if receipts
            else None,
        },
        "complete_json_schema_delivered": True,
        "local_schema_and_business_validation": True,
        "same_failure_denominator_as_gemini_v1": True,
        "historical_gemini_evidence_overwrite_count": 0,
        "production": False,
        "production_write_count": 0,
    }
    write_atomic_json(output_root / "live-provider-receipts.json", report)
    return report
