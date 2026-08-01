"""Content-free model usage ledger records for observability and cost accounting."""

from __future__ import annotations

from dataclasses import dataclass


@dataclass(frozen=True, slots=True)
class TokenUsage:
    input_tokens: int
    output_tokens: int

    def __post_init__(self) -> None:
        if self.input_tokens < 0 or self.output_tokens < 0:
            raise ValueError("model.usage_invalid")

    @property
    def total_tokens(self) -> int:
        return self.input_tokens + self.output_tokens


@dataclass(frozen=True, slots=True)
class ModelUsageRecord:
    request_id: str
    route_id: str
    attempt: int
    status: str
    input_tokens: int
    output_tokens: int
    failure_code: str | None


class ModelUsageLedger:
    """Append-only in-process ledger; never accepts prompt, output, or reasoning bodies."""

    def __init__(self) -> None:
        self._records: list[ModelUsageRecord] = []

    @property
    def records(self) -> tuple[ModelUsageRecord, ...]:
        return tuple(self._records)

    def record_success(
        self,
        *,
        request_id: str,
        route_id: str,
        attempt: int,
        usage: TokenUsage,
    ) -> None:
        self._records.append(
            ModelUsageRecord(
                request_id=request_id,
                route_id=route_id,
                attempt=attempt,
                status="succeeded",
                input_tokens=usage.input_tokens,
                output_tokens=usage.output_tokens,
                failure_code=None,
            )
        )

    def record_failure(
        self,
        *,
        request_id: str,
        route_id: str,
        attempt: int,
        failure_code: str,
    ) -> None:
        self._records.append(
            ModelUsageRecord(
                request_id=request_id,
                route_id=route_id,
                attempt=attempt,
                status="failed",
                input_tokens=0,
                output_tokens=0,
                failure_code=failure_code,
            )
        )
