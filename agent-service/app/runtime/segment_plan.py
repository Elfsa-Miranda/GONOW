"""Bounded contiguous-day segmentation and deterministic global merge."""

from __future__ import annotations

import hashlib
import json
import re
from dataclasses import dataclass

from app.runtime.candidate import ValidatedItineraryOutput


class SegmentMergeError(ValueError):
    def __init__(self, code: str) -> None:
        self.code = code
        super().__init__(code)


@dataclass(frozen=True, slots=True)
class DaySegment:
    segment_id: str
    start_day: int
    end_day: int

    @property
    def day_count(self) -> int:
        return self.end_day - self.start_day + 1


@dataclass(frozen=True, slots=True)
class SegmentPlan:
    requested_days: int
    max_days_per_segment: int
    max_segments: int
    segments: tuple[DaySegment, ...]
    digest: str


@dataclass(frozen=True, slots=True)
class SegmentOutput:
    segment_id: str
    output: ValidatedItineraryOutput
    included_claim_ids: tuple[str, ...]


def build_segment_plan(
    *,
    requested_days: int,
    max_days_per_segment: int,
    max_segments: int,
) -> SegmentPlan:
    if (
        isinstance(requested_days, bool)
        or not 1 <= requested_days <= 31
        or isinstance(max_days_per_segment, bool)
        or max_days_per_segment < 1
        or isinstance(max_segments, bool)
        or max_segments < 1
    ):
        raise SegmentMergeError("segment.policy_invalid")
    raw_ranges = tuple(
        (start, min(requested_days, start + max_days_per_segment - 1))
        for start in range(1, requested_days + 1, max_days_per_segment)
    )
    if len(raw_ranges) > max_segments:
        raise SegmentMergeError("context.clarification_required")
    segments = tuple(
        DaySegment(
            segment_id=f"segment_d{start:02d}_d{end:02d}",
            start_day=start,
            end_day=end,
        )
        for start, end in raw_ranges
    )
    canonical = json.dumps(
        {
            "max_days_per_segment": max_days_per_segment,
            "max_segments": max_segments,
            "requested_days": requested_days,
            "segments": [
                [item.segment_id, item.start_day, item.end_day] for item in segments
            ],
        },
        separators=(",", ":"),
        sort_keys=True,
    ).encode("utf-8")
    return SegmentPlan(
        requested_days=requested_days,
        max_days_per_segment=max_days_per_segment,
        max_segments=max_segments,
        segments=segments,
        digest=hashlib.sha256(canonical).hexdigest(),
    )


def merge_segment_outputs(
    plan: SegmentPlan,
    outputs: tuple[SegmentOutput, ...],
    *,
    title: str,
) -> ValidatedItineraryOutput:
    expected = {item.segment_id: item for item in plan.segments}
    if len(outputs) != len(plan.segments) or {item.segment_id for item in outputs} != set(
        expected
    ):
        raise SegmentMergeError("segment.coverage_invalid")
    days: list[dict[str, object]] = []
    item_ids: set[str] = set()
    covered_days: list[int] = []
    for segment_output in sorted(
        outputs,
        key=lambda item: expected[item.segment_id].start_day,
    ):
        segment = expected[segment_output.segment_id]
        actual_days = tuple(day.day_number for day in segment_output.output.days)
        required_days = tuple(range(segment.start_day, segment.end_day + 1))
        if actual_days != required_days:
            raise SegmentMergeError("segment.coverage_invalid")
        authority = set(segment_output.included_claim_ids)
        for day in segment_output.output.days:
            projected_items: list[dict[str, object]] = []
            for ordinal, item in enumerate(day.items, start=1):
                expected_item_id = f"item_d{day.day_number}_{ordinal}"
                if (
                    item.item_id != expected_item_id
                    or item.item_id in item_ids
                    or not set(item.claim_ids).issubset(authority)
                    or re.fullmatch(r"item_d[0-9]{1,2}_[0-9]{1,2}", item.item_id)
                    is None
                ):
                    raise SegmentMergeError("segment.output_invalid")
                item_ids.add(item.item_id)
                projected_items.append(item.model_dump(mode="json"))
            covered_days.append(day.day_number)
            days.append(
                {
                    "day_number": day.day_number,
                    "items": projected_items,
                }
            )
    if covered_days != list(range(1, plan.requested_days + 1)):
        raise SegmentMergeError("segment.coverage_invalid")
    try:
        return ValidatedItineraryOutput.model_validate({"title": title, "days": days})
    except (TypeError, ValueError) as error:
        raise SegmentMergeError("segment.output_invalid") from error
