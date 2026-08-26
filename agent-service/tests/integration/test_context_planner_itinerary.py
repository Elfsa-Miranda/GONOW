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
from app.worker.itinerary_processor import (  # noqa: E402
    GeminiItineraryProcessor,
    _prompt,
)
from tests.contract.test_gemini_itinerary_processor import _job  # noqa: E402
from tests.contract.test_single_agent_rag_processor import (  # noqa: E402
    SyntheticBoundedProvider,
)


def _response() -> httpx.Response:
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
                                                    {
                                                        "item_id": "item_day_1",
                                                        "title": "Museum visit",
                                                        "start_minute": 600,
                                                        "duration_minutes": 120,
                                                    }
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
