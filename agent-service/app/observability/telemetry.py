"""Bounded, privacy-safe telemetry signals using OpenTelemetry field names."""

from __future__ import annotations

from collections.abc import Mapping
from typing import Any, Literal, Protocol

from pydantic import BaseModel, ConfigDict, Field

from app.observability.logging import PiiRedactor, PrivacyRedactionFailed


OTEL_ATTRIBUTE_ALLOWLIST = frozenset(
    {
        "service.name",
        "service.version",
        "deployment.environment.name",
        "http.request.method",
        "http.route",
        "http.response.status_code",
        "error.type",
        "gonow.outcome",
        "gonow.request_id",
    }
)


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


class TelemetryStats(BaseModel):
    model_config = ConfigDict(extra="forbid", frozen=True)

    exporter_failures: int = Field(ge=0)
    buffered_signals: int = Field(ge=0)
    dropped_signals: int = Field(ge=0)


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
    ) -> None:
        if buffer_capacity < 0:
            raise ValueError("buffer_capacity cannot be negative")
        self._exporter = exporter
        self._buffer_capacity = buffer_capacity
        self._redactor = redactor or PiiRedactor()
        self._buffer: list[TelemetrySignal] = []
        self._exporter_failures = 0
        self._dropped_signals = 0

    @property
    def stats(self) -> TelemetryStats:
        return TelemetryStats(
            exporter_failures=self._exporter_failures,
            buffered_signals=len(self._buffer),
            dropped_signals=self._dropped_signals,
        )

    def disable_exporter(self) -> None:
        self._exporter = None

    def emit_span(self, name: str, attributes: Mapping[str, Any]) -> bool:
        return self._emit("span", name, attributes, None)

    def emit_metric(self, name: str, value: int | float, attributes: Mapping[str, Any]) -> bool:
        return self._emit("metric", name, attributes, value)

    def _emit(
        self,
        kind: Literal["span", "metric"],
        name: str,
        attributes: Mapping[str, Any],
        value: int | float | None,
    ) -> bool:
        normalized = self._safe_attributes(attributes)
        signal = TelemetrySignal(kind=kind, name=name, attributes=normalized, value=value)
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
        if set(attributes) - OTEL_ATTRIBUTE_ALLOWLIST:
            raise TelemetryUnsafeAttribute()
        try:
            redacted = self._redactor.redact(dict(attributes)).value
        except PrivacyRedactionFailed as error:
            raise TelemetryUnsafeAttribute() from error
        if not isinstance(redacted, dict) or redacted != dict(attributes):
            raise TelemetryUnsafeAttribute()
        if not all(isinstance(value, (str, int, float, bool)) for value in redacted.values()):
            raise TelemetryUnsafeAttribute()
        route = redacted.get("http.route")
        if isinstance(route, str) and ("?" in route or "#" in route):
            raise TelemetryUnsafeAttribute()
        return redacted
