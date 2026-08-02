"""Typed itinerary Worker processor backed by the certified Gemini gateway."""

from __future__ import annotations

from collections.abc import Callable
import json
import time
from typing import Any

import httpx

from app.models.gateway import (
    AuthenticatedModelGateway,
    CircuitBreaker,
    CredentialProvider,
    ModelInvocation,
    RetryPolicy,
)
from app.models.gemini import (
    EnvironmentGeminiCredentialProvider,
    GeminiModelAdapter,
    canonical_digest,
    certified_gemini_routes,
)
from app.models.ledger import ModelUsageLedger
from app.runtime.candidate import (
    CandidateProjector,
    ItineraryCandidate,
    ValidatedItineraryOutput,
)
from app.worker.execution import ClaimedItineraryJob, WorkerExecutionError


ITINERARY_RESPONSE_SCHEMA: dict[str, Any] = {
    "type": "object",
    "properties": {
        "title": {"type": "string", "minLength": 1, "maxLength": 160},
        "days": {
            "type": "array",
            "minItems": 1,
            "maxItems": 31,
            "items": {
                "type": "object",
                "properties": {
                    "day_number": {"type": "integer", "minimum": 1, "maximum": 31},
                    "items": {
                        "type": "array",
                        "minItems": 1,
                        "maxItems": 30,
                        "items": {
                            "type": "object",
                            "properties": {
                                "item_id": {
                                    "type": "string",
                                    "pattern": "^item_[a-z0-9_-]{1,80}$",
                                },
                                "title": {
                                    "type": "string",
                                    "minLength": 1,
                                    "maxLength": 160,
                                },
                                "start_minute": {
                                    "type": "integer",
                                    "minimum": 0,
                                    "maximum": 1439,
                                },
                                "duration_minutes": {
                                    "type": "integer",
                                    "minimum": 1,
                                    "maximum": 1440,
                                },
                            },
                            "required": [
                                "item_id",
                                "title",
                                "start_minute",
                                "duration_minutes",
                            ],
                            "additionalProperties": False,
                        },
                    },
                },
                "required": ["day_number", "items"],
                "additionalProperties": False,
            },
        },
    },
    "required": ["title", "days"],
    "additionalProperties": False,
}


def _prompt(structured_input: dict[str, Any]) -> str:
    canonical_input = json.dumps(
        structured_input,
        allow_nan=False,
        ensure_ascii=False,
        separators=(",", ":"),
        sort_keys=True,
    )
    return (
        "Create a practical itinerary from the supplied JSON. Preserve every hard constraint. "
        "Return only the required JSON schema. Use local clock minutes from midnight. "
        "Every item_id must start with item_ and contain only lowercase letters, digits, underscore, or dash. "
        "Do not include citations, hidden reasoning, markdown, or extra fields. Input:"
        + canonical_input
    )


class GeminiItineraryProcessor:
    """Convert one fenced Job input into a strictly validated typed Candidate."""

    def __init__(
        self,
        *,
        credentials: CredentialProvider | None = None,
        client: httpx.Client | None = None,
        clock: Callable[[], float] = time.monotonic,
        ledger: ModelUsageLedger | None = None,
    ) -> None:
        self._credentials = credentials or EnvironmentGeminiCredentialProvider()
        self._client = client
        self._clock = clock
        self.ledger = ledger or ModelUsageLedger()

    @staticmethod
    def _required_capabilities(structured_input: dict[str, Any]) -> frozenset[str]:
        days = int(structured_input.get("days", 0))
        constraints = structured_input.get("hard_constraints", [])
        complex_request = days > 7 or (
            isinstance(constraints, (list, tuple)) and len(constraints) >= 4
        )
        return frozenset({"json", "complex"} if complex_request else {"json"})

    @staticmethod
    def _validate_business_shape(
        output: ValidatedItineraryOutput,
        structured_input: dict[str, Any],
    ) -> None:
        requested_days = int(structured_input.get("days", 0))
        if requested_days < 1 or len(output.days) != requested_days:
            raise WorkerExecutionError()
        if tuple(day.day_number for day in output.days) != tuple(
            range(1, requested_days + 1)
        ):
            raise WorkerExecutionError()
        for day in output.days:
            for item in day.items:
                if item.start_minute + item.duration_minutes > 1_440 or item.claim_ids:
                    raise WorkerExecutionError()

    def process(self, job: ClaimedItineraryJob) -> ItineraryCandidate:
        prompt = _prompt(job.structured_input)
        input_sha256 = canonical_digest(prompt)
        input_ref = f"context://sha256/{input_sha256}"
        adapter = GeminiModelAdapter(
            input_resolver=lambda reference: prompt
            if reference == input_ref
            else (_ for _ in ()).throw(KeyError(reference)),
            response_schema=ITINERARY_RESPONSE_SCHEMA,
            client=self._client,
        )
        gateway = AuthenticatedModelGateway(
            routes=certified_gemini_routes(),
            credentials=self._credentials,
            adapter=adapter,
            ledger=self.ledger,
            circuit_breaker=CircuitBreaker(
                failure_threshold=2,
                cooldown_seconds=30.0,
            ),
            retry_policy=RetryPolicy(max_total_attempts=2),
        )
        requested_days = int(job.structured_input.get("days", 0))
        invocation = ModelInvocation(
            request_id=f"job-{job.claim.job_id}",
            input_ref=input_ref,
            input_sha256=input_sha256,
            required_capabilities=self._required_capabilities(job.structured_input),
            max_output_tokens=min(8_192, max(1_024, requested_days * 512)),
        )
        outcome = gateway.invoke(invocation, now_monotonic=self._clock())
        if outcome.result.payload is None:
            raise WorkerExecutionError()
        try:
            output = ValidatedItineraryOutput.model_validate(outcome.result.payload)
        except (TypeError, ValueError) as error:
            raise WorkerExecutionError() from error
        self._validate_business_shape(output, job.structured_input)
        return CandidateProjector().project(
            run_id=str(job.claim.run_id),
            behavior_digest=job.behavior_digest,
            input_digest=job.input_digest,
            output=output,
            citations=(),
        )
