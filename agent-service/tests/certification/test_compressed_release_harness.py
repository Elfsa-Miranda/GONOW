from __future__ import annotations

from pathlib import Path
import json
import os
import sys

import httpx
import pytest


CERTIFICATION_ROOT = Path(__file__).resolve().parent
SERVICE_ROOT = CERTIFICATION_ROOT.parents[1]
sys.path.insert(0, str(CERTIFICATION_ROOT))
sys.path.insert(0, str(SERVICE_ROOT))

from c1_correctness import _run_sequence, run_expanded_e0  # noqa: E402
from c2_security_performance_cost import run_security_matrix  # noqa: E402
from c3_quality import run_quality_slices  # noqa: E402
from c4_recovery_soak import (  # noqa: E402
    _decode_soak_samples,
    _formal_soak_contract_failures,
    _handle_count,
    _rss_bytes,
    _windows_process_api,
    run_c4,
    run_c4_fast,
    run_real_soak,
)
from c5_operations import run_rollback_operations  # noqa: E402
from harness_common import (  # noqa: E402
    CertificationFailure,
    require_candidate_oid,
    wilson_lower_bound,
)
from live_provider_gemini import (  # noqa: E402
    CONFIG_PATH,
    load_live_config,
    projected_maximum_cost,
    run_gemini_live,
)


def test_candidate_identity_and_confidence_bounds_fail_closed() -> None:
    assert require_candidate_oid("a" * 40) == "a" * 40
    assert wilson_lower_bound(50_000, 50_000) > 0.999
    with pytest.raises(CertificationFailure):
        require_candidate_oid("not-an-oid")
    with pytest.raises(CertificationFailure):
        wilson_lower_bound(1, 0)


def test_c1_expansion_is_unique_and_state_sequences_are_replayable(tmp_path: Path) -> None:
    expanded = run_expanded_e0(tmp_path)
    assert expanded["case_count"] == 200
    assert expanded["unique_input_count"] >= 160
    assert expanded["failure_count"] == 0
    assert [_run_sequence(seed) for seed in range(50)] == [
        _run_sequence(seed) for seed in range(50)
    ]


def test_c2_generated_security_matrix_kills_fail_open_mutants(tmp_path: Path) -> None:
    report = run_security_matrix(tmp_path)
    assert report["generated_security_attempt_count"] == 100_000
    assert report["failure_count"] == 0
    assert report["critical_mutation_kill_rate"] == 1.0


def test_c3_holm_corrected_slices_meet_noninferiority(tmp_path: Path) -> None:
    report = run_quality_slices(tmp_path)
    assert report["generated_case_count"] == 11_000
    assert report["minimum_cases_per_critical_slice"] == 1_000
    assert report["maximum_noninferiority_regression_upper"] <= 0.01
    assert report["failure_count"] == 0


def test_c4_fast_volume_is_not_relabelled_as_soak(tmp_path: Path) -> None:
    report = run_c4_fast(tmp_path)
    assert report["fault"]["schedule_count"] == 420
    assert report["virtual"]["fake_provider_lifecycle_count"] == 100_000
    assert report["judge"]["annotation_count"] == 400
    assert not (tmp_path / "soak-report.json").exists()


@pytest.mark.skipif(os.name != "nt", reason="Windows ctypes resource probe")
def test_c4_windows_resource_probe_reuses_ctypes_metadata() -> None:
    api = _windows_process_api()
    rss_values = [_rss_bytes() for _ in range(100)]
    handle_values = [_handle_count() for _ in range(100)]

    assert _windows_process_api() is api
    assert _windows_process_api.cache_info().misses == 1
    assert all(value > 0 for value in rss_values)
    assert all(value > 0 for value in handle_values)


def test_c4_real_soak_isolates_workload_from_evidence_observer(
    tmp_path: Path,
) -> None:
    report = run_real_soak(
        tmp_path,
        duration_seconds=1,
        sample_interval_seconds=0.1,
    )
    samples = json.loads((tmp_path / "soak-samples.json").read_text("utf-8"))

    assert report["sample_count"] == len(samples["samples"])
    assert report["samples_artifact_sha256"]
    assert report["gc_before_sample"] is True
    assert report["measurement_mode"] == "spawned_workload_process"
    assert report["observer_process_id"] != report["workload_process_id"]
    assert report["child_exit_code"] == 0
    assert not list(tmp_path.glob(".soak-child-*.tmp"))


def test_c4_real_soak_child_failure_is_fail_closed(tmp_path: Path) -> None:
    report = run_real_soak(
        tmp_path,
        duration_seconds=1,
        sample_interval_seconds=0.1,
        _child_failure_mode="before_samples",
    )

    assert report["status"] == "failed"
    assert report["child_exit_code"] == 4
    assert report["failure_count"] >= 1
    assert report["failure_samples"][0]["failure_code"] == "c4.soak_child_failed"


def test_c4_binary_sample_stream_rejects_partial_record(tmp_path: Path) -> None:
    sample_path = tmp_path / "partial.bin"
    sample_path.write_bytes(b"partial")

    with pytest.raises(CertificationFailure, match="c4.soak_sample_stream_invalid"):
        _decode_soak_samples(sample_path)


def _valid_formal_soak_report() -> dict[str, object]:
    return {
        "status": "passed",
        "soak_id": "c4-real-resource-soak-v1",
        "target_seconds": 14_400,
        "real_soak_seconds": 14_400.1,
        "sample_interval_seconds": 30,
        "sample_count": 480,
        "slope_sample_count": 360,
        "iteration_count": 1,
        "measurement_mode": "spawned_workload_process",
        "observer_process_id": 100,
        "workload_process_id": 101,
        "child_exit_code": 0,
        "child_scratch_artifact_count": 0,
        "failure_count": 0,
        "monotonic_clock": True,
        "gc_before_sample": True,
        "slopes_valid": True,
        "positive_resource_slope_count": 0,
        "positive_resource_slope_fields": [],
        "resource_returned_to_baseline": True,
        "database_kind": "isolated_postgresql",
        "production": False,
        "samples_path": "soak-samples.json",
        "samples_artifact_sha256": "a" * 64,
        "child_result_sha256": "b" * 64,
    }


def test_c4_formal_soak_contract_rejects_same_process_and_weak_evidence() -> None:
    valid = _valid_formal_soak_report()
    assert _formal_soak_contract_failures(valid) == []

    mutations = {
        "measurement_mode": "same_process",
        "workload_process_id": 100,
        "child_exit_code": 4,
        "child_scratch_artifact_count": 1,
        "sample_count": 479,
        "slope_sample_count": 359,
        "slopes_valid": False,
        "database_kind": "not_configured",
    }
    for field, invalid_value in mutations.items():
        tampered = dict(valid)
        tampered[field] = invalid_value
        assert _formal_soak_contract_failures(tampered), field


def test_c4_gate_directly_binds_the_soak_samples_source(tmp_path: Path) -> None:
    samples_path = tmp_path / "soak-samples.json"
    samples_path.write_text(
        json.dumps(
            {
                "schema_version": "1.0",
                "soak_id": "c4-real-resource-soak-v1",
                "samples": [],
            },
            sort_keys=True,
        ),
        "utf-8",
    )
    soak = _valid_formal_soak_report()
    (tmp_path / "soak-report.json").write_text(
        json.dumps(soak, sort_keys=True), "utf-8"
    )

    report = run_c4(tmp_path, "c" * 40)

    matching_sources = [
        source
        for source in report["source_artifacts"]
        if source["path"] == "soak-samples.json"
    ]
    assert report["status"] == "passed"
    assert len(matching_sources) == 1
    assert matching_sources[0]["sha256"]


def test_c4_gate_fails_closed_when_soak_samples_are_missing(tmp_path: Path) -> None:
    soak = _valid_formal_soak_report()
    (tmp_path / "soak-report.json").write_text(
        json.dumps(soak, sort_keys=True), "utf-8"
    )

    report = run_c4(tmp_path, "c" * 40)

    assert report["status"] == "failed"
    assert "c4.soak_samples_missing" in report["blocker_codes"]
    assert not any(
        source["path"] == "soak-samples.json"
        for source in report["source_artifacts"]
    )


def test_c5_fault_catalog_and_short_observation_are_executable(tmp_path: Path) -> None:
    report = run_rollback_operations(tmp_path, observation_seconds=1)
    assert report["fault_class_count"] == 20
    assert report["fault_failure_count"] == 0
    assert report["new_run_after_kill_count"] == 0
    assert report["old_path_success_rate"] == 1.0


def test_c2_live_gemini_executor_emits_only_content_free_receipts(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    secret = "synthetic-provider-credential-value"
    monkeypatch.setenv("GEMINI_API_KEY", secret)
    post_count = 0

    def handler(request: httpx.Request) -> httpx.Response:
        nonlocal post_count
        if request.method == "GET":
            return httpx.Response(200, content=b"official-pricing-snapshot")
        assert request.headers["x-goog-api-key"] == secret
        assert request.url.host == "generativelanguage.googleapis.com"
        request_body = json.loads(request.content)
        assert request_body["generationConfig"]["thinkingConfig"] == {
            "thinkingLevel": "low"
        }
        model_id = request.url.path.split("/")[-1].split(":")[0]
        expected_output_limit = {
            "gemini-3.1-flash-lite": 384,
            "gemini-3.6-flash": 64,
        }[model_id]
        assert request_body["generationConfig"]["maxOutputTokens"] == expected_output_limit
        post_count += 1
        return httpx.Response(
            200,
            json={
                "candidates": [
                    {
                        "finishReason": "STOP",
                        "content": {"parts": [{"text": '{"ok":true}'}]},
                    }
                ],
                "usageMetadata": {
                    "promptTokenCount": 20,
                    "candidatesTokenCount": 5,
                    "thoughtsTokenCount": 3,
                    "totalTokenCount": 28,
                },
            },
        )

    with httpx.Client(transport=httpx.MockTransport(handler)) as client:
        report = run_gemini_live(
            tmp_path,
            candidate_oid="a" * 40,
            client=client,
            sleeper=lambda _: None,
        )
    assert post_count == 400
    assert report["status"] == "passed"
    assert report["successful_call_count"] == 400
    assert report["credential_value_recorded"] is False
    assert projected_maximum_cost(load_live_config()) == pytest.approx(0.2336)
    assert {
        row["route_id"]: row["maximum_output_tokens_per_call"]
        for row in report["route_receipts"]
    } == {"economic": 384, "capability": 64}
    evidence = (tmp_path / "live-provider-receipts.json").read_text("utf-8")
    assert secret not in evidence
    assert "Return one JSON" not in evidence
    assert '{"ok":true}' not in evidence


def test_c2_live_config_prevents_projected_budget_overrun(tmp_path: Path) -> None:
    config = json.loads(CONFIG_PATH.read_text("utf-8"))
    config["budget_cap_usd"] = 0.000001
    path = tmp_path / "over-budget.json"
    path.write_text(json.dumps(config), encoding="utf-8")
    with pytest.raises(CertificationFailure, match="c2.live_projected_cost_exceeds_budget"):
        load_live_config(path)

    config = json.loads(CONFIG_PATH.read_text("utf-8"))
    config["routes"][0]["maximum_output_tokens_per_call"] = 439
    route_over_budget = tmp_path / "route-over-budget.json"
    route_over_budget.write_text(json.dumps(config), encoding="utf-8")
    with pytest.raises(CertificationFailure, match="c2.live_projected_cost_exceeds_budget"):
        load_live_config(route_over_budget)
    assert projected_maximum_cost(load_live_config()) <= 0.25


def test_c2_live_config_rejects_route_model_swap_and_boolean_limits(tmp_path: Path) -> None:
    config = json.loads(CONFIG_PATH.read_text("utf-8"))
    config["routes"][0]["model_id"] = "gemini-3.6-flash"
    swapped = tmp_path / "swapped-route.json"
    swapped.write_text(json.dumps(config), encoding="utf-8")
    with pytest.raises(CertificationFailure, match="c2.live_model_not_allowlisted"):
        load_live_config(swapped)

    config = json.loads(CONFIG_PATH.read_text("utf-8"))
    config["routes"][0]["maximum_output_tokens_per_call"] = True
    boolean_limit = tmp_path / "boolean-limit.json"
    boolean_limit.write_text(json.dumps(config), encoding="utf-8")
    with pytest.raises(CertificationFailure, match="c2.live_output_limit_invalid"):
        load_live_config(boolean_limit)


@pytest.mark.parametrize(
    ("field", "value", "failure_code"),
    [
        ("provider_id", "caller-selected-provider", "c2.live_config_boundary_invalid"),
        ("calls_per_route", 201, "c2.live_config_invalid"),
        ("requests_per_minute", 21, "c2.live_config_invalid"),
        ("budget_cap_usd", 0.250001, "c2.live_config_invalid"),
    ],
)
def test_c2_live_config_freezes_provider_volume_rate_and_budget(
    tmp_path: Path, field: str, value: object, failure_code: str
) -> None:
    config = json.loads(CONFIG_PATH.read_text("utf-8"))
    config[field] = value
    path = tmp_path / f"invalid-{field}.json"
    path.write_text(json.dumps(config), encoding="utf-8")
    with pytest.raises(CertificationFailure, match=failure_code):
        load_live_config(path)


def test_c2_live_quota_circuit_stops_repeated_429_requests(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setenv("GEMINI_API_KEY", "synthetic-provider-credential-value")
    post_count = 0

    def handler(request: httpx.Request) -> httpx.Response:
        nonlocal post_count
        if request.method == "GET":
            return httpx.Response(200, content=b"official-pricing-snapshot")
        post_count += 1
        return httpx.Response(429, json={"error": {"status": "RESOURCE_EXHAUSTED"}})

    with httpx.Client(transport=httpx.MockTransport(handler)) as client:
        report = run_gemini_live(
            tmp_path,
            candidate_oid="b" * 40,
            client=client,
            sleeper=lambda _: None,
        )
    assert report["status"] == "blocked"
    assert post_count == 6
    assert report["provider_request_count"] == 6
    assert report["successful_call_count"] == 0
    assert report["quota_circuit_open_routes"] == ["capability", "economic"]


def test_c2_live_non_stop_failure_keeps_only_allowlisted_scalar_diagnostics(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    secret = "synthetic-provider-credential-value"
    injected_finish_reason = "secret-provider-text-must-not-survive"
    monkeypatch.setenv("GEMINI_API_KEY", secret)
    route_attempts = {"economic": 0, "capability": 0}

    def handler(request: httpx.Request) -> httpx.Response:
        if request.method == "GET":
            return httpx.Response(200, content=b"official-pricing-snapshot")
        model_id = request.url.path.split("/")[-1].split(":")[0]
        route_id = "economic" if model_id == "gemini-3.1-flash-lite" else "capability"
        route_attempts[route_id] += 1
        if route_id == "economic" and route_attempts[route_id] in {1, 2}:
            return httpx.Response(
                200,
                json={
                    "candidates": [
                        {
                            "finishReason": "MAX_TOKENS"
                            if route_attempts[route_id] == 1
                            else injected_finish_reason,
                            "content": {"parts": [{"text": "response-body-must-not-survive"}]},
                        }
                    ],
                    "usageMetadata": {
                        "promptTokenCount": 20,
                        "candidatesTokenCount": 0,
                        "thoughtsTokenCount": 384,
                        "totalTokenCount": 404,
                    },
                },
            )
        return httpx.Response(429, json={"error": {"detail": "provider-body-must-not-survive"}})

    with httpx.Client(transport=httpx.MockTransport(handler)) as client:
        report = run_gemini_live(
            tmp_path,
            candidate_oid="c" * 40,
            client=client,
            sleeper=lambda _: None,
        )
    assert report["status"] == "blocked"
    assert route_attempts == {"economic": 5, "capability": 3}
    first = next(row for row in report["failure_receipts"] if row["call_id"] == "economic-0001")
    assert first == {
        "call_id": "economic-0001",
        "route_id": "economic",
        "failure_code": "llm.incomplete_output",
        "provider_http_status": 200,
        "finish_reason": "MAX_TOKENS",
        "prompt_token_count": 20,
        "candidate_token_count": 0,
        "thought_token_count": 384,
        "total_token_count": 404,
    }
    second = next(row for row in report["failure_receipts"] if row["call_id"] == "economic-0002")
    assert second["finish_reason"] == "UNRECOGNIZED"
    evidence = (tmp_path / "live-provider-receipts.json").read_text("utf-8")
    for forbidden in (
        secret,
        injected_finish_reason,
        "response-body-must-not-survive",
        "provider-body-must-not-survive",
    ):
        assert forbidden not in evidence
