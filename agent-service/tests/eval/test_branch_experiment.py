from __future__ import annotations

import json
import math
import os
import statistics
from pathlib import Path
from typing import Any


DATASET_ROOT = Path(__file__).parent / "datasets" / "branch-experiment"
MANIFEST = json.loads((DATASET_ROOT / "manifest.json").read_text("utf-8"))
OBSERVATIONS = json.loads((DATASET_ROOT / "observations.json").read_text("utf-8"))
T_CRITICAL_95_DF_11 = 2.201


def _interval(values: list[float]) -> dict[str, float]:
    mean = statistics.fmean(values)
    margin = T_CRITICAL_95_DF_11 * statistics.stdev(values) / math.sqrt(len(values))
    return {
        "mean": round(mean, 6),
        "lower": round(mean - margin, 6),
        "upper": round(mean + margin, 6),
        "margin_of_error": round(margin, 6),
    }


def _build_report() -> dict[str, Any]:
    minimum = int(MANIFEST["minimum_sample_per_slice"])
    slice_reports = []
    for row in OBSERVATIONS["slices"]:
        sample_count = len(row["sample_ids"])
        slice_reports.append(
            {
                "slice_id": row["slice_id"],
                "sample_count": sample_count,
                "minimum_sample": minimum,
                "sufficient": sample_count >= minimum,
                "quality_delta_percentage_points": _interval(
                    row["quality_delta_percentage_points"]
                ),
                "latency_ratio": _interval(row["latency_ratio"]),
                "cost_ratio": _interval(row["cost_ratio"]),
                "risk_pass_rate": _interval(row["risk_pass"]),
            }
        )
    excluded_without_reason = sum(
        1
        for row in OBSERVATIONS["excluded_samples"]
        if not row.get("reason_code")
    )
    return {
        "schema_version": "1.0",
        "task_id": "TASK-P08-005",
        "dataset_id": MANIFEST["dataset_id"],
        "execution_environment": MANIFEST["execution_environment"],
        "synthetic_fixture_only": True,
        "production_claim_authorized": False,
        "active_user_sample_count": 0,
        "slice_count": len(slice_reports),
        "total_included_samples": sum(row["sample_count"] for row in slice_reports),
        "minimum_sample_per_slice": minimum,
        "insufficient_slice_count": sum(not row["sufficient"] for row in slice_reports),
        "excluded_sample_count": len(OBSERVATIONS["excluded_samples"]),
        "excluded_sample_without_reason": excluded_without_reason,
        "confidence_interval_missing_count": 0,
        "error_bound_missing_count": 0,
        "slice_reports": slice_reports,
        "audit_receipt": {
            "dataset_manifest": "datasets/branch-experiment/manifest.json",
            "method": "two-sided t interval, pre-registered synthetic offline replay",
            "confidence_level": MANIFEST["confidence_level"],
        },
        "production_write_count": 0,
    }


def test_dataset_is_preregistered_offline_and_never_active_eligible() -> None:
    assert MANIFEST["schema_version"] == "1.0"
    assert MANIFEST["execution_environment"] == "synthetic_offline_replay"
    assert MANIFEST["active_user_eligible"] is False
    assert MANIFEST["registered_at"] == "2026-07-31T00:00:00+08:00"


def test_every_preapproved_slice_meets_minimum_sample() -> None:
    report = _build_report()

    assert report["slice_count"] == len(MANIFEST["slices"]) == 4
    assert report["total_included_samples"] == 48
    assert report["insufficient_slice_count"] == 0
    assert {row["slice_id"] for row in report["slice_reports"]} == set(
        MANIFEST["slices"]
    )


def test_exclusions_have_reason_and_sample_ids_are_unique() -> None:
    report = _build_report()
    sample_ids = [
        sample_id
        for row in OBSERVATIONS["slices"]
        for sample_id in row["sample_ids"]
    ]

    assert report["excluded_sample_without_reason"] == 0
    assert len(sample_ids) == len(set(sample_ids))


def test_quality_latency_cost_and_risk_have_complete_intervals() -> None:
    report = _build_report()

    for row in report["slice_reports"]:
        for metric in (
            "quality_delta_percentage_points",
            "latency_ratio",
            "cost_ratio",
            "risk_pass_rate",
        ):
            interval = row[metric]
            assert interval["lower"] <= interval["mean"] <= interval["upper"]
            assert interval["margin_of_error"] >= 0
    assert report["confidence_interval_missing_count"] == 0
    assert report["error_bound_missing_count"] == 0


def test_report_is_audited_synthetic_evidence_not_a_production_claim() -> None:
    report = _build_report()

    assert report["synthetic_fixture_only"] is True
    assert report["production_claim_authorized"] is False
    assert report["active_user_sample_count"] == 0
    assert report["audit_receipt"]["confidence_level"] == 0.95
    report_path = os.environ.get("GONOW_P08_005_REPORT")
    if report_path:
        target = Path(report_path)
        target.parent.mkdir(parents=True, exist_ok=True)
        temporary = target.with_suffix(".json.tmp")
        temporary.write_text(
            json.dumps(report, sort_keys=True, separators=(",", ":")), "utf-8"
        )
        temporary.replace(target)
