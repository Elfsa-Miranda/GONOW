"""Bounded live Gemini certification with content-free usage receipts.

The credential is read only from the frozen environment-variable name. Neither
the credential, request body, nor model response body is written to evidence.
Evidence contains route identity, token counts, timings, cost arithmetic, stable
failure codes, and SHA-256 digests only.
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

from harness_common import (
    CertificationFailure,
    canonical_sha256,
    require_candidate_oid,
    sha256_bytes,
    sha256_file,
    write_atomic_json,
)


CONFIG_PATH = Path(__file__).with_name("gemini-live-provider-v1.json")
ALLOWED_ORIGIN = "https://generativelanguage.googleapis.com"
ALLOWED_API_VERSION = "v1beta"
ALLOWED_PRICING_SOURCE = "https://ai.google.dev/gemini-api/docs/pricing"
ALLOWED_MODELS = {"gemini-3.1-flash-lite", "gemini-3.6-flash"}
RETRYABLE_STATUS_CODES = {429, 500, 503, 504}


@dataclass(frozen=True, slots=True)
class LiveRoute:
    route_id: str
    model_id: str
    input_price: float
    output_price: float


@dataclass(frozen=True, slots=True)
class LiveConfig:
    provider_id: str
    api_origin: str
    api_version: str
    credential_environment_variable: str
    calls_per_route: int
    requests_per_minute: int
    maximum_input_tokens_per_call: int
    maximum_output_tokens_per_call: int
    budget_cap_usd: float
    pricing_source_url: str
    pricing_retrieved_on: str
    routes: tuple[LiveRoute, ...]


def _number(value: object, *, code: str) -> float:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise CertificationFailure(code)
    number = float(value)
    if not math.isfinite(number) or number < 0:
        raise CertificationFailure(code)
    return number


def load_live_config(path: Path = CONFIG_PATH) -> LiveConfig:
    try:
        raw = json.loads(path.read_text("utf-8"))
    except (OSError, ValueError) as error:
        raise CertificationFailure("c2.live_config_invalid") from error
    required = {
        "schema_version",
        "provider_id",
        "api_origin",
        "api_version",
        "credential_environment_variable",
        "calls_per_route",
        "requests_per_minute",
        "maximum_input_tokens_per_call",
        "maximum_output_tokens_per_call",
        "budget_cap_usd",
        "pricing_source_url",
        "pricing_retrieved_on",
        "routes",
    }
    if not isinstance(raw, dict) or set(raw) != required or raw["schema_version"] != "1.0":
        raise CertificationFailure("c2.live_config_invalid")
    if (
        raw["api_origin"] != ALLOWED_ORIGIN
        or raw["api_version"] != ALLOWED_API_VERSION
        or raw["pricing_source_url"] != ALLOWED_PRICING_SOURCE
        or raw["credential_environment_variable"] != "GEMINI_API_KEY"
    ):
        raise CertificationFailure("c2.live_config_boundary_invalid")
    route_rows = raw["routes"]
    if not isinstance(route_rows, list) or len(route_rows) != 2:
        raise CertificationFailure("c2.live_routes_invalid")
    routes: list[LiveRoute] = []
    for row in route_rows:
        if not isinstance(row, dict) or set(row) != {
            "route_id",
            "model_id",
            "input_usd_per_million_tokens",
            "output_usd_per_million_tokens",
        }:
            raise CertificationFailure("c2.live_routes_invalid")
        model_id = str(row["model_id"])
        if model_id not in ALLOWED_MODELS:
            raise CertificationFailure("c2.live_model_not_allowlisted")
        routes.append(
            LiveRoute(
                route_id=str(row["route_id"]),
                model_id=model_id,
                input_price=_number(
                    row["input_usd_per_million_tokens"],
                    code="c2.live_price_invalid",
                ),
                output_price=_number(
                    row["output_usd_per_million_tokens"],
                    code="c2.live_price_invalid",
                ),
            )
        )
    if {route.route_id for route in routes} != {"economic", "capability"}:
        raise CertificationFailure("c2.live_routes_invalid")
    calls = int(raw["calls_per_route"])
    rpm = int(raw["requests_per_minute"])
    input_limit = int(raw["maximum_input_tokens_per_call"])
    output_limit = int(raw["maximum_output_tokens_per_call"])
    budget = _number(raw["budget_cap_usd"], code="c2.live_budget_invalid")
    if calls < 200 or rpm < 1 or rpm > 120 or input_limit < 1 or output_limit < 1 or budget <= 0:
        raise CertificationFailure("c2.live_config_invalid")
    config = LiveConfig(
        provider_id=str(raw["provider_id"]),
        api_origin=str(raw["api_origin"]),
        api_version=str(raw["api_version"]),
        credential_environment_variable=str(raw["credential_environment_variable"]),
        calls_per_route=calls,
        requests_per_minute=rpm,
        maximum_input_tokens_per_call=input_limit,
        maximum_output_tokens_per_call=output_limit,
        budget_cap_usd=budget,
        pricing_source_url=str(raw["pricing_source_url"]),
        pricing_retrieved_on=str(raw["pricing_retrieved_on"]),
        routes=tuple(routes),
    )
    if projected_maximum_cost(config) > config.budget_cap_usd:
        raise CertificationFailure("c2.live_projected_cost_exceeds_budget")
    return config


def projected_maximum_cost(config: LiveConfig) -> float:
    return sum(
        config.calls_per_route
        * (
            config.maximum_input_tokens_per_call * route.input_price
            + config.maximum_output_tokens_per_call * route.output_price
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


def _request_payload(maximum_output_tokens: int) -> dict[str, Any]:
    return {
        "contents": [
            {
                "role": "user",
                "parts": [
                    {
                        "text": (
                            "Return one JSON object with the boolean field ok set to true. "
                            "Do not add any other fields."
                        )
                    }
                ],
            }
        ],
        "generationConfig": {
            "temperature": 0,
            "maxOutputTokens": maximum_output_tokens,
            "responseMimeType": "application/json",
            "responseJsonSchema": {
                "type": "object",
                "properties": {"ok": {"type": "boolean", "const": True}},
                "required": ["ok"],
                "additionalProperties": False,
            },
            "thinkingConfig": {"thinkingLevel": "low"},
        },
    }


def _safe_failure_code(response: httpx.Response | None, error: Exception | None) -> str:
    if response is not None and response.status_code >= 400:
        return f"provider.http_{response.status_code}"
    if isinstance(error, httpx.TimeoutException):
        return "provider.timeout"
    if isinstance(error, httpx.HTTPError):
        return "provider.transport"
    return "provider.invalid_response"


def _call_once(
    client: httpx.Client,
    *,
    config: LiveConfig,
    route: LiveRoute,
    api_key: str,
) -> tuple[dict[str, Any] | None, str | None]:
    url = f"{config.api_origin}/{config.api_version}/models/{route.model_id}:generateContent"
    payload = _request_payload(config.maximum_output_tokens_per_call)
    started = time.perf_counter()
    response: httpx.Response | None = None
    error: Exception | None = None
    try:
        response = client.post(
            url,
            headers={"x-goog-api-key": api_key, "content-type": "application/json"},
            json=payload,
        )
        response.raise_for_status()
        body = response.json()
        usage = body.get("usageMetadata", {})
        input_tokens = int(usage["promptTokenCount"])
        output_tokens = int(usage["candidatesTokenCount"])
        total_tokens = int(usage["totalTokenCount"])
        candidates = body.get("candidates", [])
        text_value = (
            candidates[0].get("content", {}).get("parts", [{}])[0].get("text", "")
            if isinstance(candidates, list) and candidates
            else ""
        )
        parsed_output = json.loads(text_value)
        if (
            not isinstance(candidates, list)
            or not candidates
            or input_tokens < 1
            or output_tokens < 1
            or total_tokens < input_tokens + output_tokens
            or input_tokens > config.maximum_input_tokens_per_call
            or output_tokens > config.maximum_output_tokens_per_call
            or parsed_output != {"ok": True}
        ):
            raise ValueError("provider response contract")
        finish_reason = str(candidates[0].get("finishReason", ""))
        body_bytes = response.content
        cost = (
            input_tokens * route.input_price + output_tokens * route.output_price
        ) / 1_000_000
        return (
            {
                "http_status": response.status_code,
                "latency_ms": round((time.perf_counter() - started) * 1_000, 6),
                "input_tokens": input_tokens,
                "output_tokens": output_tokens,
                "total_tokens": total_tokens,
                "cost_usd": cost,
                "finish_reason": finish_reason,
                "response_sha256": sha256_bytes(body_bytes),
            },
            None,
        )
    except (httpx.HTTPError, AttributeError, IndexError, KeyError, TypeError, ValueError) as caught:
        error = caught
    return None, _safe_failure_code(response, error)


def run_gemini_live(
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
    evidence_root.mkdir(parents=True, exist_ok=True)
    owns_client = client is None
    selected = client or httpx.Client(
        timeout=httpx.Timeout(30.0),
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
    minimum_interval = 60.0 / config.requests_per_minute
    last_started: float | None = None
    try:
        for route in config.routes:
            for index in range(config.calls_per_route):
                if last_started is not None:
                    remaining = minimum_interval - (time.perf_counter() - last_started)
                    if remaining > 0:
                        sleeper(remaining)
                last_started = time.perf_counter()
                receipt, failure = _call_once(
                    selected,
                    config=config,
                    route=route,
                    api_key=api_key,
                )
                cohort = "baseline" if index < config.calls_per_route // 2 else "candidate"
                call_id = f"{route.route_id}-{index + 1:04d}"
                if receipt is None:
                    failures.append(
                        {
                            "call_id": call_id,
                            "route_id": route.route_id,
                            "failure_code": failure or "provider.invalid_response",
                        }
                    )
                    continue
                receipts.append(
                    {
                        "call_id": call_id,
                        "route_id": route.route_id,
                        "model_id": route.model_id,
                        "cohort": cohort,
                        **receipt,
                    }
                )
    finally:
        if owns_client:
            selected.close()

    route_receipts: list[dict[str, Any]] = []
    p95_increases: list[float] = []
    for route in config.routes:
        rows = [row for row in receipts if row["route_id"] == route.route_id]
        baseline = [float(row["cost_usd"]) for row in rows if row["cohort"] == "baseline"]
        candidate_cost = [
            float(row["cost_usd"]) for row in rows if row["cohort"] == "candidate"
        ]
        if baseline and candidate_cost:
            baseline_p95 = _percentile(baseline, 0.95)
            candidate_p95 = _percentile(candidate_cost, 0.95)
            increase = max(0.0, candidate_p95 / baseline_p95 - 1.0)
        else:
            baseline_p95 = 0.0
            candidate_p95 = 0.0
            increase = 999.0
        p95_increases.append(increase)
        route_receipts.append(
            {
                "route_id": route.route_id,
                "model_id": route.model_id,
                "call_count": len(rows),
                "failure_count": sum(
                    row["route_id"] == route.route_id for row in failures
                ),
                "input_token_count": sum(int(row["input_tokens"]) for row in rows),
                "output_token_count": sum(int(row["output_tokens"]) for row in rows),
                "total_cost_usd": sum(float(row["cost_usd"]) for row in rows),
                "latency_p95_ms": _percentile(
                    [float(row["latency_ms"]) for row in rows], 0.95
                )
                if rows
                else None,
                "baseline_cost_p95_usd": baseline_p95,
                "candidate_cost_p95_usd": candidate_p95,
                "p95_cost_increase": increase,
                "usage_receipts_sha256": canonical_sha256(rows),
            }
        )
    total_cost = sum(float(row["cost_usd"]) for row in receipts)
    completed = (
        len(receipts) == config.calls_per_route * len(config.routes)
        and not failures
        and pricing_response_sha256 is not None
        and all(row["call_count"] >= 200 for row in route_receipts)
    )
    pricing_snapshot = {
        "schema_version": "1.0",
        "provider_id": config.provider_id,
        "source_url": config.pricing_source_url,
        "source_http_status": pricing_status,
        "source_response_sha256": pricing_response_sha256,
        "retrieved_at": datetime.now(UTC).isoformat(),
        "rates": [
            {
                "route_id": route.route_id,
                "model_id": route.model_id,
                "input_usd_per_million_tokens": route.input_price,
                "output_usd_per_million_tokens": route.output_price,
            }
            for route in config.routes
        ],
        "frozen_config_sha256": sha256_file(config_path),
    }
    write_atomic_json(evidence_root / "pricing-snapshot.json", pricing_snapshot)
    report = {
        "schema_version": "1.0",
        "candidate_head_oid": candidate,
        "provider_id": config.provider_id,
        "executor": "repository_owned_gemini_live_v1",
        "status": "passed" if completed else "blocked",
        "credential_source": config.credential_environment_variable,
        "credential_value_recorded": False,
        "request_body_record_count": 0,
        "response_body_record_count": 0,
        "secret_or_pii_leak_count": 0,
        "route_receipts": route_receipts,
        "failure_receipts": failures,
        "successful_call_count": len(receipts),
        "provider_request_count": len(receipts) + len(failures),
        "projected_maximum_cost_usd": projected_maximum_cost(config),
        "actual_total_cost_usd": total_cost,
        "budget_cap_usd": config.budget_cap_usd,
        "cost_to_budget_ratio_upper": total_cost / config.budget_cap_usd,
        "p95_cost_increase_upper": max(p95_increases),
        "pricing_snapshot_sha256": sha256_file(
            evidence_root / "pricing-snapshot.json"
        ),
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
        "production": False,
        "production_write_count": 0,
    }
    write_atomic_json(evidence_root / "live-provider-receipts.json", report)
    return report
