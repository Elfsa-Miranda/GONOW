from __future__ import annotations

import json
from pathlib import Path
import site
import sys

import httpx
import pytest


SERVICE_ROOT = Path(__file__).resolve().parents[2]
site.addsitedir(str(SERVICE_ROOT / ".venv" / "Lib" / "site-packages"))
sys.path.insert(0, str(SERVICE_ROOT))

from app.runtime.context_planner import ContextPlanner  # noqa: E402
from app.runtime.state import WorkflowStage  # noqa: E402
from app.worker.execution import WorkerExecutionError  # noqa: E402
from app.worker.itinerary_processor import (  # noqa: E402
    GeminiItineraryProcessor,
    ItineraryStageRuntimePolicy,
    StageObservation,
    _prompt,
)
from tests.contract.test_gemini_itinerary_processor import _job  # noqa: E402
from tests.contract.test_single_agent_rag_processor import (  # noqa: E402
    SyntheticAuthorizedProvider,
    SyntheticBoundedProvider,
)


class EmptyAuthorizedProvider:
    def __init__(self) -> None:
        self.calls = 0

    def retrieve(self, *, tenant_id: str, structured_input):
        del tenant_id, structured_input
        self.calls += 1
        return ()


def _response(*, claim_id: str | None = None) -> httpx.Response:
    item = {
        "item_id": "item_day_1",
        "title": "Museum visit",
        "start_minute": 600,
        "duration_minutes": 120,
    }
    if claim_id is not None:
        item["claim_ids"] = [claim_id]
    return httpx.Response(
        200,
        json={
            "candidates": [
                {
                    "finishReason": "STOP",
                    "content": {
                        "parts": [
                            {
                                "text": json.dumps(
                                    {
                                        "title": "Stable itinerary",
                                        "days": [
                                            {
                                                "day_number": 1,
                                                "items": [
                                                    item
                                                ],
                                            }
                                        ],
                                    }
                                )
                            }
                        ]
                    },
                }
            ],
            "usageMetadata": {
                "promptTokenCount": 50,
                "candidatesTokenCount": 30,
                "totalTokenCount": 80,
            },
        },
    )


def test_context_planner_itinerary_enabled_and_feature_off_paths(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setenv("GEMINI_API_KEY", "synthetic-gemini-credential")
    prompts: list[str] = []

    def handler(request: httpx.Request) -> httpx.Response:
        body = json.loads(request.content)
        prompts.append(body["contents"][0]["parts"][0]["text"])
        return _response()

    planner = ContextPlanner()
    job = _job(days=1, context_policy_digest=planner.policy_digest)
    provider = SyntheticBoundedProvider()
    evidence = provider.retrieve(
        tenant_id=job.claim.tenant_id,
        structured_input=job.structured_input,
    )
    with httpx.Client(transport=httpx.MockTransport(handler)) as client:
        disabled_processor = GeminiItineraryProcessor(
            client=client,
            rag_enabled=True,
            knowledge_provider=provider,
        )
        disabled = disabled_processor.process(job)
        enabled_processor = GeminiItineraryProcessor(
            client=client,
            rag_enabled=True,
            knowledge_provider=provider,
            context_planner=planner,
            context_window_tokens=1_900,
            context_safety_tokens=0,
        )
        enabled = enabled_processor.process(job)

    assert prompts[0] == _prompt(job.structured_input, evidence)
    assert disabled_processor.metrics.snapshot() == {}
    assert "OMITTED_CANARY_" in prompts[0]
    assert "OMITTED_CANARY_" not in prompts[1]
    assert "knowledge_1111111111111111" in prompts[1]
    assert "knowledge_2222222222222222" in prompts[1]
    assert "knowledge_ffffffffffffffff" not in prompts[1]
    assert "unique_item_ids" in prompts[1]
    assert "day_end_within_1440" in prompts[1]
    assert disabled == enabled
    serialized_metrics = json.dumps(
        {
            name: [point.model_dump(mode="json") for point in points]
            for name, points in enabled_processor.metrics.snapshot().items()
        },
        sort_keys=True,
    )
    assert "OMITTED_CANARY_" not in serialized_metrics
    assert "knowledge_" not in serialized_metrics
    assert set(enabled_processor.metrics.snapshot()) == {
        "gonow_context_decisions_total",
        "gonow_context_tokens",
        "gonow_context_utilization",
    }


def test_itinerary_stage_runtime_executes_six_stages_with_one_model_call(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setenv("GEMINI_API_KEY", "synthetic-gemini-credential")
    planner = ContextPlanner()
    observations: list[StageObservation] = []
    model_calls = 0

    def handler(_: httpx.Request) -> httpx.Response:
        nonlocal model_calls
        model_calls += 1
        return _response()

    with httpx.Client(transport=httpx.MockTransport(handler)) as client:
        processor = GeminiItineraryProcessor(
            client=client,
            rag_enabled=True,
            knowledge_provider=SyntheticBoundedProvider(),
            context_planner=planner,
            stage_runtime_policy=ItineraryStageRuntimePolicy(),
            stage_observer=observations.append,
        )
        candidate = processor.process(
            _job(days=1, context_policy_digest=planner.policy_digest)
        )

    assert [item.stage for item in observations] == [
        WorkflowStage.INTAKE,
        WorkflowStage.PLAN,
        WorkflowStage.EVIDENCE,
        WorkflowStage.COMPOSE,
        WorkflowStage.VALIDATE,
        WorkflowStage.COMPLETE,
    ]
    assert model_calls == 1
    assert len(processor.ledger.records) == 1
    assert observations[-1].model_call_count == 1
    assert observations[-1].tool_call_count == 0
    assert observations[-1].remaining_tokens == 32_688
    assert candidate.status == "candidate"
    stage_points = processor.metrics.snapshot()["gonow_stage_transitions_total"]
    assert [item.labels["stage"] for item in stage_points] == [
        "intake",
        "plan",
        "evidence",
        "compose",
        "validate",
        "complete",
    ]
    assert len(processor.metrics.snapshot()["gonow_context_decisions_total"]) == 6


def test_itinerary_stage_runtime_preserves_candidate_with_empty_evidence(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setenv("GEMINI_API_KEY", "synthetic-gemini-credential")
    planner = ContextPlanner()
    job = _job(days=1, context_policy_digest=planner.policy_digest)
    provider = EmptyAuthorizedProvider()
    model_calls = 0

    def handler(_: httpx.Request) -> httpx.Response:
        nonlocal model_calls
        model_calls += 1
        return _response()

    with httpx.Client(transport=httpx.MockTransport(handler)) as client:
        baseline = GeminiItineraryProcessor(
            client=client,
            rag_enabled=True,
            knowledge_provider=provider,
            context_planner=planner,
        ).process(job)
        staged_processor = GeminiItineraryProcessor(
            client=client,
            rag_enabled=True,
            knowledge_provider=provider,
            context_planner=planner,
            stage_runtime_policy=ItineraryStageRuntimePolicy(),
        )
        staged = staged_processor.process(job)

    assert baseline == staged
    assert provider.calls == 2
    assert model_calls == 2
    assert len(staged_processor.ledger.records) == 1


def test_itinerary_stage_runtime_rejects_unknown_constraint_before_side_effect(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setenv("GEMINI_API_KEY", "synthetic-gemini-credential")
    model_calls = 0
    observations: list[StageObservation] = []

    def handler(_: httpx.Request) -> httpx.Response:
        nonlocal model_calls
        model_calls += 1
        return _response()

    planner = ContextPlanner()
    with httpx.Client(transport=httpx.MockTransport(handler)) as client:
        with pytest.raises(WorkerExecutionError) as raised:
            GeminiItineraryProcessor(
                client=client,
                context_planner=planner,
                stage_runtime_policy=ItineraryStageRuntimePolicy(),
                stage_observer=observations.append,
            ).process(
                _job(
                    days=1,
                    constraints=("unknown_constraint",),
                    context_policy_digest=planner.policy_digest,
                )
            )

    assert raised.value.code == "task_contract.constraint_unknown"
    assert model_calls == 0
    assert [item.stage for item in observations] == [WorkflowStage.INTAKE]


def test_itinerary_stage_runtime_exhausts_token_budget_before_model_call(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setenv("GEMINI_API_KEY", "synthetic-gemini-credential")
    model_calls = 0
    observations: list[StageObservation] = []

    def handler(_: httpx.Request) -> httpx.Response:
        nonlocal model_calls
        model_calls += 1
        return _response()

    planner = ContextPlanner()
    with httpx.Client(transport=httpx.MockTransport(handler)) as client:
        with pytest.raises(WorkerExecutionError) as raised:
            GeminiItineraryProcessor(
                client=client,
                context_planner=planner,
                stage_runtime_policy=ItineraryStageRuntimePolicy(
                    max_total_tokens=1_000,
                ),
                stage_observer=observations.append,
            ).process(_job(days=1, context_policy_digest=planner.policy_digest))

    assert raised.value.code == "budget.global_exhausted"
    assert model_calls == 0
    assert [item.stage for item in observations] == [
        WorkflowStage.INTAKE,
        WorkflowStage.PLAN,
        WorkflowStage.EVIDENCE,
        WorkflowStage.COMPOSE,
    ]


def test_itinerary_stage_runtime_provider_failure_stops_in_evidence(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setenv("GEMINI_API_KEY", "synthetic-gemini-credential")
    observations: list[StageObservation] = []
    planner = ContextPlanner()
    with pytest.raises(WorkerExecutionError) as raised:
        GeminiItineraryProcessor(
            rag_enabled=True,
            knowledge_provider=SyntheticAuthorizedProvider(fail=True),
            context_planner=planner,
            stage_runtime_policy=ItineraryStageRuntimePolicy(),
            stage_observer=observations.append,
        ).process(_job(days=1, context_policy_digest=planner.policy_digest))

    assert raised.value.code == "knowledge.unavailable"
    assert [item.stage for item in observations] == [
        WorkflowStage.INTAKE,
        WorkflowStage.PLAN,
        WorkflowStage.EVIDENCE,
    ]


def test_itinerary_stage_runtime_model_failure_stops_in_compose(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setenv("GEMINI_API_KEY", "synthetic-gemini-credential")
    observations: list[StageObservation] = []
    planner = ContextPlanner()
    with httpx.Client(
        transport=httpx.MockTransport(
            lambda _: httpx.Response(
                400,
                json={"error": {"status": "INVALID_ARGUMENT"}},
            )
        )
    ) as client:
        with pytest.raises(WorkerExecutionError) as raised:
            GeminiItineraryProcessor(
                client=client,
                context_planner=planner,
                stage_runtime_policy=ItineraryStageRuntimePolicy(),
                stage_observer=observations.append,
            ).process(_job(days=1, context_policy_digest=planner.policy_digest))

    assert raised.value.code == "retry.exhausted"
    assert observations[-1].stage is WorkflowStage.COMPOSE


def test_itinerary_stage_runtime_validation_failure_stops_before_complete(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setenv("GEMINI_API_KEY", "synthetic-gemini-credential")
    observations: list[StageObservation] = []
    planner = ContextPlanner()
    with httpx.Client(
        transport=httpx.MockTransport(
            lambda _: _response(claim_id="knowledge_ffffffffffffffff")
        )
    ) as client:
        with pytest.raises(WorkerExecutionError) as raised:
            GeminiItineraryProcessor(
                client=client,
                context_planner=planner,
                stage_runtime_policy=ItineraryStageRuntimePolicy(),
                stage_observer=observations.append,
            ).process(_job(days=1, context_policy_digest=planner.policy_digest))

    assert raised.value.code == "validation.business_rules"
    assert observations[-1].stage is WorkflowStage.VALIDATE
    assert WorkflowStage.COMPLETE not in {item.stage for item in observations}


def test_itinerary_stage_runtime_deadline_stops_before_plan(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setenv("GEMINI_API_KEY", "synthetic-gemini-credential")
    observations: list[StageObservation] = []
    clock_values = iter((0.0, 61.0))
    planner = ContextPlanner()
    with pytest.raises(WorkerExecutionError) as raised:
        GeminiItineraryProcessor(
            context_planner=planner,
            stage_runtime_policy=ItineraryStageRuntimePolicy(),
            stage_observer=observations.append,
            clock=lambda: next(clock_values),
        ).process(_job(days=1, context_policy_digest=planner.policy_digest))

    assert raised.value.code == "budget.global_exhausted"
    assert [item.stage for item in observations] == [WorkflowStage.INTAKE]
