from __future__ import annotations

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
        prompt = body["messages"][0]["content"]
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
