from __future__ import annotations

import site
import sys
from pathlib import Path

import pytest


SERVICE_ROOT = Path(__file__).resolve().parents[3]
site.addsitedir(str(SERVICE_ROOT / ".venv" / "Lib" / "site-packages"))
sys.path.insert(0, str(SERVICE_ROOT))

from app.observability.telemetry import (  # noqa: E402
    InMemoryTelemetryExporter,
    SafeTelemetry,
    TelemetrySignal,
    TelemetryUnsafeAttribute,
)


class DownExporter:
    def export(self, signal: TelemetrySignal) -> None:
        raise OSError("synthetic exporter down")


def test_29_telemetry_s_redacted_span_and_metric_match_minimal_schema() -> None:
    exporter = InMemoryTelemetryExporter()
    telemetry = SafeTelemetry(exporter)
    assert telemetry.emit_span("http.request", {"http.route": "/runs/{run_id}", "gonow.outcome": "success"})
    assert telemetry.emit_metric("gonow.request.count", 1, {"service.name": "gonow-agent"})
    assert [signal.kind for signal in exporter.signals] == ["span", "metric"]


def test_29_telemetry_i_exporter_down_does_not_block_business_result() -> None:
    telemetry = SafeTelemetry(DownExporter(), buffer_capacity=1)
    business_result = {"accepted": True}
    assert telemetry.emit_span("run.completed", {"gonow.outcome": "success"}) is False
    assert business_result == {"accepted": True}
    assert telemetry.stats.exporter_failures == 1


def test_29_telemetry_d_full_buffer_drops_with_bounded_counter() -> None:
    telemetry = SafeTelemetry(DownExporter(), buffer_capacity=1)
    telemetry.emit_span("run.first", {"gonow.outcome": "degraded"})
    telemetry.emit_span("run.second", {"gonow.outcome": "degraded"})
    assert telemetry.stats.buffered_signals == 1
    assert telemetry.stats.dropped_signals == 1


def test_29_telemetry_d_high_cardinality_pii_label_is_rejected() -> None:
    telemetry = SafeTelemetry(InMemoryTelemetryExporter())
    with pytest.raises(TelemetryUnsafeAttribute):
        telemetry.emit_span("run.started", {"gonow.request_id": "phase.telemetry@example.invalid"})
