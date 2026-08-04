"""Credential-gated, resumable and strictly bounded local P12B calibration."""

from __future__ import annotations

import argparse
from collections.abc import Mapping
from dataclasses import asdict, dataclass
from datetime import datetime, timezone
from decimal import Decimal, ROUND_CEILING
import hashlib
import json
import math
import os
from pathlib import Path
import sys
import time
from typing import Any

import httpx


SERVICE_ROOT = Path(__file__).resolve().parents[1]
REPOSITORY_ROOT = SERVICE_ROOT.parent
if str(SERVICE_ROOT) not in sys.path:
    sys.path.insert(0, str(SERVICE_ROOT))

from app.models.deepseek import (  # noqa: E402
    DeepSeekModelAdapter,
    EnvironmentDeepSeekCredentialProvider,
    FixedCostRouterCredentialProvider,
    FixedCostRouterModelAdapter,
    ROUTE_ID as DEEPSEEK_ROUTE_ID,
    certified_deepseek_route,
)
from app.models.gateway import (  # noqa: E402
    AdapterFailure,
    AuthenticatedModelGateway,
    CircuitBreaker,
    ModelAdapter,
    ModelGatewayError,
    ModelInvocation,
    ModelResult,
    RetryPolicy,
)
from app.models.gemini import (  # noqa: E402
    EnvironmentGeminiCredentialProvider,
    GeminiModelAdapter,
    canonical_digest,
    certified_gemini_routes,
)
from app.models.ledger import ModelUsageLedger, TokenUsage  # noqa: E402
from app.models.routes import CertifiedModelRoute, FixedCertifiedRoutePlan  # noqa: E402
from app.worker.itinerary_processor import (  # noqa: E402
    ITINERARY_RESPONSE_SCHEMA,
    _prompt,
    itinerary_business_rule_codes,
    itinerary_max_output_tokens,
)
from scripts.run_p12b_replay import (  # noqa: E402
    DATASET_SHA256,
    _required_capabilities,
    load_dataset,
)


MAX_TASKS = 20
MAX_CALLS = 40
MAX_TOTAL_TOKENS = 100_000
MAX_COST_MICROUSD = 1_000_000
PILOT_IDS = frozenset({"CR-V1-001", "CR-V1-007", "CR-V1-008", "CR-V1-010"})
REPAIR_V2_MAX_TASKS = 4
REPAIR_V2_MAX_CALLS = 8
REPAIR_V2_MAX_TOTAL_TOKENS = 40_000
REPAIR_V2_MAX_COST_MICROUSD = 500_000
DEEPSEEK_V3_MAX_TASKS = 10
DEEPSEEK_V3_MAX_CALLS = 14
DEEPSEEK_V3_MAX_TOTAL_TOKENS = 60_000
DEEPSEEK_V3_MAX_COST_MICROUSD = 500_000
DEEPSEEK_V3_MAX_RETRIES = 4
DEEPSEEK_V3_RETRYABLE_CODES = frozenset(
    {"llm.provider_unavailable", "llm.rate_limited", "llm.timeout"}
)
DEEPSEEK_V4_SCENARIO_IDS = frozenset({"CR-V1-003", "CR-V1-008", "CR-V1-009"})
DEEPSEEK_V4_MAX_TASKS = 3
DEEPSEEK_V4_MAX_CALLS = 3
DEEPSEEK_V4_MAX_TOTAL_TOKENS = 10_000
DEEPSEEK_V4_MAX_COST_MICROUSD = 250_000
DEEPSEEK_V5_SCENARIO_IDS = frozenset({"CR-V1-003"})
DEEPSEEK_V5_MAX_TASKS = 1
DEEPSEEK_V5_MAX_CALLS = 1
DEEPSEEK_V5_MAX_TOTAL_TOKENS = 5_000
DEEPSEEK_V5_MAX_COST_MICROUSD = 100_000
MANIFEST_REQUIRED_SHA256 = "84e4b409dc8f66fd34e2ac3458e0c50e1d65ecc0f04bb996ff35a88a1e5b9344"
PRICE_SNAPSHOT_PATH = REPOSITORY_ROOT / "docs/execution/evidence/phase-12b/P12B-010/price-snapshot.json"


class CalibrationError(RuntimeError):
    def __init__(self, code: str) -> None:
        self.code = code
        super().__init__(code)


@dataclass(frozen=True, slots=True)
class PriceRate:
    provider_id: str
    model_id: str
    input_cache_miss_usd: Decimal
    input_cache_hit_usd: Decimal
    output_usd: Decimal


@dataclass(frozen=True, slots=True)
class LiveAttempt:
    scenario_id: str
    arm: str
    attempt: int
    route_id: str
    provider_id: str
    model_id: str
    status: str
    failure_class: str | None
    input_tokens: int
    output_tokens: int
    cache_hit_input_tokens: int
    cache_miss_input_tokens: int
    cost_microusd: int
    latency_ms: int
    output_sha256: str | None
    rule_codes: tuple[str, ...] = ()


class CalibrationBudget:
    def __init__(
        self,
        *,
        calls: int = 0,
        total_tokens: int = 0,
        cost_microusd: int = 0,
        call_limit: int = MAX_CALLS,
        token_limit: int = MAX_TOTAL_TOKENS,
        cost_limit_microusd: int = MAX_COST_MICROUSD,
    ) -> None:
        if (
            calls < 0
            or total_tokens < 0
            or cost_microusd < 0
            or calls > call_limit
            or total_tokens > token_limit
            or cost_microusd > cost_limit_microusd
        ):
            raise CalibrationError("calibration.prior_budget_invalid")
        self.call_limit = call_limit
        self.token_limit = token_limit
        self.cost_limit_microusd = cost_limit_microusd
        self.calls = calls
        self.total_tokens = total_tokens
        self.cost_microusd = cost_microusd

    @staticmethod
    def _cost(
        *,
        input_hit: int,
        input_miss: int,
        output: int,
        rate: PriceRate,
    ) -> int:
        value = (
            Decimal(input_hit) * rate.input_cache_hit_usd
            + Decimal(input_miss) * rate.input_cache_miss_usd
            + Decimal(output) * rate.output_usd
        )
        return int(value.to_integral_value(rounding=ROUND_CEILING))

    def authorize_call(
        self, *, prompt_utf8_bytes: int, max_output_tokens: int, rate: PriceRate
    ) -> None:
        worst_tokens = prompt_utf8_bytes + max_output_tokens
        worst_cost = self._cost(
            input_hit=0,
            input_miss=prompt_utf8_bytes,
            output=max_output_tokens,
            rate=rate,
        )
        if self.calls + 1 > self.call_limit:
            raise CalibrationError("calibration.call_cap")
        if self.total_tokens + worst_tokens > self.token_limit:
            raise CalibrationError("calibration.token_cap")
        if self.cost_microusd + worst_cost > self.cost_limit_microusd:
            raise CalibrationError("calibration.cost_cap")
        self.calls += 1

    def record_usage(
        self,
        *,
        usage: TokenUsage,
        input_cache_hit_tokens: int,
        input_cache_miss_tokens: int | None,
        rate: PriceRate,
    ) -> int:
        hit = input_cache_hit_tokens
        miss = (
            input_cache_miss_tokens
            if input_cache_miss_tokens is not None
            else usage.input_tokens - hit
        )
        tokens = usage.total_tokens
        cost = self._cost(
            input_hit=hit,
            input_miss=miss,
            output=usage.output_tokens,
            rate=rate,
        )
        self.total_tokens += tokens
        self.cost_microusd += cost
        if self.total_tokens > self.token_limit:
            raise CalibrationError("calibration.token_cap_post_call")
        if self.cost_microusd > self.cost_limit_microusd:
            raise CalibrationError("calibration.cost_cap_post_call")
        return cost

    def record_result(self, *, result: ModelResult, rate: PriceRate) -> int:
        return self.record_usage(
            usage=result.usage,
            input_cache_hit_tokens=result.input_cache_hit_tokens,
            input_cache_miss_tokens=result.input_cache_miss_tokens,
            rate=rate,
        )


class RecordingBudgetAdapter:
    def __init__(
        self,
        *,
        delegate: ModelAdapter,
        budget: CalibrationBudget,
        rates: Mapping[tuple[str, str], PriceRate],
        scenario_id: str,
        arm: str,
        prompt_utf8_bytes: int,
        records: list[LiveAttempt],
        monotonic=None,
    ) -> None:
        self._delegate = delegate
        self._budget = budget
        self._rates = rates
        self._scenario_id = scenario_id
        self._arm = arm
        self._prompt_utf8_bytes = prompt_utf8_bytes
        self._records = records
        self._monotonic = monotonic or time.monotonic

    def invoke(
        self,
        route: CertifiedModelRoute,
        invocation: ModelInvocation,
        credential,
        *,
        timeout_seconds: float,
    ) -> ModelResult:
        rate = self._rates.get((route.provider_id, route.model_id))
        if rate is None:
            raise AdapterFailure("calibration.price_missing", retryable=False)
        self._budget.authorize_call(
            prompt_utf8_bytes=self._prompt_utf8_bytes,
            max_output_tokens=invocation.max_output_tokens,
            rate=rate,
        )
        attempt = 1 + sum(
            record.scenario_id == self._scenario_id and record.arm == self._arm
            for record in self._records
        )
        started = self._monotonic()
        try:
            result = self._delegate.invoke(
                route,
                invocation,
                credential,
                timeout_seconds=timeout_seconds,
            )
        except AdapterFailure as error:
            usage = error.metered_usage
            cost = 0
            input_tokens = 0
            output_tokens = 0
            cache_hit = 0
            cache_miss = 0
            if usage is not None:
                input_tokens = usage.input_tokens
                output_tokens = usage.output_tokens
                cache_hit = error.input_cache_hit_tokens
                cache_miss = (
                    error.input_cache_miss_tokens
                    if error.input_cache_miss_tokens is not None
                    else input_tokens - cache_hit
                )
                cost = self._budget.record_usage(
                    usage=usage,
                    input_cache_hit_tokens=cache_hit,
                    input_cache_miss_tokens=cache_miss,
                    rate=rate,
                )
            self._records.append(
                LiveAttempt(
                    scenario_id=self._scenario_id,
                    arm=self._arm,
                    attempt=attempt,
                    route_id=route.route_id,
                    provider_id=route.provider_id,
                    model_id=route.model_id,
                    status="failed",
                    failure_class=error.code,
                    input_tokens=input_tokens,
                    output_tokens=output_tokens,
                    cache_hit_input_tokens=cache_hit,
                    cache_miss_input_tokens=cache_miss,
                    cost_microusd=cost,
                    latency_ms=max(0, round((self._monotonic() - started) * 1000)),
                    output_sha256=error.output_sha256,
                    rule_codes=error.rule_codes,
                )
            )
            raise
        cost = self._budget.record_result(result=result, rate=rate)
        hit = result.input_cache_hit_tokens
        miss = (
            result.input_cache_miss_tokens
            if result.input_cache_miss_tokens is not None
            else result.usage.input_tokens - hit
        )
        self._records.append(
            LiveAttempt(
                scenario_id=self._scenario_id,
                arm=self._arm,
                attempt=attempt,
                route_id=route.route_id,
                provider_id=route.provider_id,
                model_id=route.model_id,
                status="succeeded",
                failure_class=None,
                input_tokens=result.usage.input_tokens,
                output_tokens=result.usage.output_tokens,
                cache_hit_input_tokens=hit,
                cache_miss_input_tokens=miss,
                cost_microusd=cost,
                latency_ms=max(0, round((self._monotonic() - started) * 1000)),
                output_sha256=result.output_sha256,
                rule_codes=(),
            )
        )
        return result


def _sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def _load_prices() -> tuple[dict[tuple[str, str], PriceRate], str]:
    snapshot = json.loads(PRICE_SNAPSHOT_PATH.read_text(encoding="utf-8"))
    observed_at = datetime.fromisoformat(snapshot["freshness"]["observed_at"])
    maximum_age_seconds = int(
        snapshot["freshness"]["maximum_age_hours_before_live_call"] * 3600
    )
    age_seconds = (datetime.now(timezone.utc) - observed_at).total_seconds()
    if age_seconds < 0 or age_seconds > maximum_age_seconds:
        raise CalibrationError("calibration.price_snapshot_stale")
    rates: dict[tuple[str, str], PriceRate] = {}
    for item in snapshot["prices"]:
        rates[(item["provider_id"], item["model_id"])] = PriceRate(
            provider_id=item["provider_id"],
            model_id=item["model_id"],
            input_cache_miss_usd=Decimal(str(item["input_cache_miss_usd"])),
            input_cache_hit_usd=Decimal(str(item["input_cache_hit_usd"])),
            output_usd=Decimal(
                str(item.get("output_usd", item.get("output_including_thinking_usd")))
            ),
        )
    if len(rates) != 3:
        raise CalibrationError("calibration.price_snapshot_invalid")
    return rates, _sha256(PRICE_SNAPSHOT_PATH)


def _load_manifest(manifest_path: Path) -> tuple[tuple[dict[str, Any], ...], str]:
    if _sha256(manifest_path) != MANIFEST_REQUIRED_SHA256:
        raise CalibrationError("calibration.manifest_hash_mismatch")
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    if manifest["dataset_sha256"] != DATASET_SHA256:
        raise CalibrationError("calibration.dataset_binding_invalid")
    dataset = REPOSITORY_ROOT / manifest["dataset_path"]
    return load_dataset(dataset), _sha256(manifest_path)


def _make_output_sensitive_key_count(value: Any) -> int:
    forbidden_fragments = (
        "secret",
        "credential",
        "api_key",
        "prompt",
        "response_body",
        "reasoning",
    )
    if isinstance(value, dict):
        return sum(
            int(
                key
                not in {
                    "secret_material_persisted",
                    "secret_or_content_evidence_field",
                }
                and any(fragment in str(key).lower() for fragment in forbidden_fragments)
            )
            + _make_output_sensitive_key_count(child)
            for key, child in value.items()
        )
    if isinstance(value, list):
        return sum(_make_output_sensitive_key_count(child) for child in value)
    return 0


def _nearest_rank_p95(values: list[int]) -> int | None:
    if not values:
        return None
    return sorted(values)[math.ceil(0.95 * len(values)) - 1]


def _arm_summary(tasks: list[dict[str, Any]], attempts: list[LiveAttempt], arm: str) -> dict[str, Any]:
    arm_tasks = [task for task in tasks if task["arm"] == arm]
    arm_attempts = [attempt for attempt in attempts if attempt.arm == arm]
    successes = sum(task["quality_qualified"] for task in arm_tasks)
    total_cost = sum(attempt.cost_microusd for attempt in arm_attempts)
    return {
        "denominator": len(arm_tasks),
        "attempt_count": len(arm_attempts),
        "qualified_success_count": successes,
        "failure_count": len(arm_tasks) - successes,
        "total_input_tokens": sum(attempt.input_tokens for attempt in arm_attempts),
        "total_output_tokens": sum(attempt.output_tokens for attempt in arm_attempts),
        "total_tokens": sum(
            attempt.input_tokens + attempt.output_tokens for attempt in arm_attempts
        ),
        "total_cost_microusd": total_cost,
        "cost_per_qualified_success_microusd": (
            total_cost / successes if successes else None
        ),
        "p95_latency_ms": _nearest_rank_p95(
            [task["latency_ms"] for task in arm_tasks]
        ),
        "fallback_count": sum(task["fallback_used"] for task in arm_tasks),
        "maximum_fallback_depth": max(
            (task["fallback_depth"] for task in arm_tasks), default=0
        ),
        "failure_classes": {
            code: sum(attempt.failure_class == code for attempt in arm_attempts)
            for code in sorted(
                {
                    attempt.failure_class
                    for attempt in arm_attempts
                    if attempt.failure_class
                }
            )
        },
        "quality_rule_failures": {
            code: sum(code in attempt.rule_codes for attempt in arm_attempts)
            for code in sorted(
                {
                    code
                    for attempt in arm_attempts
                    for code in attempt.rule_codes
                }
            )
        },
    }


def _execute_arm(
    *,
    scenario: dict[str, Any],
    arm: str,
    prompt: str,
    input_ref: str,
    input_sha256: str,
    max_output_tokens: int,
    baseline_plan: tuple[CertifiedModelRoute, ...],
    client: httpx.Client,
    budget: CalibrationBudget,
    rates: Mapping[tuple[str, str], PriceRate],
    attempts: list[LiveAttempt],
    max_total_attempts: int,
) -> dict[str, Any]:
    output_validator = lambda payload: itinerary_business_rule_codes(
        payload,
        scenario["request"],
        quality_checks=scenario["quality_checks"],
    )
    gemini_adapter = GeminiModelAdapter(
        input_resolver=lambda reference: prompt
        if reference == input_ref
        else (_ for _ in ()).throw(KeyError(reference)),
        response_schema=ITINERARY_RESPONSE_SCHEMA,
        output_validator=output_validator,
        client=client,
    )
    if arm == "baseline":
        routes = certified_gemini_routes()
        credentials = EnvironmentGeminiCredentialProvider()
        delegate: ModelAdapter = gemini_adapter
    else:
        routes = FixedCertifiedRoutePlan(
            (certified_deepseek_route(), baseline_plan[0])
        )
        credentials = FixedCostRouterCredentialProvider(
            gemini=EnvironmentGeminiCredentialProvider(),
            deepseek=EnvironmentDeepSeekCredentialProvider(),
        )
        delegate = FixedCostRouterModelAdapter(
            gemini=gemini_adapter,
            deepseek=DeepSeekModelAdapter(
                input_resolver=lambda reference: prompt
                if reference == input_ref
                else (_ for _ in ()).throw(KeyError(reference)),
                response_schema=ITINERARY_RESPONSE_SCHEMA,
                output_validator=output_validator,
                client=client,
            ),
        )
    adapter = RecordingBudgetAdapter(
        delegate=delegate,
        budget=budget,
        rates=rates,
        scenario_id=scenario["scenario_id"],
        arm=arm,
        prompt_utf8_bytes=len(prompt.encode("utf-8"))
        + len(
            json.dumps(
                ITINERARY_RESPONSE_SCHEMA,
                ensure_ascii=False,
                separators=(",", ":"),
                sort_keys=True,
            ).encode("utf-8")
        ),
        records=attempts,
    )
    gateway = AuthenticatedModelGateway(
        routes=routes,
        credentials=credentials,
        adapter=adapter,
        ledger=ModelUsageLedger(),
        circuit_breaker=CircuitBreaker(failure_threshold=2, cooldown_seconds=30),
        retry_policy=RetryPolicy(max_total_attempts=max_total_attempts),
    )
    invocation = ModelInvocation(
        request_id=f"p12b-{scenario['scenario_id']}-{arm}",
        input_ref=input_ref,
        input_sha256=input_sha256,
        required_capabilities=_required_capabilities(scenario["request"]),
        max_output_tokens=max_output_tokens,
    )
    before = len(attempts)
    started = time.monotonic()
    try:
        outcome = gateway.invoke(invocation, now_monotonic=time.monotonic())
        payload = outcome.result.payload
        rule_codes = (
            itinerary_business_rule_codes(
                payload,
                scenario["request"],
                quality_checks=scenario["quality_checks"],
            )
            if payload is not None
            else ("schema.payload_missing",)
        )
        quality = not rule_codes
        failure_code = None if quality else rule_codes[0]
        output_sha256 = outcome.result.output_sha256
        route_id = outcome.route_id
        fallback_used = outcome.fallback_used
        fallback_depth = int(outcome.fallback_used)
    except (ModelGatewayError, CalibrationError) as error:
        arm_attempts = attempts[before:]
        rule_codes = tuple(
            sorted({code for attempt in arm_attempts for code in attempt.rule_codes})
        )
        quality = False
        failure_code = (
            arm_attempts[-1].failure_class
            if arm_attempts and arm_attempts[-1].failure_class
            else getattr(error, "code", "calibration.failure")
        )
        output_sha256 = arm_attempts[-1].output_sha256 if arm_attempts else None
        route_id = arm_attempts[-1].route_id if arm_attempts else None
        fallback_used = len(arm_attempts) > 1
        fallback_depth = int(fallback_used)
    return {
        "scenario_id": scenario["scenario_id"],
        "arm": arm,
        "input_sha256": input_sha256,
        "max_output_tokens": max_output_tokens,
        "status": "qualified_success" if quality else "failed",
        "failure_class": failure_code,
        "quality_rule_codes": list(rule_codes),
        "quality_qualified": quality,
        "route_id": route_id,
        "output_sha256": output_sha256,
        "attempt_count": len(attempts) - before,
        "fallback_used": fallback_used,
        "fallback_depth": fallback_depth,
        "latency_ms": max(0, round((time.monotonic() - started) * 1000)),
    }


def _prior_values(
    prior: dict[str, Any] | None,
    *,
    call_limit: int,
    token_limit: int,
    cost_limit_microusd: int,
) -> tuple[list[dict[str, Any]], list[LiveAttempt], CalibrationBudget]:
    if prior is None:
        return [], [], CalibrationBudget(
            call_limit=call_limit,
            token_limit=token_limit,
            cost_limit_microusd=cost_limit_microusd,
        )
    if (
        prior.get("schema_version") != "1.0"
        or prior.get("dataset_sha256") != DATASET_SHA256
        or prior.get("limits")
        != {"max_tasks": MAX_TASKS, "max_calls": MAX_CALLS, "max_total_tokens": MAX_TOTAL_TOKENS, "max_cost_microusd": MAX_COST_MICROUSD}
    ):
        raise CalibrationError("calibration.prior_invalid")
    tasks = list(prior["tasks"])
    attempts = [LiveAttempt(**item) for item in prior["attempts"]]
    return (
        tasks,
        attempts,
        CalibrationBudget(
            calls=len(attempts),
            total_tokens=sum(item.input_tokens + item.output_tokens for item in attempts),
            cost_microusd=sum(item.cost_microusd for item in attempts),
            call_limit=call_limit,
            token_limit=token_limit,
            cost_limit_microusd=cost_limit_microusd,
        ),
    )


def _expansion_projection(
    scenarios: tuple[dict[str, Any], ...],
    rates: Mapping[tuple[str, str], PriceRate],
) -> dict[str, int | bool]:
    calls = 0
    tokens = 0
    cost = 0
    for scenario in scenarios:
        if scenario["scenario_id"] in PILOT_IDS:
            continue
        prompt_bytes = len(_prompt(scenario["request"]).encode("utf-8")) + len(
            json.dumps(
                ITINERARY_RESPONSE_SCHEMA,
                ensure_ascii=False,
                separators=(",", ":"),
                sort_keys=True,
            ).encode("utf-8")
        )
        max_output = itinerary_max_output_tokens(int(scenario["request"]["days"]))
        baseline_plan = certified_gemini_routes().plan(
            _required_capabilities(scenario["request"])
        )
        worst_routes = (*baseline_plan, certified_deepseek_route(), baseline_plan[0])
        calls += len(worst_routes)
        for route in worst_routes:
            rate = rates[(route.provider_id, route.model_id)]
            tokens += prompt_bytes + max_output
            cost += CalibrationBudget._cost(
                input_hit=0,
                input_miss=prompt_bytes,
                output=max_output,
                rate=rate,
            )
    return {
        "worst_additional_calls": calls,
        "worst_additional_tokens": tokens,
        "worst_additional_cost_microusd": cost,
    }


def run_calibration(
    *,
    manifest_path: Path,
    cohort: str,
    prior: dict[str, Any] | None = None,
    client: httpx.Client | None = None,
) -> dict[str, Any]:
    scenarios, manifest_sha256 = _load_manifest(manifest_path)
    rates, price_snapshot_sha256 = _load_prices()
    repair_v2 = cohort == "repair-v2"
    task_limit = REPAIR_V2_MAX_TASKS if repair_v2 else MAX_TASKS
    call_limit = REPAIR_V2_MAX_CALLS if repair_v2 else MAX_CALLS
    token_limit = REPAIR_V2_MAX_TOTAL_TOKENS if repair_v2 else MAX_TOTAL_TOKENS
    cost_limit = (
        REPAIR_V2_MAX_COST_MICROUSD if repair_v2 else MAX_COST_MICROUSD
    )
    limits = {
        "max_tasks": task_limit,
        "max_calls": call_limit,
        "max_total_tokens": token_limit,
        "max_cost_microusd": cost_limit,
    }
    missing = [
        name
        for name in ("GEMINI_API_KEY", "DEEPSEEK_API_KEY")
        if not os.environ.get(name, "")
    ]
    if missing:
        return {
            "schema_version": "1.0",
            "status": "pending_key",
            "missing_environment_variables": missing,
            "manifest_sha256": manifest_sha256,
            "dataset_sha256": DATASET_SHA256,
            "price_snapshot_sha256": price_snapshot_sha256,
            "limits": limits,
            "task_count": 0,
            "live_call_count": 0,
            "total_tokens": 0,
            "total_cost_microusd": 0,
            "redline_failure_count": 0,
            "secret_material_persisted": 0,
            "tasks": [],
            "attempts": [],
        }
    tasks, attempts, budget = _prior_values(
        prior,
        call_limit=call_limit,
        token_limit=token_limit,
        cost_limit_microusd=cost_limit,
    )
    completed_ids = {task["scenario_id"] for task in tasks}
    if len(completed_ids) * 2 != len(tasks):
        raise CalibrationError("calibration.prior_pairing_invalid")
    if cohort == "pilot":
        if prior is not None:
            raise CalibrationError("calibration.pilot_prior_forbidden")
        selected = [item for item in scenarios if item["scenario_id"] in PILOT_IDS]
    elif cohort == "expansion":
        if prior is None or not prior.get("expansion_allowed"):
            raise CalibrationError("calibration.expansion_not_allowed")
        selected = [item for item in scenarios if item["scenario_id"] not in PILOT_IDS]
    elif cohort == "repair-v2":
        if prior is not None:
            raise CalibrationError("calibration.repair_v2_prior_forbidden")
        selected = [item for item in scenarios if item["scenario_id"] in PILOT_IDS]
    else:
        raise CalibrationError("calibration.cohort_invalid")
    if completed_ids & {item["scenario_id"] for item in selected}:
        raise CalibrationError("calibration.duplicate_task")
    if len(completed_ids) + len(selected) > task_limit:
        raise CalibrationError("calibration.task_cap")

    owns_client = client is None
    live_client = client or httpx.Client(
        follow_redirects=False,
        timeout=httpx.Timeout(60.0),
    )
    try:
        for scenario in selected:
            prompt = _prompt(scenario["request"])
            input_sha256 = canonical_digest(prompt)
            input_ref = f"context://sha256/{input_sha256}"
            max_output_tokens = itinerary_max_output_tokens(
                int(scenario["request"]["days"])
            )
            baseline_plan = certified_gemini_routes().plan(
                _required_capabilities(scenario["request"])
            )
            for arm in ("baseline", "candidate"):
                tasks.append(
                    _execute_arm(
                        scenario=scenario,
                        arm=arm,
                        prompt=prompt,
                        input_ref=input_ref,
                        input_sha256=input_sha256,
                        max_output_tokens=max_output_tokens,
                        baseline_plan=baseline_plan,
                        client=live_client,
                        budget=budget,
                        rates=rates,
                        attempts=attempts,
                        max_total_attempts=1 if repair_v2 else 2,
                    )
                )
    finally:
        if owns_client:
            live_client.close()

    baseline = _arm_summary(tasks, attempts, "baseline")
    candidate = _arm_summary(tasks, attempts, "candidate")
    paired_mismatches = sum(
        {
            task["input_sha256"]
            for task in tasks
            if task["scenario_id"] == scenario_id
        }
        != {
            next(
                task["input_sha256"]
                for task in tasks
                if task["scenario_id"] == scenario_id and task["arm"] == "baseline"
            )
        }
        for scenario_id in sorted({task["scenario_id"] for task in tasks})
    )
    baseline_cost_per_success = baseline["cost_per_qualified_success_microusd"]
    candidate_cost_per_success = candidate["cost_per_qualified_success_microusd"]
    cost_ratio = (
        candidate_cost_per_success / baseline_cost_per_success
        if baseline_cost_per_success and candidate_cost_per_success is not None
        else None
    )
    baseline_p95 = baseline["p95_latency_ms"]
    candidate_p95 = candidate["p95_latency_ms"]
    latency_limit = (
        min(1.25 * baseline_p95, baseline_p95 + 5000)
        if baseline_p95 is not None
        else None
    )
    guardrails = {
        "quality_non_inferior": (
            baseline["qualified_success_count"] > 0
            and candidate["qualified_success_count"]
            >= baseline["qualified_success_count"]
        ),
        "cost_signal": cost_ratio is not None and cost_ratio <= 0.75,
        "latency": (
            candidate_p95 is not None
            and latency_limit is not None
            and candidate_p95 <= latency_limit
        ),
        "fallback": candidate["fallback_count"] <= 1
        and candidate["maximum_fallback_depth"] <= 1,
    }
    expansion_projection = _expansion_projection(scenarios, rates)
    expansion_projection.update(
        {
            "projected_calls": len(attempts)
            + int(expansion_projection["worst_additional_calls"]),
            "projected_tokens": sum(
                attempt.input_tokens + attempt.output_tokens for attempt in attempts
            )
            + int(expansion_projection["worst_additional_tokens"]),
            "projected_cost_microusd": sum(
                attempt.cost_microusd for attempt in attempts
            )
            + int(expansion_projection["worst_additional_cost_microusd"]),
        }
    )
    expansion_projection["within_caps"] = (
        expansion_projection["projected_calls"] <= MAX_CALLS
        and expansion_projection["projected_tokens"] <= MAX_TOTAL_TOKENS
        and expansion_projection["projected_cost_microusd"] <= MAX_COST_MICROUSD
    )
    provisional = {
        "schema_version": "2.0" if repair_v2 else "1.0",
        "status": (
            "repair_v2_complete"
            if repair_v2
            else "pilot_complete"
            if cohort == "pilot"
            else "complete"
        ),
        "cohort": cohort,
        "manifest_sha256": manifest_sha256,
        "dataset_sha256": DATASET_SHA256,
        "price_snapshot_sha256": price_snapshot_sha256,
        "limits": limits,
        "task_count": len({task["scenario_id"] for task in tasks}),
        "live_call_count": len(attempts),
        "total_tokens": sum(
            attempt.input_tokens + attempt.output_tokens for attempt in attempts
        ),
        "total_cost_microusd": sum(attempt.cost_microusd for attempt in attempts),
        "arms": {"baseline": baseline, "candidate": candidate},
        "candidate_cost_per_success_ratio": cost_ratio,
        "candidate_latency_limit_ms": latency_limit,
        "guardrails": guardrails,
        "expansion_budget": expansion_projection,
        "paired_input_mismatch_count": paired_mismatches,
        "tasks": tasks,
        "attempts": [asdict(attempt) for attempt in attempts],
        "secret_material_persisted": 0,
        "production_write_count": 0,
        "claim_boundary": "bounded local synthetic live sample; not production traffic or invoice",
    }
    redlines = {
        "task_cap_exceeded": int(provisional["task_count"] > task_limit),
        "call_cap_exceeded": int(provisional["live_call_count"] > call_limit),
        "token_cap_exceeded": int(provisional["total_tokens"] > token_limit),
        "cost_cap_exceeded": int(
            provisional["total_cost_microusd"] > cost_limit
        ),
        "paired_input_mismatch": paired_mismatches,
        "fallback_depth_gt_1": int(candidate["maximum_fallback_depth"] > 1),
        "secret_or_content_evidence_field": _make_output_sensitive_key_count(
            provisional
        ),
        "production_write": 0,
    }
    redline_failure_count = sum(redlines.values())
    expansion_allowed = (
        cohort == "pilot"
        and all(guardrails.values())
        and redline_failure_count == 0
        and bool(expansion_projection["within_caps"])
    )
    provisional["redlines"] = redlines
    provisional["redline_failure_count"] = redline_failure_count
    provisional["expansion_allowed"] = expansion_allowed
    provisional["benefit_claim_eligible"] = bool(
        baseline["qualified_success_count"] > 0
        and candidate["qualified_success_count"] > 0
        and all(guardrails.values())
        and redline_failure_count == 0
    )
    provisional["candidate_allocation"] = 0
    provisional["allocation_change_authorized"] = False
    return provisional


def _run_deepseek_quality_calibration(
    *,
    manifest_path: Path,
    client: httpx.Client | None,
    cohort: str,
    schema_version: str,
    scenario_ids: frozenset[str] | None,
    max_tasks: int,
    max_calls: int,
    max_total_tokens: int,
    max_cost_microusd: int,
    max_retries: int,
    complete_status: str,
    repair_status: str,
) -> dict[str, Any]:
    """Certify DeepSeek quality across every stratum without a Gemini live arm."""

    all_scenarios, manifest_sha256 = _load_manifest(manifest_path)
    scenarios = tuple(
        scenario
        for scenario in all_scenarios
        if scenario_ids is None or scenario["scenario_id"] in scenario_ids
    )
    rates, price_snapshot_sha256 = _load_prices()
    limits = {
        "max_tasks": max_tasks,
        "max_calls": max_calls,
        "max_total_tokens": max_total_tokens,
        "max_cost_microusd": max_cost_microusd,
        "max_retryable_retries": max_retries,
    }
    if not os.environ.get("DEEPSEEK_API_KEY", ""):
        return {
            "schema_version": schema_version,
            "status": "pending_key",
            "missing_environment_variables": ["DEEPSEEK_API_KEY"],
            "manifest_sha256": manifest_sha256,
            "dataset_sha256": DATASET_SHA256,
            "price_snapshot_sha256": price_snapshot_sha256,
            "limits": limits,
            "task_count": 0,
            "live_call_count": 0,
            "total_tokens": 0,
            "total_cost_microusd": 0,
            "redline_failure_count": 0,
            "secret_material_persisted": 0,
            "tasks": [],
            "attempts": [],
            "candidate_allocation": 0,
        }
    if len(scenarios) != max_tasks:
        raise CalibrationError("calibration.deepseek_scenario_count")
    budget = CalibrationBudget(
        call_limit=max_calls,
        token_limit=max_total_tokens,
        cost_limit_microusd=max_cost_microusd,
    )
    attempts: list[LiveAttempt] = []
    tasks: list[dict[str, Any]] = []
    retries = 0
    owns_client = client is None
    live_client = client or httpx.Client(
        follow_redirects=False,
        timeout=httpx.Timeout(60.0),
    )
    try:
        for scenario in scenarios:
            prompt = _prompt(scenario["request"])
            input_sha256 = canonical_digest(prompt)
            input_ref = f"context://sha256/{input_sha256}"
            max_output_tokens = itinerary_max_output_tokens(
                int(scenario["request"]["days"])
            )
            baseline_plan = certified_gemini_routes().plan(
                _required_capabilities(scenario["request"])
            )
            task = _execute_arm(
                scenario=scenario,
                arm="candidate",
                prompt=prompt,
                input_ref=input_ref,
                input_sha256=input_sha256,
                max_output_tokens=max_output_tokens,
                baseline_plan=baseline_plan,
                client=live_client,
                budget=budget,
                rates=rates,
                attempts=attempts,
                max_total_attempts=1,
            )
            initial_failure = task["failure_class"]
            task["retry_used"] = False
            task["initial_failure_class"] = initial_failure
            if (
                initial_failure in DEEPSEEK_V3_RETRYABLE_CODES
                and retries < max_retries
            ):
                retries += 1
                retry = _execute_arm(
                    scenario=scenario,
                    arm="candidate",
                    prompt=prompt,
                    input_ref=input_ref,
                    input_sha256=input_sha256,
                    max_output_tokens=max_output_tokens,
                    baseline_plan=baseline_plan,
                    client=live_client,
                    budget=budget,
                    rates=rates,
                    attempts=attempts,
                    max_total_attempts=1,
                )
                retry["attempt_count"] += task["attempt_count"]
                retry["latency_ms"] += task["latency_ms"]
                retry["retry_used"] = True
                retry["initial_failure_class"] = initial_failure
                task = retry
            tasks.append(task)
    finally:
        if owns_client:
            live_client.close()

    candidate = _arm_summary(tasks, attempts, "candidate")
    qualified_latencies = [
        int(task["latency_ms"])
        for task in tasks
        if task["quality_qualified"]
    ]
    provider_failure_count = sum(
        task["failure_class"] in DEEPSEEK_V3_RETRYABLE_CODES for task in tasks
    )
    quality_rule_failure_count = sum(
        bool(task["quality_rule_codes"]) for task in tasks
    )
    redlines = {
        "task_cap_exceeded": int(len(tasks) > max_tasks),
        "call_cap_exceeded": int(len(attempts) > max_calls),
        "token_cap_exceeded": int(budget.total_tokens > max_total_tokens),
        "cost_cap_exceeded": int(budget.cost_microusd > max_cost_microusd),
        "retry_cap_exceeded": int(retries > max_retries),
        "secret_or_content_evidence_field": 0,
        "production_write": 0,
    }
    redline_failure_count = sum(redlines.values())
    guardrails = {
        "all_strata_quality_qualified": candidate["qualified_success_count"]
        == len(scenarios),
        "schema_and_business_rules": quality_rule_failure_count == 0,
        "bounded_retry": retries <= max_retries
        and all(int(task["attempt_count"]) <= 2 for task in tasks),
        "provider_availability": provider_failure_count == 0,
        "successful_task_p95_latency_lte_20s": (
            (_nearest_rank_p95(qualified_latencies) or 0) <= 20_000
        ),
        "safety_redlines": redline_failure_count == 0,
    }
    quality_gate_passed = all(guardrails.values())
    result = {
        "schema_version": schema_version,
        "status": (
            complete_status if quality_gate_passed else repair_status
        ),
        "cohort": cohort,
        "manifest_sha256": manifest_sha256,
        "dataset_sha256": DATASET_SHA256,
        "price_snapshot_sha256": price_snapshot_sha256,
        "limits": limits,
        "task_count": len(tasks),
        "live_call_count": len(attempts),
        "retry_count": retries,
        "total_tokens": budget.total_tokens,
        "total_cost_microusd": budget.cost_microusd,
        "cost_per_qualified_success_microusd": candidate[
            "cost_per_qualified_success_microusd"
        ],
        "qualified_success_count": candidate["qualified_success_count"],
        "quality_rule_failure_count": quality_rule_failure_count,
        "provider_failure_count": provider_failure_count,
        "successful_task_p95_latency_ms": _nearest_rank_p95(qualified_latencies),
        "guardrails": guardrails,
        "quality_gate_passed": quality_gate_passed,
        "redlines": redlines,
        "redline_failure_count": redline_failure_count,
        "tasks": tasks,
        "attempts": [asdict(attempt) for attempt in attempts],
        "candidate_allocation": 0,
        "allocation_change_authorized": False,
        "benefit_claim_eligible": False,
        "secret_material_persisted": 0,
        "production_write_count": 0,
        "claim_boundary": (
            "DeepSeek-only local quality and unit-cost evidence; no live baseline, "
            "relative Cost Router benefit or production suitability claim."
        ),
    }
    result["redlines"]["secret_or_content_evidence_field"] = (
        _make_output_sensitive_key_count(result)
    )
    result["redline_failure_count"] = sum(result["redlines"].values())
    result["guardrails"]["safety_redlines"] = (
        result["redline_failure_count"] == 0
    )
    result["quality_gate_passed"] = all(result["guardrails"].values())
    if not result["quality_gate_passed"]:
        result["status"] = repair_status
    return result


def run_deepseek_quality_calibration(
    *, manifest_path: Path, client: httpx.Client | None = None
) -> dict[str, Any]:
    return _run_deepseek_quality_calibration(
        manifest_path=manifest_path,
        client=client,
        cohort="deepseek-quality-v3",
        schema_version="3.0",
        scenario_ids=None,
        max_tasks=DEEPSEEK_V3_MAX_TASKS,
        max_calls=DEEPSEEK_V3_MAX_CALLS,
        max_total_tokens=DEEPSEEK_V3_MAX_TOTAL_TOKENS,
        max_cost_microusd=DEEPSEEK_V3_MAX_COST_MICROUSD,
        max_retries=DEEPSEEK_V3_MAX_RETRIES,
        complete_status="deepseek_quality_complete",
        repair_status="deepseek_quality_repair_required",
    )


def run_deepseek_targeted_repair_calibration(
    *, manifest_path: Path, client: httpx.Client | None = None
) -> dict[str, Any]:
    return _run_deepseek_quality_calibration(
        manifest_path=manifest_path,
        client=client,
        cohort="deepseek-targeted-v4",
        schema_version="4.0",
        scenario_ids=DEEPSEEK_V4_SCENARIO_IDS,
        max_tasks=DEEPSEEK_V4_MAX_TASKS,
        max_calls=DEEPSEEK_V4_MAX_CALLS,
        max_total_tokens=DEEPSEEK_V4_MAX_TOTAL_TOKENS,
        max_cost_microusd=DEEPSEEK_V4_MAX_COST_MICROUSD,
        max_retries=0,
        complete_status="deepseek_targeted_repair_complete",
        repair_status="deepseek_targeted_repair_required",
    )


def run_deepseek_identifier_repair_calibration(
    *, manifest_path: Path, client: httpx.Client | None = None
) -> dict[str, Any]:
    return _run_deepseek_quality_calibration(
        manifest_path=manifest_path,
        client=client,
        cohort="deepseek-identifier-v5",
        schema_version="5.0",
        scenario_ids=DEEPSEEK_V5_SCENARIO_IDS,
        max_tasks=DEEPSEEK_V5_MAX_TASKS,
        max_calls=DEEPSEEK_V5_MAX_CALLS,
        max_total_tokens=DEEPSEEK_V5_MAX_TOTAL_TOKENS,
        max_cost_microusd=DEEPSEEK_V5_MAX_COST_MICROUSD,
        max_retries=0,
        complete_status="deepseek_identifier_repair_complete",
        repair_status="deepseek_identifier_repair_required",
    )


def _atomic_write(path: Path, value: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(
        json.dumps(value, ensure_ascii=True, sort_keys=True, separators=(",", ":"))
        + "\n",
        encoding="utf-8",
    )
    temporary.replace(path)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument(
        "--cohort",
        choices=(
            "pilot",
            "expansion",
            "repair-v2",
            "deepseek-quality-v3",
            "deepseek-targeted-v4",
            "deepseek-identifier-v5",
        ),
        required=True,
    )
    parser.add_argument("--prior", type=Path)
    args = parser.parse_args()
    prior = (
        json.loads(args.prior.read_text(encoding="utf-8")) if args.prior else None
    )
    result = (
        run_deepseek_quality_calibration(manifest_path=args.manifest)
        if args.cohort == "deepseek-quality-v3"
        else run_deepseek_targeted_repair_calibration(manifest_path=args.manifest)
        if args.cohort == "deepseek-targeted-v4"
        else run_deepseek_identifier_repair_calibration(manifest_path=args.manifest)
        if args.cohort == "deepseek-identifier-v5"
        else run_calibration(
            manifest_path=args.manifest,
            cohort=args.cohort,
            prior=prior,
        )
    )
    _atomic_write(args.output, result)
    summary = {
        key: result.get(key)
        for key in (
            "status",
            "cohort",
            "task_count",
            "live_call_count",
            "total_tokens",
            "total_cost_microusd",
            "redline_failure_count",
            "expansion_allowed",
            "quality_gate_passed",
            "qualified_success_count",
            "retry_count",
            "secret_material_persisted",
        )
    }
    print(json.dumps(summary, sort_keys=True, separators=(",", ":")))
    return int(
        result["status"] == "pending_key"
        or result.get("redline_failure_count", 0) != 0
    )


if __name__ == "__main__":
    raise SystemExit(main())
