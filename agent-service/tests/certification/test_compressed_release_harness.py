from __future__ import annotations

from pathlib import Path
import json
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
from c4_recovery_soak import run_c4_fast  # noqa: E402
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
                    "totalTokenCount": 25,
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
    assert projected_maximum_cost(load_live_config()) <= 0.1
