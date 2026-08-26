from __future__ import annotations

from pathlib import Path
import site
import sys

import pytest


SERVICE_ROOT = Path(__file__).resolve().parents[3]
site.addsitedir(str(SERVICE_ROOT / ".venv" / "Lib" / "site-packages"))
sys.path.insert(0, str(SERVICE_ROOT))

from app.runtime.candidate import ValidatedItineraryOutput  # noqa: E402
from app.runtime.segment_plan import (  # noqa: E402
    SegmentMergeError,
    SegmentOutput,
    build_segment_plan,
    merge_segment_outputs,
)


def _output(start: int, end: int) -> ValidatedItineraryOutput:
    return ValidatedItineraryOutput.model_validate(
        {
            "title": "Segment",
            "days": [
                {
                    "day_number": day,
                    "items": [
                        {
                            "item_id": f"item_d{day}_1",
                            "title": f"Day {day}",
                            "start_minute": 600,
                            "duration_minutes": 60,
                            "claim_ids": [],
                        }
                    ],
                }
                for day in range(start, end + 1)
            ],
        }
    )


def test_31_day_segment_plan_is_bounded_contiguous_and_deterministic() -> None:
    plans = [
        build_segment_plan(
            requested_days=31,
            max_days_per_segment=7,
            max_segments=5,
        )
        for _ in range(3)
    ]
    assert len({item.digest for item in plans}) == 1
    assert [(item.start_day, item.end_day) for item in plans[0].segments] == [
        (1, 7),
        (8, 14),
        (15, 21),
        (22, 28),
        (29, 31),
    ]


def test_segment_merge_requires_every_day_once_and_segment_claim_authority() -> None:
    plan = build_segment_plan(
        requested_days=4,
        max_days_per_segment=2,
        max_segments=2,
    )
    outputs = tuple(
        SegmentOutput(
            segment_id=segment.segment_id,
            output=_output(segment.start_day, segment.end_day),
            included_claim_ids=(),
        )
        for segment in plan.segments
    )
    merged = merge_segment_outputs(plan, outputs, title="Merged")
    assert tuple(day.day_number for day in merged.days) == (1, 2, 3, 4)

    with pytest.raises(SegmentMergeError, match="segment.coverage_invalid"):
        merge_segment_outputs(plan, outputs[:-1], title="Missing")
    duplicate_day = SegmentOutput(
        segment_id=plan.segments[1].segment_id,
        output=_output(2, 3),
        included_claim_ids=(),
    )
    with pytest.raises(SegmentMergeError, match="segment.coverage_invalid"):
        merge_segment_outputs(plan, (outputs[0], duplicate_day), title="Duplicate")


def test_segment_plan_routes_excess_segment_count_to_clarification() -> None:
    with pytest.raises(SegmentMergeError, match="context.clarification_required"):
        build_segment_plan(
            requested_days=31,
            max_days_per_segment=3,
            max_segments=5,
        )
