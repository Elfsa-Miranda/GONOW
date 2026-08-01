from __future__ import annotations

import json
from pathlib import Path
from typing import Any


REPOSITORY_ROOT = Path(__file__).resolve().parents[3]
EVIDENCE_ROOT = REPOSITORY_ROOT / "docs" / "execution" / "evidence" / "phase-10" / "P10-006"
ANNOTATIONS_PATH = EVIDENCE_ROOT / "judge-annotations.jsonl"
CALIBRATION_PATH = EVIDENCE_ROOT / "judge-calibration.json"


def load_annotations() -> list[dict[str, Any]]:
    return [
        json.loads(line)
        for line in ANNOTATIONS_PATH.read_text("utf-8").splitlines()
        if line.strip()
    ]


def load_calibration() -> dict[str, Any]:
    return json.loads(CALIBRATION_PATH.read_text("utf-8"))


def binary_metrics(rows: list[dict[str, Any]], prediction_field: str) -> dict[str, float | int]:
    sample_count = len(rows)
    observed = sum(row[prediction_field] == row["adjudicated_label"] for row in rows)
    truth_fail = sum(row["adjudicated_label"] == "fail" for row in rows)
    predicted_fail = sum(row[prediction_field] == "fail" for row in rows)
    true_positive = sum(
        row[prediction_field] == row["adjudicated_label"] == "fail" for row in rows
    )
    truth_pass = sample_count - truth_fail
    predicted_pass = sample_count - predicted_fail
    expected = (
        truth_fail * predicted_fail + truth_pass * predicted_pass
    ) / (sample_count * sample_count)
    agreement = observed / sample_count
    kappa = (agreement - expected) / (1 - expected)
    return {
        "sample_count": sample_count,
        "raw_agreement": agreement,
        "cohen_kappa": kappa,
        "recall": true_positive / truth_fail,
        "precision": true_positive / predicted_fail,
    }


def calibration_decision(
    metrics: dict[str, float | int],
    thresholds: dict[str, float | int | str],
    *,
    formal_approval_status: str,
) -> dict[str, bool | int]:
    thresholds_met = (
        metrics["raw_agreement"] >= thresholds["raw_agreement_gte"]
        and metrics["cohen_kappa"] >= thresholds["cohen_kappa_gte"]
        and metrics["recall"] >= thresholds["recall_gte"]
        and metrics["precision"] >= thresholds["precision_gte"]
    )
    return {
        "thresholds_met": thresholds_met,
        "advisory_only": not thresholds_met or formal_approval_status != "accepted",
        "rollout_decision_count": 0,
    }


def test_annotations_are_double_labeled_adjudicated_and_reasoning_free() -> None:
    rows = load_annotations()
    assert len(rows) == 100
    assert all(
        {"human_label_a", "human_label_b", "adjudicated_label", "judge_label"}
        <= row.keys()
        for row in rows
    )
    assert all(
        forbidden not in row
        for row in rows
        for forbidden in ("prompt", "response", "reasoning")
    )


def test_recomputed_global_metrics_match_frozen_calibration() -> None:
    actual = binary_metrics(load_annotations(), "judge_label")
    expected = load_calibration()["global"]
    assert actual["sample_count"] == expected["sample_count"]
    for metric in ("raw_agreement", "cohen_kappa", "recall", "precision"):
        assert abs(actual[metric] - expected[metric]) < 1e-12


def test_every_applicable_slice_meets_minimum_sample_and_metrics() -> None:
    rows = load_annotations()
    calibration = load_calibration()
    thresholds = calibration["thresholds"]
    for expected in calibration["slices"]:
        selected = [row for row in rows if row["slice"] == expected["slice"]]
        actual = binary_metrics(selected, "judge_label")
        assert actual["sample_count"] >= thresholds["min_slice_sample"]
        assert abs(actual["raw_agreement"] - expected["raw_agreement"]) < 1e-12
        assert actual["recall"] >= thresholds["recall_gte"]
        assert actual["precision"] >= thresholds["precision_gte"]


def test_below_threshold_is_advisory_only_with_no_rollout_decision() -> None:
    calibration = load_calibration()
    below = {
        "raw_agreement": 0.5,
        "cohen_kappa": 0.0,
        "recall": 0.4,
        "precision": 0.4,
    }
    decision = calibration_decision(
        below,
        calibration["thresholds"],
        formal_approval_status="pending_external",
    )
    assert decision == {
        "thresholds_met": False,
        "advisory_only": True,
        "rollout_decision_count": 0,
    }


def test_audit_receipts_are_present_and_unique() -> None:
    receipts = [row["audit_receipt_id"] for row in load_annotations()]
    assert len(receipts) == len(set(receipts)) == 100
    assert all(len(receipt) == 64 for receipt in receipts)


def test_judge_never_makes_a_rollout_decision() -> None:
    calibration = load_calibration()
    decision = calibration_decision(
        calibration["global"],
        calibration["thresholds"],
        formal_approval_status=calibration["formal_approval_status"],
    )
    assert decision["thresholds_met"] is True
    assert decision["advisory_only"] is True
    assert decision["rollout_decision_count"] == 0
