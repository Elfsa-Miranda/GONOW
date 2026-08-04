from __future__ import annotations

import copy
import json
from pathlib import Path
import site
import sys

import httpx
import pytest


SERVICE_ROOT = Path(__file__).resolve().parents[2]
REPOSITORY_ROOT = SERVICE_ROOT.parent
site.addsitedir(str(SERVICE_ROOT / ".venv" / "Lib" / "site-packages"))
sys.path.insert(0, str(SERVICE_ROOT))

from scripts import run_p12b_live_calibration as live  # noqa: E402
from app.worker.itinerary_processor import itinerary_business_rule_codes  # noqa: E402


MANIFEST = REPOSITORY_ROOT / "docs/execution/evidence/phase-12b/P12B-010/calibration-dataset-manifest.json"


def _output(days: int, destination: str) -> dict[str, object]:
    return {
        "title": f"Synthetic {destination} itinerary",
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
            for day in range(1, days + 1)
        ],
    }


def _request_input(prompt: str) -> dict[str, object]:
    return json.loads(prompt.rsplit(" Input:", 1)[1])


def _handler(request: httpx.Request) -> httpx.Response:
    body = json.loads(request.content)
    if request.url.host == "api.deepseek.com":
        prompt = body["messages"][-1]["content"]
        structured = _request_input(prompt)
        payload = _output(int(structured["days"]), str(structured["destination"]))
        return httpx.Response(
            200,
            json={
                "choices": [
                    {
                        "finish_reason": "stop",
                        "message": {"content": json.dumps(payload)},
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
    assert request.url.host == "generativelanguage.googleapis.com"
    prompt = body["contents"][0]["parts"][0]["text"]
    structured = _request_input(prompt)
    payload = _output(int(structured["days"]), str(structured["destination"]))
    return httpx.Response(
        200,
        json={
            "candidates": [
                {
                    "finishReason": "STOP",
                    "content": {"parts": [{"text": json.dumps(payload)}]},
                }
            ],
            "usageMetadata": {
                "promptTokenCount": 120,
                "candidatesTokenCount": 80,
                "totalTokenCount": 200,
            },
        },
    )


@pytest.fixture
def ready_environment(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("GEMINI_API_KEY", "synthetic-gemini-credential")
    monkeypatch.setenv("DEEPSEEK_API_KEY", "synthetic-deepseek-credential")
    counter = iter(index / 100 for index in range(10_000))
    monkeypatch.setattr(live.time, "monotonic", lambda: next(counter))


def test_missing_key_receipt_has_zero_calls_and_no_secret_value(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.delenv("GEMINI_API_KEY", raising=False)
    monkeypatch.delenv("DEEPSEEK_API_KEY", raising=False)
    result = live.run_calibration(manifest_path=MANIFEST, cohort="pilot")
    assert result["status"] == "pending_key"
    assert result["live_call_count"] == 0
    assert result["total_tokens"] == 0
    assert result["secret_material_persisted"] == 0
    assert "synthetic" not in json.dumps(result)


def test_pilot_uses_eight_mock_calls_and_freezes_expansion_budget(
    ready_environment: None,
) -> None:
    with httpx.Client(transport=httpx.MockTransport(_handler)) as client:
        result = live.run_calibration(
            manifest_path=MANIFEST, cohort="pilot", client=client
        )
    assert result["status"] == "pilot_complete"
    assert result["task_count"] == 4
    assert result["live_call_count"] == 8
    assert result["total_tokens"] == 1600
    assert result["arms"]["baseline"]["qualified_success_count"] == 4
    assert result["arms"]["candidate"]["qualified_success_count"] == 4
    assert result["redline_failure_count"] == 0
    assert result["expansion_budget"]["within_caps"]
    assert result["expansion_allowed"]
    assert result["secret_material_persisted"] == 0
    serialized = json.dumps(result)
    assert "synthetic-gemini-credential" not in serialized
    assert "synthetic-deepseek-credential" not in serialized


def test_expansion_resumes_without_repeating_pilot(
    ready_environment: None,
) -> None:
    with httpx.Client(transport=httpx.MockTransport(_handler)) as client:
        pilot = live.run_calibration(
            manifest_path=MANIFEST, cohort="pilot", client=client
        )
        complete = live.run_calibration(
            manifest_path=MANIFEST,
            cohort="expansion",
            prior=pilot,
            client=client,
        )
    assert complete["status"] == "complete"
    assert complete["task_count"] == 10
    assert complete["live_call_count"] == 20
    assert complete["total_tokens"] == 4000
    assert len({task["scenario_id"] for task in complete["tasks"]}) == 10
    assert complete["redline_failure_count"] == 0
    assert not complete["expansion_allowed"]


def test_hard_caps_fail_before_an_additional_call() -> None:
    rate = live.PriceRate(
        "provider",
        "model",
        live.Decimal("1"),
        live.Decimal("1"),
        live.Decimal("1"),
    )
    budget = live.CalibrationBudget(calls=live.MAX_CALLS)
    with pytest.raises(live.CalibrationError, match="calibration.call_cap"):
        budget.authorize_call(
            prompt_utf8_bytes=1, max_output_tokens=1, rate=rate
        )
    assert budget.calls == live.MAX_CALLS
    token_budget = live.CalibrationBudget(total_tokens=live.MAX_TOTAL_TOKENS)
    with pytest.raises(live.CalibrationError, match="calibration.token_cap"):
        token_budget.authorize_call(
            prompt_utf8_bytes=1, max_output_tokens=1, rate=rate
        )
    assert token_budget.calls == 0


def test_expansion_refuses_tampered_or_non_signal_prior(
    ready_environment: None,
) -> None:
    with httpx.Client(transport=httpx.MockTransport(_handler)) as client:
        pilot = live.run_calibration(
            manifest_path=MANIFEST, cohort="pilot", client=client
        )
        blocked = dict(pilot)
        blocked["expansion_allowed"] = False
        with pytest.raises(
            live.CalibrationError, match="calibration.expansion_not_allowed"
        ):
            live.run_calibration(
                manifest_path=MANIFEST,
                cohort="expansion",
                prior=blocked,
                client=client,
            )
        tampered = dict(pilot)
        tampered["dataset_sha256"] = "0" * 64
        with pytest.raises(live.CalibrationError, match="calibration.prior_invalid"):
            live.run_calibration(
                manifest_path=MANIFEST,
                cohort="expansion",
                prior=tampered,
                client=client,
            )


def test_zero_success_on_both_arms_is_not_quality_non_inferiority(
    ready_environment: None,
) -> None:
    with httpx.Client(
        transport=httpx.MockTransport(
            lambda _: httpx.Response(400, json={"error": {}})
        )
    ) as client:
        result = live.run_calibration(
            manifest_path=MANIFEST, cohort="pilot", client=client
        )
    assert result["arms"]["baseline"]["qualified_success_count"] == 0
    assert result["arms"]["candidate"]["qualified_success_count"] == 0
    assert not result["guardrails"]["quality_non_inferior"]
    assert not result["expansion_allowed"]


def test_repair_v2_is_independent_one_attempt_per_arm_and_allocation_zero(
    ready_environment: None,
) -> None:
    with httpx.Client(transport=httpx.MockTransport(_handler)) as client:
        result = live.run_calibration(
            manifest_path=MANIFEST, cohort="repair-v2", client=client
        )
    assert result["schema_version"] == "2.0"
    assert result["status"] == "repair_v2_complete"
    assert result["task_count"] == 4
    assert result["live_call_count"] == 8
    assert result["limits"] == {
        "max_tasks": 4,
        "max_calls": 8,
        "max_total_tokens": 40_000,
        "max_cost_microusd": 500_000,
    }
    assert all(task["attempt_count"] == 1 for task in result["tasks"])
    assert result["arms"]["baseline"]["qualified_success_count"] == 4
    assert result["arms"]["candidate"]["qualified_success_count"] == 4
    assert result["candidate_allocation"] == 0
    assert not result["allocation_change_authorized"]
    assert result["secret_material_persisted"] == 0


def test_repair_v2_records_specific_quality_codes_and_metering_without_body(
    ready_environment: None,
) -> None:
    def invalid_handler(request: httpx.Request) -> httpx.Response:
        body = json.loads(request.content)
        if request.url.host == "api.deepseek.com":
            prompt = body["messages"][-1]["content"]
            structured = _request_input(prompt)
            payload = _output(
                int(structured["days"]), str(structured["destination"])
            )
            payload["days"][0]["items"][0]["start_minute"] = 1300  # type: ignore[index]
            payload["days"][0]["items"][0]["duration_minutes"] = 180  # type: ignore[index]
            return httpx.Response(
                200,
                json={
                    "choices": [
                        {
                            "finish_reason": "stop",
                            "message": {"content": json.dumps(payload)},
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
        return _handler(request)

    with httpx.Client(transport=httpx.MockTransport(invalid_handler)) as client:
        result = live.run_calibration(
            manifest_path=MANIFEST, cohort="repair-v2", client=client
        )
    candidate_tasks = [task for task in result["tasks"] if task["arm"] == "candidate"]
    assert all(task["quality_rule_codes"] for task in candidate_tasks)
    assert result["arms"]["candidate"]["total_tokens"] == 800
    serialized = json.dumps(result)
    assert "response_body" not in serialized
    assert "Synthetic day" not in serialized


@pytest.mark.parametrize(
    ("mutation", "expected"),
    [
        ("day_count", "quality.exact_day_count"),
        ("day_numbers", "quality.consecutive_day_numbers"),
        ("duplicate_id", "quality.unique_item_ids"),
        ("overlap", "quality.no_overlap"),
        ("late_night", "quality.no_late_night"),
        ("daylight", "quality.daylight_only"),
        ("morning", "quality.morning_start"),
        ("item_cap", "quality.max_3_items_per_day"),
        ("day_end", "quality.day_end_within_1440"),
        ("unknown_claim", "quality.claim_id_not_available"),
    ],
)
def test_business_guardrails_emit_finite_rule_codes(
    mutation: str, expected: str
) -> None:
    request = {
        "days": 2,
        "hard_constraints": [
            "no_overlap",
            "no_late_night",
            "daylight_only",
            "morning_start",
            "max_3_items_per_day",
        ],
    }
    payload = _output(2, "Hangzhou")
    days = payload["days"]
    assert isinstance(days, list)
    first = days[0]
    assert isinstance(first, dict)
    items = first["items"]
    assert isinstance(items, list)
    item = items[0]
    assert isinstance(item, dict)
    if mutation == "day_count":
        days.pop()
    elif mutation == "day_numbers":
        first["day_number"] = 2
    elif mutation == "duplicate_id":
        second_items = days[1]["items"]
        second_items[0]["item_id"] = item["item_id"]
    elif mutation == "overlap":
        duplicate = copy.deepcopy(item)
        duplicate["item_id"] = "item_overlap"
        duplicate["start_minute"] = 600
        items.append(duplicate)
    elif mutation == "late_night":
        item["start_minute"] = 1_300
        item["duration_minutes"] = 60
    elif mutation == "daylight":
        item["start_minute"] = 300
    elif mutation == "morning":
        item["start_minute"] = 700
    elif mutation == "item_cap":
        for index in range(3):
            duplicate = copy.deepcopy(item)
            duplicate["item_id"] = f"item_extra_{index}"
            duplicate["start_minute"] = 780 + index * 120
            items.append(duplicate)
    elif mutation == "day_end":
        item["start_minute"] = 1_400
        item["duration_minutes"] = 100
    elif mutation == "unknown_claim":
        item["claim_ids"] = ["knowledge_0123456789abcdef"]
    codes = itinerary_business_rule_codes(
        payload,
        request,
        quality_checks=request["hard_constraints"],
    )
    assert expected in codes


def test_deepseek_v3_covers_all_strata_with_no_gemini_calls(
    ready_environment: None,
) -> None:
    hosts: list[str] = []

    def handler(request: httpx.Request) -> httpx.Response:
        assert request.url.host is not None
        hosts.append(request.url.host)
        return _handler(request)

    with httpx.Client(transport=httpx.MockTransport(handler)) as client:
        result = live.run_deepseek_quality_calibration(
            manifest_path=MANIFEST, client=client
        )
    assert result["status"] == "deepseek_quality_complete"
    assert result["task_count"] == 10
    assert result["live_call_count"] == 10
    assert result["retry_count"] == 0
    assert result["qualified_success_count"] == 10
    assert result["quality_rule_failure_count"] == 0
    assert all(result["guardrails"].values())
    assert set(hosts) == {"api.deepseek.com"}
    assert result["candidate_allocation"] == 0
    assert not result["benefit_claim_eligible"]


def test_deepseek_v3_retries_only_four_retryable_failures(
    ready_environment: None,
) -> None:
    failed_once: set[str] = set()

    def handler(request: httpx.Request) -> httpx.Response:
        body = json.loads(request.content)
        prompt = body["messages"][-1]["content"]
        scenario = _request_input(prompt)
        destination = str(scenario["destination"])
        if len(failed_once) < 4 and destination not in failed_once:
            failed_once.add(destination)
            return httpx.Response(503, json={"error": {"status": "UNAVAILABLE"}})
        return _handler(request)

    with httpx.Client(transport=httpx.MockTransport(handler)) as client:
        result = live.run_deepseek_quality_calibration(
            manifest_path=MANIFEST, client=client
        )
    assert result["live_call_count"] == 14
    assert result["retry_count"] == 4
    assert result["qualified_success_count"] == 10
    assert all(int(task["attempt_count"]) <= 2 for task in result["tasks"])
    assert result["redline_failure_count"] == 0


def test_deepseek_v4_rechecks_only_three_failed_scenarios_without_retry(
    ready_environment: None,
) -> None:
    hosts: list[str] = []

    def handler(request: httpx.Request) -> httpx.Response:
        assert request.url.host is not None
        hosts.append(request.url.host)
        return _handler(request)

    with httpx.Client(transport=httpx.MockTransport(handler)) as client:
        result = live.run_deepseek_targeted_repair_calibration(
            manifest_path=MANIFEST, client=client
        )
    assert result["status"] == "deepseek_targeted_repair_complete"
    assert result["task_count"] == 3
    assert result["live_call_count"] == 3
    assert result["retry_count"] == 0
    assert result["qualified_success_count"] == 3
    assert result["quality_rule_failure_count"] == 0
    assert {task["scenario_id"] for task in result["tasks"]} == {
        "CR-V1-003",
        "CR-V1-008",
        "CR-V1-009",
    }
    assert result["limits"] == {
        "max_tasks": 3,
        "max_calls": 3,
        "max_total_tokens": 10_000,
        "max_cost_microusd": 250_000,
        "max_retryable_retries": 0,
    }
    assert all(result["guardrails"].values())
    assert hosts == ["api.deepseek.com"] * 3
    assert result["candidate_allocation"] == 0
    assert not result["benefit_claim_eligible"]
