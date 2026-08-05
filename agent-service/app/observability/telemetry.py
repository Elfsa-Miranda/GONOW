"""Bounded, privacy-safe telemetry and the Release B trace topology."""

from __future__ import annotations

import hashlib
from collections.abc import Mapping, Sequence
from typing import Any, Literal, Protocol

from pydantic import BaseModel, ConfigDict, Field

from app.observability.logging import PiiRedactor
from app.observability.redaction import (
    TRACE_ATTRIBUTE_ALLOWLIST,
    TRACE_STAGES,
    TraceIdentifiers,
    TraceRedactionError,
    TraceRedactor,
)


OTEL_ATTRIBUTE_ALLOWLIST = TRACE_ATTRIBUTE_ALLOWLIST


class TelemetryUnsafeAttribute(RuntimeError):
    code = "telemetry.unsafe_attribute"

    def __init__(self) -> None:
        super().__init__(self.code)


class TelemetrySignal(BaseModel):
    model_config = ConfigDict(extra="forbid", frozen=True)

    kind: Literal["span", "metric"]
    name: str = Field(pattern=r"^[a-z][a-z0-9_.-]+$", max_length=96)
    attributes: dict[str, str | int | float | bool]
    value: int | float | None = None
    trace_id: str | None = Field(default=None, pattern=r"^[a-f0-9]{32}$")
    span_id: str | None = Field(default=None, pattern=r"^[a-f0-9]{16}$")
    parent_span_id: str | None = Field(default=None, pattern=r"^[a-f0-9]{16}$")
    sampled: bool = True


class TelemetryStats(BaseModel):
    model_config = ConfigDict(extra="forbid", frozen=True)

    exporter_failures: int = Field(ge=0)
    buffered_signals: int = Field(ge=0)
    dropped_signals: int = Field(ge=0)
    sampled_out_signals: int = Field(ge=0)


class TraceSamplingPolicy(BaseModel):
    """Deterministic sampling; denied, failed, and degraded outcomes are always retained."""

    model_config = ConfigDict(extra="forbid", frozen=True)

    success_rate_permyriad: int = Field(default=1000, ge=0, le=10_000)

    def should_sample(self, trace_id: str, outcome: str) -> bool:
        if outcome in {"denied", "failed", "degraded"}:
            return True
        bucket = int(hashlib.sha256(trace_id.encode("ascii")).hexdigest()[:8], 16) % 10_000
        return bucket < self.success_rate_permyriad


class TelemetryExporter(Protocol):
    def export(self, signal: TelemetrySignal) -> None:
        """Export one already-redacted signal."""


class InMemoryTelemetryExporter:
    """Deterministic isolated-test exporter; never an external truth source."""

    def __init__(self) -> None:
        self.signals: list[TelemetrySignal] = []

    def export(self, signal: TelemetrySignal) -> None:
        self.signals.append(signal)


class SafeTelemetry:
    """Reject unsafe labels and degrade without blocking business execution."""

    def __init__(
        self,
        exporter: TelemetryExporter | None,
        *,
        buffer_capacity: int = 64,
        redactor: PiiRedactor | None = None,
        canaries: Sequence[str] = (),
    ) -> None:
        if buffer_capacity < 0:
            raise ValueError("buffer_capacity cannot be negative")
        self._exporter = exporter
        self._buffer_capacity = buffer_capacity
        self._redactor = TraceRedactor(redactor)
        self._canaries = tuple(canaries)
        self._buffer: list[TelemetrySignal] = []
        self._exporter_failures = 0
        self._dropped_signals = 0
        self._sampled_out_signals = 0

    @property
    def stats(self) -> TelemetryStats:
        return TelemetryStats(
            exporter_failures=self._exporter_failures,
            buffered_signals=len(self._buffer),
            dropped_signals=self._dropped_signals,
            sampled_out_signals=self._sampled_out_signals,
        )

    def disable_exporter(self) -> None:
        self._exporter = None

    def emit_span(
        self,
        name: str,
        attributes: Mapping[str, Any],
        *,
        trace_id: str | None = None,
        span_id: str | None = None,
        parent_span_id: str | None = None,
        sampled: bool = True,
    ) -> bool:
        return self._emit(
            "span",
            name,
            attributes,
            None,
            trace_id=trace_id,
            span_id=span_id,
            parent_span_id=parent_span_id,
            sampled=sampled,
        )

    def emit_metric(self, name: str, value: int | float, attributes: Mapping[str, Any]) -> bool:
        return self._emit("metric", name, attributes, value)

    def _emit(
        self,
        kind: Literal["span", "metric"],
        name: str,
        attributes: Mapping[str, Any],
        value: int | float | None,
        *,
        trace_id: str | None = None,
        span_id: str | None = None,
        parent_span_id: str | None = None,
        sampled: bool = True,
    ) -> bool:
        if not sampled:
            self._sampled_out_signals += 1
            return False
        normalized = self._safe_attributes(attributes)
        signal = TelemetrySignal(
            kind=kind,
            name=name,
            attributes=normalized,
            value=value,
            trace_id=trace_id,
            span_id=span_id,
            parent_span_id=parent_span_id,
            sampled=sampled,
        )
        try:
            self._redactor.assert_canaries_absent(signal.model_dump(exclude_none=True), self._canaries)
        except TraceRedactionError as error:
            raise TelemetryUnsafeAttribute() from error
        if self._exporter is None:
            return False
        try:
            self._exporter.export(signal)
            return True
        except Exception:
            self._exporter_failures += 1
            if len(self._buffer) < self._buffer_capacity:
                self._buffer.append(signal)
            else:
                self._dropped_signals += 1
            return False

    def flush(self) -> int:
        if self._exporter is None:
            return 0
        exported = 0
        while self._buffer:
            signal = self._buffer[0]
            try:
                self._exporter.export(signal)
            except Exception:
                self._exporter_failures += 1
                break
            self._buffer.pop(0)
            exported += 1
        return exported

    def _safe_attributes(self, attributes: Mapping[str, Any]) -> dict[str, str | int | float | bool]:
        try:
            return self._redactor.attributes(attributes)
        except TraceRedactionError as error:
            raise TelemetryUnsafeAttribute() from error


class TraceTopology:
    """Emit the fixed Flutter→API→Job→Worker→Tool/Model→Command parent chain."""

    def __init__(
        self,
        telemetry: SafeTelemetry,
        identifiers: TraceIdentifiers,
        *,
        sampling: TraceSamplingPolicy | None = None,
    ) -> None:
        self._telemetry = telemetry
        self.identifiers = identifiers
        self._sampling = sampling or TraceSamplingPolicy()

    def emit(self, *, outcomes: Mapping[str, str] | None = None) -> tuple[bool, ...]:
        stage_outcomes = dict(outcomes or {})
        if set(stage_outcomes) - set(TRACE_STAGES):
            raise TelemetryUnsafeAttribute()
        emitted: list[bool] = []
        parent_span_id: str | None = None
        for stage in TRACE_STAGES:
            outcome = stage_outcomes.get(stage, "success")
            span_id = hashlib.sha256(f"{self.identifiers.trace_id}:{stage}".encode("ascii")).hexdigest()[:16]
            sampled = self._sampling.should_sample(self.identifiers.trace_id, outcome)
            emitted.append(
                self._telemetry.emit_span(
                    f"gonow.trace.{stage}",
                    {
                        "gonow.stage": stage,
                        "gonow.outcome": outcome,
                        "gonow.run_ref": self.identifiers.run_ref,
                        "gonow.behavior_digest": self.identifiers.behavior_digest,
                    },
                    trace_id=self.identifiers.trace_id,
                    span_id=span_id,
                    parent_span_id=parent_span_id,
                    sampled=sampled,
                )
            )
            parent_span_id = span_id
        return tuple(emitted)
