from __future__ import annotations

import json
from pathlib import Path

import pytest

from .process_harness import (
    APPROVED_INJECTION_POINTS,
    run_failure_injection_matrix,
    run_injection_point,
)


def test_each_approved_injection_point_is_killed_restarted_and_collected(
    tmp_path: Path,
) -> None:
    output = tmp_path / "failure-injection-report.json"
    report = run_failure_injection_matrix(output_path=output, timeout_seconds=5)
    assert report["approved_injection_point_count"] == 7
    assert report["structured_result_count"] == len(APPROVED_INJECTION_POINTS)
    assert report["kill_confirmed"] is True
    assert report["orphan_process_count"] == 0
    assert report["dirty_fixture_count"] == 0
    assert report["production_write_count"] == 0
    assert all(result["passed"] for result in report["results"])
    assert {result["injection_point"] for result in report["results"]} == set(
        APPROVED_INJECTION_POINTS
    )
    assert json.loads(output.read_text(encoding="utf-8")) == report


def test_unapproved_injection_point_is_rejected_before_spawn(tmp_path: Path) -> None:
    with pytest.raises(ValueError, match="unapproved injection point"):
        run_injection_point("arbitrary_boundary", fixture_parent=tmp_path)
    assert tuple(tmp_path.iterdir()) == ()


@pytest.mark.parametrize("timeout_seconds", (0, 31))
def test_unbounded_timeout_is_rejected(
    tmp_path: Path, timeout_seconds: float
) -> None:
    with pytest.raises(ValueError, match="timeout_seconds"):
        run_injection_point(
            APPROVED_INJECTION_POINTS[0],
            fixture_parent=tmp_path,
            timeout_seconds=timeout_seconds,
        )
