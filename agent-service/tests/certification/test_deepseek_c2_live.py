from __future__ import annotations

import json
import site
import sys
from pathlib import Path

import httpx
import pytest


SERVICE_ROOT = Path(__file__).resolve().parents[2]
site.addsitedir(str(SERVICE_ROOT / ".venv" / "Lib" / "site-packages"))
sys.path.insert(0, str(SERVICE_ROOT))
sys.path.insert(0, str(Path(__file__).resolve().parent))

from app.models.deepseek import MODEL_ID  # noqa: E402
from app.models.json_schema import canonical_schema_text  # noqa: E402
from app.worker.itinerary_processor import ITINERARY_RESPONSE_SCHEMA  # noqa: E402
from c2_security_performance_cost import _load_live_provider_receipt  # noqa: E402
from harness_common import CertificationFailure, sha256_file  # noqa: E402
from live_provider_deepseek import (  # noqa: E402
    CONFIG_PATH,
    EVIDENCE_DIRECTORY,
    SCHEMA_PATH,
    _call_once,
    load_live_config,
    projected_maximum_cost,
    run_deepseek_live,
)


CANDIDATE = "a" * 40
FIXTURE_PATH = Path(__file__).with_name("fixtures") / (
    "deepseek-c2-captured-response-v1.json"
)


def _valid_response() -> dict[str, object]:
    return {
        "choices": [
            {
                "finish_reason": "stop",
                "message": {
                    "content": json.dumps(
                        {
                            "title": "C2 contract probe",
                            "days": [
                                {
                                    "day_number": 1,
                                    "items": [
                                        {
                                            "item_id": "item_c2_probe",
                                            "title": "Morning walk",
                                            "start_minute": 480,
                                            "duration_minutes": 60,
                                        }
                                    ],
                                }
                            ],
                        },
                        separators=(",", ":"),
                    )
                },
            }
        ],
        "usage": {
            "prompt_tokens": 742,
            "completion_tokens": 81,
            "total_tokens": 823,
            "prompt_cache_hit_tokens": 512,
            "prompt_cache_miss_tokens": 230,
        },
    }


def _success_handler(observed: list[dict[str, object]]):
    schema_text = canonical_schema_text(ITINERARY_RESPONSE_SCHEMA)

    def handler(request: httpx.Request) -> httpx.Response:
        if request.method == "GET":
            return httpx.Response(200, content=b"official-pricing-snapshot")
        body = json.loads(request.content)
        observed.append(body)
        assert body == {
            "model": MODEL_ID,
            "messages": [
                {
                    "role": "system",
                    "content": (
                        "Return only one JSON object that matches this complete JSON "
                        "Schema exactly; do not add fields. JSON Schema:" + schema_text
                    ),
                },
                {
                    "role": "user",
                    "content": (
                        "Return JSON for exactly one itinerary day with exactly one "
                        "item. Use day_number 1, a globally unique item_id matching "
                        "item_[a-z0-9_-]+, a non-empty title, a start_minute from 360 "
                        "through 600, and a positive duration_minutes that ends by "
                        "minute 1200. Do not invent claim_ids."
                    ),
                },
            ],
            "thinking": {"type": "disabled"},
            "response_format": {"type": "json_object"},
            "temperature": 0,
            "max_tokens": 512,
        }
        return httpx.Response(200, json=_valid_response())

    return handler


def test_deepseek_config_freezes_model_schema_parameters_prices_and_denominator() -> None:
    config = load_live_config()
    schema = json.loads(SCHEMA_PATH.read_text("utf-8"))
    assert config.model_id == "deepseek-v4-flash"
    assert config.calls_per_route == 200
    assert config.requests_per_minute == 20
    assert config.budget_cap_usd == 0.25
    assert config.pricing_source_url == (
        "https://api-docs.deepseek.com/quick_start/pricing/"
    )
    assert config.response_schema_sha256 == sha256_file(SCHEMA_PATH)
    assert schema == ITINERARY_RESPONSE_SCHEMA
    assert {route.model_id for route in config.routes} == {"deepseek-v4-flash"}
    assert projected_maximum_cost(config) == pytest.approx(0.172032)


@pytest.mark.parametrize(
    ("field", "value", "failure_code"),
    [
        ("model_id", "caller-selected-model", "c2.live_config_boundary_invalid"),
        ("calls_per_route", 199, "c2.live_failure_denominator_invalid"),
        ("requests_per_minute", 21, "c2.live_config_invalid"),
        ("budget_cap_usd", 0.26, "c2.live_config_invalid"),
    ],
)
def test_deepseek_config_rejects_boundary_or_threshold_drift(
    tmp_path: Path, field: str, value: object, failure_code: str
) -> None:
    raw = json.loads(CONFIG_PATH.read_text("utf-8"))
    raw[field] = value
    if field == "calls_per_route":
        raw["failure_denominator"]["attempted_slots_per_route"] = value
    path = tmp_path / "config.json"
    path.write_text(json.dumps(raw), encoding="utf-8")
    with pytest.raises(CertificationFailure, match=failure_code):
        load_live_config(path)


def test_deepseek_config_rejects_parameter_schema_and_price_drift(
    tmp_path: Path,
) -> None:
    mutations = (
        lambda raw: raw["fixed_parameters"].update({"temperature": 0.1}),
        lambda raw: raw.update({"response_schema_sha256": "0" * 64}),
        lambda raw: raw["routes"][0].update(
            {"output_usd_per_million_tokens": 0.27}
        ),
    )
    for index, mutation in enumerate(mutations):
        raw = json.loads(CONFIG_PATH.read_text("utf-8"))
        mutation(raw)
        path = tmp_path / f"config-{index}.json"
        path.write_text(json.dumps(raw), encoding="utf-8")
        with pytest.raises(CertificationFailure):
            load_live_config(path)


def test_captured_response_envelope_passes_complete_schema_and_business_contract() -> None:
    fixture = json.loads(FIXTURE_PATH.read_text("utf-8"))
    assert fixture["provenance"]["raw_provider_content_preserved"] is False
    assert fixture["provenance"]["safe_payload_source"] == "synthetic_schema_equivalent"
    client = httpx.Client(
        transport=httpx.MockTransport(
            lambda _: httpx.Response(200, json=fixture["provider_response"])
        )
    )
    try:
        receipt, failure = _call_once(
            client,
            config=load_live_config(),
            route=load_live_config().routes[0],
            api_key="synthetic-provider-credential",
        )
    finally:
        client.close()
    assert failure is None
    assert receipt is not None
    assert receipt["schema_and_business_rule_failure_count"] == 0
    assert receipt["input_tokens"] == 742
    assert receipt["output_tokens"] == 81


def test_fake_400_slot_run_is_content_free_budgeted_and_additive(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setenv("DEEPSEEK_API_KEY", "synthetic-provider-credential")
    historical = tmp_path / "live-provider-receipts.json"
    historical.write_text('{"historical":"gemini"}\n', encoding="utf-8")
    before = historical.read_bytes()
    observed: list[dict[str, object]] = []
    client = httpx.Client(transport=httpx.MockTransport(_success_handler(observed)))
    try:
        report = run_deepseek_live(
            tmp_path,
            candidate_oid=CANDIDATE,
            client=client,
            sleeper=lambda _: None,
        )
    finally:
        client.close()
    assert len(observed) == 400
    assert historical.read_bytes() == before
    assert report["status"] == "passed"
    assert report["successful_call_count"] == 400
    assert report["failed_call_count"] == 0
    assert report["failure_denominator_count"] == 400
    assert report["projected_maximum_cost_usd"] == pytest.approx(0.172032)
    assert report["actual_total_cost_usd"] < report["budget_cap_usd"]
    assert report["complete_json_schema_delivered"] is True
    assert report["local_schema_and_business_validation"] is True
    assert report["same_failure_denominator_as_gemini_v1"] is True
    assert report["historical_gemini_evidence_overwrite_count"] == 0
    assert all(row["attempted_slot_count"] == 200 for row in report["route_receipts"])
    assert all(row["call_count"] == 200 for row in report["route_receipts"])
    assert all(row["failure_count"] == 0 for row in report["route_receipts"])
    loaded, blockers = _load_live_provider_receipt(
        tmp_path, expected_candidate_oid=CANDIDATE
    )
    assert blockers == []
    assert loaded == report
    evidence_text = (tmp_path / EVIDENCE_DIRECTORY / "live-provider-receipts.json").read_text(
        "utf-8"
    )
    assert "synthetic-provider-credential" not in evidence_text
    assert "Morning walk" not in evidence_text


def test_quota_circuit_preserves_all_failed_slots_and_redacts_provider_body(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setenv("DEEPSEEK_API_KEY", "synthetic-provider-credential")

    def handler(request: httpx.Request) -> httpx.Response:
        if request.method == "GET":
            return httpx.Response(200, content=b"official-pricing-snapshot")
        return httpx.Response(
            429,
            json={
                "error": {
                    "message": "secret-provider-body-must-not-survive",
                    "credential": "synthetic-provider-credential",
                }
            },
        )

    client = httpx.Client(transport=httpx.MockTransport(handler))
    try:
        report = run_deepseek_live(
            tmp_path,
            candidate_oid=CANDIDATE,
            client=client,
            sleeper=lambda _: None,
        )
    finally:
        client.close()
    assert report["status"] == "blocked"
    assert report["provider_request_count"] == 6
    assert report["successful_call_count"] == 0
    assert report["failed_call_count"] == 400
    assert report["failure_denominator_count"] == 400
    assert report["quota_circuit_open_routes"] == ["capability", "economic"]
    assert all(row["failure_denominator_count"] == 200 for row in report["route_receipts"])
    evidence_text = (tmp_path / EVIDENCE_DIRECTORY / "live-provider-receipts.json").read_text(
        "utf-8"
    )
    for forbidden in (
        "secret-provider-body-must-not-survive",
        "synthetic-provider-credential",
        '"credential"',
    ):
        assert forbidden not in evidence_text
