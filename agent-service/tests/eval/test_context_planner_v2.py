from __future__ import annotations

import json
from pathlib import Path

import pytest

from app.evaluation.context_planner_v2 import (
    ContextEvaluationError,
    run_evaluation,
    verify_report,
)


FIXTURE_ROOT = Path(__file__).resolve().parents[1] / "fixtures" / "context-planner-v2"


def _report() -> dict[str, object]:
    return run_evaluation(
        FIXTURE_ROOT,
        e0_passes=8,
        full_ci_passed=False,
        live_provider_evidence=False,
    )


def test_paired_runner_reports_every_frozen_case_and_keeps_default_disabled() -> None:
    report = _report()
    verify_report(report, FIXTURE_ROOT)

    assert len(report["pairs"]) == 24
    assert all(item["expected_terminal_matched"] for item in report["pairs"])
    assert report["measurements"]["hard_semantic_coverage"] == 1.0
    assert report["measurements"]["long_context_overflow_wins"] >= 1
    assert report["decision"] == "KEEP_DISABLED"
    assert report["hard_gates"]["full_ci"] is False
    assert report["activation_gates"]["live_provider_evidence"] is False
    assert report["production_write_count"] == 0


def test_candidate_results_are_reproducible_across_three_runs() -> None:
    reports = [_report() for _ in range(3)]
    candidate_pairs = [
        [item["candidate"] for item in report["pairs"]] for report in reports
    ]
    for ordinal in range(24):
        stable = [
            {
                key: pair_set[ordinal][key]
                for key in pair_set[ordinal]
                if key != "compile_latency_ms"
            }
            for pair_set in candidate_pairs
        ]
        assert len({json.dumps(item, sort_keys=True) for item in stable}) == 1


@pytest.mark.parametrize(
    ("field", "value"),
    (("manifest_sha256", "f" * 64), ("decision", "ENABLE"), ("pairs", [])),
)
def test_report_tampering_fails_closed(field: str, value: object) -> None:
    report = _report()
    report[field] = value
    with pytest.raises(ContextEvaluationError):
        verify_report(report, FIXTURE_ROOT)
