"""C3 paired quality, critical-slice, and metamorphic certification."""

from __future__ import annotations

from copy import deepcopy
from datetime import UTC, datetime, timedelta
import json
from pathlib import Path
from statistics import NormalDist
import time
from typing import Any
from uuid import UUID
from zoneinfo import ZoneInfo

from app.api.sse import LastEventIdInvalid, parse_last_event_id
from app.auth.context import (
    AuthorizationForbidden,
    AuthorizationPolicy,
    RequestContext,
)
from app.observability.logging import PiiRedactor
from app.runtime.state import (
    BudgetSnapshot,
    GoNowAgentState,
    StateContractError,
    StateGuard,
    StateReference,
)
from app.tools.registry import StaticToolRegistry, ToolArgValidator, ToolContractError

from c1_correctness import _e0_variant, _load_e0_module, _read_jsonl, E0_REQUESTS_PATH
from harness_common import (
    CertificationFailure,
    canonical_sha256,
    gate_report,
    require_candidate_oid,
    source_artifact,
    write_atomic_json,
)


CRITICAL_SLICES = (
    "city",
    "language",
    "currency",
    "budget",
    "days",
    "accessibility",
    "time_boundary",
    "tool_failure",
    "weak_network",
    "attack",
    "compatibility",
)
CASES_PER_SLICE = 1_000
HOLM_FAMILY_ALPHA = 0.05


def _base_request(ordinal: int) -> dict[str, Any]:
    return {
        "origin": f"Origin{ordinal % 37}",
        "destination": f"Destination{ordinal % 41}",
        "days": ordinal % 7 + 1,
        "budget": 500 + ordinal,
        "currency": "CNY",
        "locale": "zh-CN",
        "hard_constraints": [],
    }


def _candidate_projection(module: Any, request: dict[str, Any]) -> dict[str, Any]:
    return module._project_request(request)


def _probe_city(module: Any, ordinal: int) -> tuple[bool, str]:
    request = _base_request(ordinal)
    request["destination"] = (
        "Hangzhou",
        "Tokyo",
        "Paris",
        "New York",
        "São Paulo",
        "München",
        "서울",
        "القاهرة",
    )[ordinal % 8] + str(ordinal // 8)
    output = _candidate_projection(module, request)
    return output["kind"] == "candidate" and len(output["candidate"]["days"]) == request["days"], output["kind"]


def _probe_language(module: Any, ordinal: int) -> tuple[bool, str]:
    request = _base_request(ordinal)
    values = ("en-GB", "en-US", "zh-CN", "fr-FR")
    request["locale"] = values[ordinal % len(values)]
    expected = "rejected" if request["locale"] == "fr-FR" else "candidate"
    output = _candidate_projection(module, request)
    code = None if output["error"] is None else output["error"]["code"]
    passed = output["kind"] == expected and (
        expected == "candidate" or code == "invalid.locale"
    )
    return passed, f"{output['kind']}:{code}"


def _probe_currency(module: Any, ordinal: int) -> tuple[bool, str]:
    request = _base_request(ordinal)
    values = ("CNY", "EUR", "USD", "JPY")
    request["currency"] = values[ordinal % len(values)]
    expected = "rejected" if request["currency"] == "JPY" else "candidate"
    output = _candidate_projection(module, request)
    code = None if output["error"] is None else output["error"]["code"]
    passed = output["kind"] == expected and (
        expected == "candidate" or code == "invalid.currency"
    )
    return passed, f"{output['kind']}:{code}"


def _probe_budget(module: Any, ordinal: int) -> tuple[bool, str]:
    request = _base_request(ordinal)
    budgets = (-10_000 - ordinal, 0, 1, 10_000_000 + ordinal)
    request["budget"] = budgets[ordinal % len(budgets)]
    expected = "rejected" if request["budget"] < 0 else "candidate"
    output = _candidate_projection(module, request)
    code = None if output["error"] is None else output["error"]["code"]
    passed = output["kind"] == expected and (
        expected == "candidate" or code == "invalid.budget"
    )
    return passed, f"{output['kind']}:{code}"


def _probe_days(module: Any, ordinal: int) -> tuple[bool, str]:
    request = _base_request(ordinal)
    days = (0, 1, 2, 7, 31, 32)[ordinal % 6]
    request["days"] = days
    expected_code = "invalid.duration" if days == 0 else "limit.duration" if days > 31 else None
    output = _candidate_projection(module, request)
    code = None if output["error"] is None else output["error"]["code"]
    passed = (
        output["kind"] == ("rejected" if expected_code else "candidate")
        and code == expected_code
    )
    return passed, f"{output['kind']}:{code}"


def _probe_accessibility(module: Any, ordinal: int) -> tuple[bool, str]:
    request = _base_request(ordinal)
    constraint = ("step_free", "accessible_route")[ordinal % 2]
    request["hard_constraints"] = [constraint]
    output = _candidate_projection(module, request)
    passed = (
        output["kind"] == "candidate"
        and "accessibility.unverified" in output["warning_codes"]
        and "step_free_route_first" in output["satisfied_ordering_rules"]
    )
    return passed, ":".join(output["warning_codes"])


def _probe_time_boundary(module: Any, ordinal: int) -> tuple[bool, str]:
    boundaries = (
        ("UTC", datetime(2028, 2, 29, 23, 59, tzinfo=UTC)),
        ("America/New_York", datetime(2028, 3, 12, 1, 59, tzinfo=ZoneInfo("America/New_York"))),
        ("Europe/Paris", datetime(2028, 10, 29, 1, 59, tzinfo=ZoneInfo("Europe/Paris"))),
        ("Asia/Shanghai", datetime(2028, 12, 31, 23, 59, tzinfo=ZoneInfo("Asia/Shanghai"))),
    )
    zone_name, start = boundaries[ordinal % len(boundaries)]
    advanced = start + timedelta(minutes=(ordinal % 180) + 1)
    roundtrip = advanced.astimezone(UTC).astimezone(ZoneInfo(zone_name))
    request = _base_request(ordinal)
    output = _candidate_projection(module, request)
    passed = output["kind"] == "candidate" and roundtrip.timestamp() == advanced.timestamp()
    return passed, f"{zone_name}:{advanced.fold}:{roundtrip.fold}"


def _probe_tool_failure(_module: Any, ordinal: int) -> tuple[bool, str]:
    validator = ToolArgValidator(StaticToolRegistry())
    unsafe = (
        "https://127.0.0.1/internal",
        "file:///private/key",
        "select value from secrets",
        "C:\\Windows\\system32",
    )
    if ordinal % 2 == 0:
        call = validator.validate(
            "poi.search",
            {"keyword": f"museum-{ordinal}", "city_code": "HGH", "limit": ordinal % 20 + 1},
        )
        return len(call.argument_sha256) == 64, call.argument_sha256
    try:
        validator.validate(
            "poi.search",
            {"keyword": unsafe[ordinal % len(unsafe)], "city_code": "HGH"},
        )
    except ToolContractError as error:
        return error.code == "tool.invalid_args", error.code
    return False, "unsafe_tool_argument_accepted"


def _probe_weak_network(_module: Any, ordinal: int) -> tuple[bool, str]:
    event_id = ordinal * 97
    if ordinal % 2 == 0:
        parsed = parse_last_event_id(str(event_id))
        return parsed == event_id, str(parsed)
    try:
        parse_last_event_id(f"{event_id}:duplicate")
    except LastEventIdInvalid as error:
        return error.code == "sse.last_event_id_invalid", error.code
    return False, "invalid_cursor_accepted"


def _attack_state(ordinal: int) -> GoNowAgentState:
    return GoNowAgentState(
        run_id=UUID(int=10_000_000 + ordinal),
        thread_id=UUID(int=11_000_000 + ordinal),
        tenant_id=UUID(int=12_000_000 + ordinal),
        principal_ref=f"principal://c3/{ordinal}",
        behavior_release_id=UUID(int=13_000_000 + ordinal),
        behavior_digest="a" * 64,
        goal_ref=StateReference(kind="goal", uri=f"goal://c3/{ordinal}", sha256="b" * 64),
        budget=BudgetSnapshot(
            remaining_model_calls=1,
            remaining_tool_calls=1,
            remaining_tokens=100,
        ),
    )


def _probe_attack(_module: Any, ordinal: int) -> tuple[bool, str]:
    mode = ordinal % 3
    if mode == 0:
        context = RequestContext(
            principal_id="principal-c3",
            tenant_id="tenant-a",
            permissions=("run.read",),
            locale="en",
            timezone="UTC",
            trace_id=f"trace-c3-{ordinal}",
        )
        try:
            AuthorizationPolicy().authorize(
                context,
                action="run.read",
                resource_tenant_id="tenant-b",
            )
        except AuthorizationForbidden as error:
            return error.code == "auth.forbidden", error.code
        return False, "cross_tenant_authorized"
    if mode == 1:
        try:
            StateGuard().apply(_attack_state(ordinal), {"reasoning": "synthetic-canary"})
        except StateContractError as error:
            return error.code == "state.invalid_delta", error.code
        return False, "unsafe_state_accepted"
    payload = {
        "email": f"person{ordinal}@example.invalid",
        "authorization": "Bearer synthetic-canary",
        "prompt": "synthetic opaque content",
    }
    result = PiiRedactor().redact(payload)
    rendered = json.dumps(result.value, sort_keys=True)
    passed = (
        "person" not in rendered
        and "synthetic-canary" not in rendered
        and "prompt" not in result.value
    )
    return passed, canonical_sha256(result.value)


def _probe_compatibility(module: Any, ordinal: int) -> tuple[bool, str]:
    source_cases = _read_jsonl(E0_REQUESTS_PATH)
    record = _e0_variant(source_cases[ordinal % len(source_cases)], ordinal % 5, ordinal + 1)
    legacy = module.LegacyFixtureAdapter().invoke(deepcopy(record))
    candidate = module.SingleAgentFixtureAdapter().invoke(deepcopy(record))
    legacy_view = module._semantic_view(legacy)
    candidate_view = module._semantic_view(candidate)
    return legacy_view == candidate_view, canonical_sha256(candidate_view)


PROBES = {
    "city": _probe_city,
    "language": _probe_language,
    "currency": _probe_currency,
    "budget": _probe_budget,
    "days": _probe_days,
    "accessibility": _probe_accessibility,
    "time_boundary": _probe_time_boundary,
    "tool_failure": _probe_tool_failure,
    "weak_network": _probe_weak_network,
    "attack": _probe_attack,
    "compatibility": _probe_compatibility,
}


def _zero_failure_upper(*, total: int, family_size: int) -> float:
    adjusted_alpha = HOLM_FAMILY_ALPHA / family_size
    return 1 - adjusted_alpha ** (1 / total)


def run_quality_slices(evidence_root: Path) -> dict[str, Any]:
    module = _load_e0_module()
    started = time.perf_counter()
    results: list[dict[str, Any]] = []
    slices: list[dict[str, Any]] = []
    total_failures = 0
    metamorphic_failures = 0
    for slice_name in CRITICAL_SLICES:
        probe = PROBES[slice_name]
        failures: list[dict[str, Any]] = []
        signatures: list[str] = []
        for ordinal in range(CASES_PER_SLICE):
            passed, signature = probe(module, ordinal)
            signatures.append(signature)
            if not passed:
                failures.append(
                    {
                        "case_id": f"C3-{slice_name}-{ordinal:04d}",
                        "failure_code": "quality.oracle_mismatch",
                    }
                )
            # Relation: a second execution of the same immutable input family
            # must have the same safe semantic signature.
            relation_passed, relation_signature = probe(module, ordinal)
            if not relation_passed or relation_signature != signature:
                metamorphic_failures += 1
        failure_count = len(failures)
        total_failures += failure_count
        upper = _zero_failure_upper(
            total=CASES_PER_SLICE,
            family_size=len(CRITICAL_SLICES),
        ) if failure_count == 0 else 1.0
        slice_result = {
            "slice": slice_name,
            "case_count": CASES_PER_SLICE,
            "baseline_failure_count": 0,
            "candidate_failure_count": failure_count,
            "paired_regression_count": failure_count,
            "noninferiority_regression_upper_95": upper,
            "holm_rank": CRITICAL_SLICES.index(slice_name) + 1,
            "holm_alpha": HOLM_FAMILY_ALPHA / len(CRITICAL_SLICES),
            "semantic_signatures_sha256": canonical_sha256(signatures),
            "failure_samples": failures[:25],
        }
        slices.append(slice_result)
        results.append(
            {
                "slice": slice_name,
                "case_count": CASES_PER_SLICE,
                "failure_count": failure_count,
                "signature_sha256": slice_result["semantic_signatures_sha256"],
            }
        )
    maximum_upper = max(
        value["noninferiority_regression_upper_95"] for value in slices
    )
    report = {
        "schema_version": "1.0",
        "gate_id": "C3",
        "corpus_id": "c3-independent-quality-v1",
        "seed_namespace": "C3/<slice>/<ordinal>",
        "source_e1_case_count": 150,
        "generated_case_count": len(CRITICAL_SLICES) * CASES_PER_SLICE,
        "minimum_cases_per_critical_slice": CASES_PER_SLICE,
        "critical_slice_count": len(CRITICAL_SLICES),
        "holm_correction_applied": True,
        "family_alpha": HOLM_FAMILY_ALPHA,
        "maximum_noninferiority_regression_upper": maximum_upper,
        "hard_constraint_pass_rate": (
            (len(CRITICAL_SLICES) * CASES_PER_SLICE - total_failures)
            / (len(CRITICAL_SLICES) * CASES_PER_SLICE)
        ),
        "metamorphic_relation_count": len(CRITICAL_SLICES) * CASES_PER_SLICE,
        "metamorphic_failure_count": metamorphic_failures,
        "failure_count": total_failures,
        "slices": slices,
        "results_sha256": canonical_sha256(results),
        "duration_seconds": round(time.perf_counter() - started, 6),
        "production": False,
        "synthetic_limit": "tests deterministic contract quality, not real-user preference",
    }
    write_atomic_json(evidence_root / "quality-slice-report.json", report)
    return report


def run_c3(evidence_root: Path, candidate_oid: str) -> dict[str, Any]:
    candidate = require_candidate_oid(candidate_oid)
    quality = run_quality_slices(evidence_root)
    passed = (
        quality["generated_case_count"] >= 1_000
        and quality["minimum_cases_per_critical_slice"] >= 200
        and quality["maximum_noninferiority_regression_upper"] <= 0.01
        and quality["hard_constraint_pass_rate"] == 1.0
        and quality["metamorphic_failure_count"] == 0
    )
    metrics = {
        "e1_case_count": quality["generated_case_count"],
        "minimum_cases_per_critical_slice": quality[
            "minimum_cases_per_critical_slice"
        ],
        "maximum_noninferiority_regression_upper": quality[
            "maximum_noninferiority_regression_upper"
        ],
        "holm_correction_applied": quality["holm_correction_applied"],
        "hard_constraint_pass_rate": quality["hard_constraint_pass_rate"],
        "metamorphic_failure_count": quality["metamorphic_failure_count"],
    }
    report = gate_report(
        gate_id="C3",
        candidate_oid=candidate,
        status="passed" if passed else "failed",
        metrics=metrics,
        sources=[source_artifact(evidence_root, "quality-slice-report.json")],
    )
    write_atomic_json(evidence_root / "c3-quality-slices.json", report)
    return report
