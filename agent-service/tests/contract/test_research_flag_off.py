from __future__ import annotations

import json
import os
from pathlib import Path

import pytest
from pydantic import ValidationError

from app.runtime.research.flags import ResearchExperimentFlags
from app.runtime.research.router import (
    ResearchAudience,
    ResearchExperimentRouter,
    ResearchRoute,
)


PHASE_7_GOLDEN = b'{"candidate":"phase-7","events":[1,2,4],"status":"complete"}'


def test_feature_flag_defaults_to_false_and_off() -> None:
    flags = ResearchExperimentFlags()

    assert flags.enabled is False
    assert flags.mode.value == "off"
    assert flags.active_cohort_allowed is False
    assert flags.experiment_available is False


def test_flag_off_output_is_phase_7_byte_semantic_equivalent() -> None:
    branch_calls = 0

    def research_branch() -> bytes:
        nonlocal branch_calls
        branch_calls += 1
        return b"research-output"

    result = ResearchExperimentRouter().route(
        flags=ResearchExperimentFlags(),
        audience=ResearchAudience.ACTIVE_USER,
        phase_7_single_graph=lambda: PHASE_7_GOLDEN,
        research_branch=research_branch,
    )

    assert result.output == PHASE_7_GOLDEN
    assert result.audit.route is ResearchRoute.PHASE_7_SINGLE_GRAPH
    assert result.audit.reason_code == "research.flag_off"
    assert result.audit.branch_runtime_call_count == 0
    assert branch_calls == 0
    report_path = os.environ.get("GONOW_P08_004_REPORT")
    if report_path:
        report = {
            "schema_version": "1.0",
            "task_id": "TASK-P08-004",
            "feature_flag_default": False,
            "phase_7_golden_size": len(PHASE_7_GOLDEN),
            "flag_off_output_diff_count": int(result.output != PHASE_7_GOLDEN),
            "branch_runtime_call_count": branch_calls,
            "active_research_output_count": 0,
            "production_write_count": 0,
        }
        target = Path(report_path)
        target.parent.mkdir(parents=True, exist_ok=True)
        temporary = target.with_suffix(".json.tmp")
        temporary.write_text(
            json.dumps(report, sort_keys=True, separators=(",", ":")), "utf-8"
        )
        temporary.replace(target)


def test_active_user_cannot_enter_enabled_shadow_experiment() -> None:
    branch_calls = 0

    def research_branch() -> bytes:
        nonlocal branch_calls
        branch_calls += 1
        return b"research-output"

    result = ResearchExperimentRouter().route(
        flags=ResearchExperimentFlags(enabled=True, mode="shadow"),
        audience=ResearchAudience.ACTIVE_USER,
        phase_7_single_graph=lambda: PHASE_7_GOLDEN,
        research_branch=research_branch,
    )

    assert result.output == PHASE_7_GOLDEN
    assert result.audit.reason_code == "research.active_user_forbidden"
    assert branch_calls == 0


def test_matching_offline_experiment_is_isolated_from_active_output() -> None:
    result = ResearchExperimentRouter().route(
        flags=ResearchExperimentFlags(enabled=True, mode="offline"),
        audience=ResearchAudience.OFFLINE,
        phase_7_single_graph=lambda: PHASE_7_GOLDEN,
        research_branch=lambda: b"offline-research-evidence",
    )

    assert result.output == b"offline-research-evidence"
    assert result.audit.route is ResearchRoute.RESEARCH_BRANCH
    assert result.audit.branch_runtime_call_count == 1
    assert result.audit.active_output_count == 0


def test_kill_switch_returns_enabled_experiment_to_single_graph() -> None:
    result = ResearchExperimentRouter().route(
        flags=ResearchExperimentFlags(enabled=True, mode="replay", kill_switch=True),
        audience=ResearchAudience.REPLAY,
        phase_7_single_graph=lambda: PHASE_7_GOLDEN,
        research_branch=lambda: b"must-not-run",
    )

    assert result.output == PHASE_7_GOLDEN
    assert result.audit.reason_code == "research.kill_switch"
    assert result.audit.branch_runtime_call_count == 0


@pytest.mark.parametrize(
    "payload",
    [
        {"enabled": True, "mode": "off"},
        {"enabled": False, "mode": "shadow"},
        {"active_cohort_allowed": True},
    ],
)
def test_invalid_or_active_cohort_flags_fail_closed(payload: dict[str, object]) -> None:
    with pytest.raises(ValidationError):
        ResearchExperimentFlags.model_validate(payload)
