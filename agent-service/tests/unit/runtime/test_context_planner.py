from __future__ import annotations

import hashlib
from pathlib import Path
import site
import sys


SERVICE_ROOT = Path(__file__).resolve().parents[3]
site.addsitedir(str(SERVICE_ROOT / ".venv" / "Lib" / "site-packages"))
sys.path.insert(0, str(SERVICE_ROOT))

from app.runtime.context_planner import (  # noqa: E402
    ContextArtifact,
    ContextArtifactKind,
    ContextBudgetEnvelope,
    ContextDecisionStatus,
    ContextPlanRequest,
    ContextPlanner,
    ContextPlannerPolicy,
    DEFAULT_CONTEXT_POLICY,
    DEFAULT_STAGE_CONTEXT_POLICIES,
    StageContextPolicy,
    deterministic_token_count,
)
from app.runtime.state import WorkflowStage  # noqa: E402


def _artifact(
    artifact_id: str,
    kind: ContextArtifactKind,
    content: str,
    *,
    required: bool,
    priority: int,
    claim_ids: tuple[str, ...] = (),
) -> ContextArtifact:
    return ContextArtifact(
        artifact_id=artifact_id,
        kind=kind,
        content=content,
        sha256=hashlib.sha256(content.encode("utf-8")).hexdigest(),
        priority=priority,
        required=required,
        provenance_ref=f"fixture://sha256/{hashlib.sha256(artifact_id.encode()).hexdigest()}",
        claim_ids=claim_ids,
    )


def _policy() -> ContextPlannerPolicy:
    return ContextPlannerPolicy(
        policy_id="itinerary-compose-v2-test",
        tokenizer_id="utf8-ceil-div4-v1",
        supported_stages=(WorkflowStage.COMPOSE,),
        required_kinds=(ContextArtifactKind.TASK_CONTRACT,),
    )


def _request(
    planner: ContextPlanner,
    artifacts: tuple[ContextArtifact, ...],
    *,
    policy_digest: str | None = None,
) -> ContextPlanRequest:
    return ContextPlanRequest(
        stage=WorkflowStage.COMPOSE,
        policy_digest=policy_digest or planner.policy_digest,
        artifacts=artifacts,
        budget=ContextBudgetEnvelope(
            model_context_tokens=800,
            reserved_instruction_tokens=100,
            reserved_schema_tokens=100,
            reserved_output_tokens=100,
            reserved_safety_tokens=100,
        ),
    )


def test_planner_is_deterministic_and_includes_only_compiled_claims() -> None:
    planner = ContextPlanner(_policy(), token_counter=deterministic_token_count)
    task = _artifact(
        "task",
        ContextArtifactKind.TASK_CONTRACT,
        '{"days":3,"hard_constraints":["no_overlap"]}',
        required=True,
        priority=100,
    )
    evidence_a = _artifact(
        "evidence-a",
        ContextArtifactKind.EVIDENCE,
        "a" * 600,
        required=False,
        priority=80,
        claim_ids=("knowledge_aaaaaaaaaaaaaaaa",),
    )
    evidence_b = _artifact(
        "evidence-b",
        ContextArtifactKind.EVIDENCE,
        "b" * 600,
        required=False,
        priority=70,
        claim_ids=("knowledge_bbbbbbbbbbbbbbbb",),
    )
    decisions = (
        planner.plan(_request(planner, (task, evidence_a, evidence_b))),
        planner.plan(_request(planner, (evidence_b, task, evidence_a))),
        planner.plan(_request(planner, (evidence_a, evidence_b, task))),
    )
    first, second, third = decisions
    assert first.status is ContextDecisionStatus.COMPILED
    assert len({item.digest for item in decisions}) == 1
    assert first.working_context == second.working_context == third.working_context
    assert first.included_artifact_ids == ("task", "evidence-a")
    assert first.omitted_artifact_ids == ("evidence-b",)
    assert first.included_claim_ids == ("knowledge_aaaaaaaaaaaaaaaa",)
    assert "knowledge_bbbbbbbbbbbbbbbb" not in first.working_context


def test_planner_fails_closed_when_behavior_policy_does_not_match() -> None:
    planner = ContextPlanner(_policy(), token_counter=deterministic_token_count)
    task = _artifact(
        "task",
        ContextArtifactKind.TASK_CONTRACT,
        "{}",
        required=True,
        priority=100,
    )
    decision = planner.plan(_request(planner, (task,), policy_digest="f" * 64))
    assert decision.status is ContextDecisionStatus.BLOCKED
    assert decision.reason_code == "context.policy_mismatch"
    assert decision.working_context is None


def test_planner_returns_typed_blocked_decision_for_required_overflow() -> None:
    planner = ContextPlanner(_policy(), token_counter=deterministic_token_count)
    task = _artifact(
        "task",
        ContextArtifactKind.TASK_CONTRACT,
        "required" * 700,
        required=True,
        priority=100,
    )
    decision = planner.plan(_request(planner, (task,)))
    assert decision.status is ContextDecisionStatus.BLOCKED
    assert decision.reason_code == "context.required_slice_missing"
    assert decision.included_claim_ids == ()


def test_budget_envelope_rejects_reservations_that_consume_the_window() -> None:
    try:
        ContextBudgetEnvelope(
            model_context_tokens=400,
            reserved_instruction_tokens=100,
            reserved_schema_tokens=100,
            reserved_output_tokens=100,
            reserved_safety_tokens=100,
        )
    except ValueError as error:
        assert str(error) == "context.budget_invalid"
    else:
        raise AssertionError("zero working-context budget must be rejected")


def test_planner_rejects_duplicate_artifact_identity() -> None:
    planner = ContextPlanner(_policy())
    task = _artifact(
        "task",
        ContextArtifactKind.TASK_CONTRACT,
        "{}",
        required=True,
        priority=100,
    )
    decision = planner.plan(_request(planner, (task, task)))
    assert decision.status is ContextDecisionStatus.BLOCKED
    assert decision.reason_code == "context.input_invalid"


def test_planner_maps_invalid_tokenizer_count_to_stable_failure() -> None:
    planner = ContextPlanner(_policy(), token_counter=lambda _: 0)
    task = _artifact(
        "task",
        ContextArtifactKind.TASK_CONTRACT,
        "{}",
        required=True,
        priority=100,
    )
    decision = planner.plan(_request(planner, (task,)))
    assert decision.status is ContextDecisionStatus.BLOCKED
    assert decision.reason_code == "context.tokenizer_unavailable"
    assert decision.working_context is None


def test_default_stage_context_policies_require_stage_artifacts() -> None:
    assert tuple(item.stage for item in DEFAULT_STAGE_CONTEXT_POLICIES) == (
        WorkflowStage.INTAKE,
        WorkflowStage.PLAN,
        WorkflowStage.EVIDENCE,
        WorkflowStage.COMPOSE,
        WorkflowStage.VALIDATE,
        WorkflowStage.COMPLETE,
    )
    planner = ContextPlanner()
    task = _artifact(
        "task",
        ContextArtifactKind.TASK_CONTRACT,
        "{}",
        required=True,
        priority=100,
    )
    intent = _artifact(
        "plan-intent",
        ContextArtifactKind.PLAN_INTENT,
        '{"evidence_mode":"disabled"}',
        required=True,
        priority=90,
    )
    plan_decision = planner.plan(
        ContextPlanRequest(
            stage=WorkflowStage.PLAN,
            policy_digest=planner.policy_digest,
            artifacts=(task,),
            budget=_request(planner, (task,)).budget,
        )
    )
    evidence_decision = planner.plan(
        ContextPlanRequest(
            stage=WorkflowStage.EVIDENCE,
            policy_digest=planner.policy_digest,
            artifacts=(task, intent),
            budget=_request(planner, (task,)).budget,
        )
    )
    complete_decision = planner.plan(
        ContextPlanRequest(
            stage=WorkflowStage.COMPLETE,
            policy_digest=planner.policy_digest,
            artifacts=(task,),
            budget=_request(planner, (task,)).budget,
        )
    )

    assert plan_decision.status is ContextDecisionStatus.COMPILED
    assert evidence_decision.status is ContextDecisionStatus.COMPILED
    assert complete_decision.reason_code == "context.input_invalid"


def test_stage_context_policy_budget_is_bound_to_behavior_policy_digest() -> None:
    changed_stages = tuple(
        StageContextPolicy(
            stage=item.stage,
            required_kinds=item.required_kinds,
            optional_kinds=item.optional_kinds,
            max_working_context_tokens=(
                item.max_working_context_tokens + 1
                if item.stage is WorkflowStage.PLAN
                else item.max_working_context_tokens
            ),
        )
        for item in DEFAULT_STAGE_CONTEXT_POLICIES
    )
    changed = ContextPlannerPolicy(
        policy_id=DEFAULT_CONTEXT_POLICY.policy_id,
        tokenizer_id=DEFAULT_CONTEXT_POLICY.tokenizer_id,
        supported_stages=DEFAULT_CONTEXT_POLICY.supported_stages,
        required_kinds=DEFAULT_CONTEXT_POLICY.required_kinds,
        stage_policies=changed_stages,
    )

    assert ContextPlanner().policy_digest == ContextPlanner().policy_digest
    assert changed.digest != ContextPlanner().policy_digest
