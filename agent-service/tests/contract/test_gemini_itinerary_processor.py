from __future__ import annotations

import json
from pathlib import Path
import site
import sys
from uuid import uuid4

import httpx
import pytest


SERVICE_ROOT = Path(__file__).resolve().parents[2]
site.addsitedir(str(SERVICE_ROOT / ".venv" / "Lib" / "site-packages"))
sys.path.insert(0, str(SERVICE_ROOT))

from app.models.gateway import ProviderCredential
from app.persistence.repositories.jobs import JobClaim
from app.worker.execution import ClaimedItineraryJob, WorkerExecutionError
from app.worker.itinerary_processor import GeminiItineraryProcessor


def _job(*, days: int = 2, constraints: tuple[str, ...] = ()) -> ClaimedItineraryJob:
    run_id = uuid4()
    return ClaimedItineraryJob(
        claim=JobClaim(
            job_id=uuid4(),
            run_id=run_id,
            tenant_id="tenant-gemini-contract",
            job_type="itinerary_planning",
            input_ref="job-input://sha256/" + "a" * 64,
            lease_id=uuid4(),
            holder_id="worker-gemini-contract",
            fencing_token=1,
            attempt_count=1,
            replayed=False,
        ),
        behavior_digest="b" * 64,
        input_digest="c" * 64,
        structured_input={
            "schema_version": "1.0",
            "origin": "Shanghai",
            "destination": "Hangzhou",
            "starts_on": "2026-08-03",
            "days": days,
            "budget_minor": 200_000,
            "currency": "CNY",
            "locale": "zh-CN",
            "timezone": "Asia/Shanghai",
            "hard_constraints": list(constraints),
        },
    )


def _output(days: int) -> dict[str, object]:
    return {
        "title": "Hangzhou itinerary",
        "days": [
            {
                "day_number": day,
                "items": [
                    {
                        "item_id": f"item_day_{day}",
                        "title": f"Day {day} activity",
                        "start_minute": 600,
                        "duration_minutes": 120,
                    }
                ],
            }
            for day in range(1, days + 1)
        ],
    }


def _response(request: httpx.Request, *, days: int) -> httpx.Response:
    request_body = json.loads(request.content)
    assert request.url.host == "generativelanguage.googleapis.com"
    assert request.headers["x-goog-api-key"] == "synthetic-gemini-credential"
    assert request_body["generationConfig"]["responseMimeType"] == "application/json"
    return httpx.Response(
        200,
        json={
            "candidates": [
                {
                    "finishReason": "STOP",
                    "content": {"parts": [{"text": json.dumps(_output(days))}]},
                }
            ],
            "usageMetadata": {
                "promptTokenCount": 120,
                "candidatesTokenCount": 80,
                "thoughtsTokenCount": 20,
                "totalTokenCount": 220,
            },
        },
    )


def test_processor_uses_economic_route_and_projects_typed_candidate(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setenv("GEMINI_API_KEY", "synthetic-gemini-credential")
    requested_models: list[str] = []

    def handler(request: httpx.Request) -> httpx.Response:
        requested_models.append(request.url.path.split("/")[-1].split(":")[0])
        return _response(request, days=2)

    with httpx.Client(transport=httpx.MockTransport(handler)) as client:
        processor = GeminiItineraryProcessor(client=client)
        job = _job(days=2)
        candidate = processor.process(job)
    assert requested_models == ["gemini-3.1-flash-lite"]
    assert candidate.run_id == str(job.claim.run_id)
    assert len(candidate.days) == 2
    assert candidate.citations == ()
    assert processor.ledger.records[0].output_tokens == 100


def test_retryable_economic_failure_moves_once_to_capability(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setenv("GEMINI_API_KEY", "synthetic-gemini-credential")
    requested_models: list[str] = []

    def handler(request: httpx.Request) -> httpx.Response:
        model = request.url.path.split("/")[-1].split(":")[0]
        requested_models.append(model)
        if model == "gemini-3.1-flash-lite":
            return httpx.Response(503, json={"error": {"status": "UNAVAILABLE"}})
        return _response(request, days=2)

    with httpx.Client(transport=httpx.MockTransport(handler)) as client:
        processor = GeminiItineraryProcessor(client=client)
        candidate = processor.process(_job(days=2))
    assert candidate.status == "candidate"
    assert requested_models == ["gemini-3.1-flash-lite", "gemini-3.6-flash"]
    assert [record.status for record in processor.ledger.records] == [
        "failed",
        "succeeded",
    ]


def test_complex_request_selects_capability_without_dynamic_model_choice(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setenv("GEMINI_API_KEY", "synthetic-gemini-credential")
    requested_models: list[str] = []

    def handler(request: httpx.Request) -> httpx.Response:
        requested_models.append(request.url.path.split("/")[-1].split(":")[0])
        return _response(request, days=8)

    with httpx.Client(transport=httpx.MockTransport(handler)) as client:
        candidate = GeminiItineraryProcessor(client=client).process(_job(days=8))
    assert len(candidate.days) == 8
    assert requested_models == ["gemini-3.6-flash"]


def test_invalid_model_output_fails_before_candidate_projection(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setenv("GEMINI_API_KEY", "synthetic-gemini-credential")

    def handler(_: httpx.Request) -> httpx.Response:
        return httpx.Response(
            200,
            json={
                "candidates": [
                    {
                        "finishReason": "STOP",
                        "content": {"parts": [{"text": '{"title":"incomplete"}'}]},
                    }
                ],
                "usageMetadata": {
                    "promptTokenCount": 10,
                    "candidatesTokenCount": 5,
                    "totalTokenCount": 15,
                },
            },
        )

    with httpx.Client(transport=httpx.MockTransport(handler)) as client:
        with pytest.raises(WorkerExecutionError):
            GeminiItineraryProcessor(client=client).process(_job(days=2))


def test_provider_credential_repr_never_contains_secret() -> None:
    credential = ProviderCredential(
        "google-gemini-developer-api",
        "secret://environment/GEMINI_API_KEY",
        "synthetic-gemini-credential",
    )
    assert "synthetic-gemini-credential" not in repr(credential)
