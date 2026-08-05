from __future__ import annotations

import site
import sys
from pathlib import Path

import pytest
from uuid import UUID


SERVICE_ROOT = Path(__file__).resolve().parents[3]
site.addsitedir(str(SERVICE_ROOT / ".venv" / "Lib" / "site-packages"))
sys.path.insert(0, str(SERVICE_ROOT))

from app.observability.telemetry import (  # noqa: E402
    InMemoryTelemetryExporter,
    SafeTelemetry,
    TelemetrySignal,
    TelemetryUnsafeAttribute,
    TraceSamplingPolicy,
    TraceTopology,
)
from app.observability.redaction import TRACE_STAGES, TraceIdentityFactory  # noqa: E402


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


def test_29_telemetry_s_six_stage_trace_preserves_parent_chain_and_locator() -> None:
    exporter = InMemoryTelemetryExporter()
    identifiers = TraceIdentityFactory(b"synthetic-harness-key").create(
        request_id="request-harness",
        run_id=UUID("0bfbf2f8-7a68-4d68-9846-8d6f55d5c7c7"),
        behavior_digest="b" * 64,
    )
    emitted = TraceTopology(
        SafeTelemetry(exporter),
        identifiers,
        sampling=TraceSamplingPolicy(success_rate_permyriad=10_000),
    ).emit()
    assert emitted == (True,) * len(TRACE_STAGES)
    assert [signal.attributes["gonow.stage"] for signal in exporter.signals] == list(TRACE_STAGES)
    assert exporter.signals[0].parent_span_id is None
    assert all(current.parent_span_id == previous.span_id for previous, current in zip(exporter.signals, exporter.signals[1:]))


def test_29_telemetry_i_zero_sampling_keeps_failed_stage_only() -> None:
    exporter = InMemoryTelemetryExporter()
    identifiers = TraceIdentityFactory(b"synthetic-harness-key").create(
        request_id="request-harness",
        run_id=UUID("0bfbf2f8-7a68-4d68-9846-8d6f55d5c7c7"),
        behavior_digest="b" * 64,
    )
    telemetry = SafeTelemetry(exporter)
    TraceTopology(telemetry, identifiers, sampling=TraceSamplingPolicy(success_rate_permyriad=0)).emit(
        outcomes={"tool_model": "failed"}
    )
    assert [signal.attributes["gonow.stage"] for signal in exporter.signals] == ["tool_model"]
    assert telemetry.stats.sampled_out_signals == 5


def test_29_telemetry_d_canary_is_rejected_before_export() -> None:
    exporter = InMemoryTelemetryExporter()
    telemetry = SafeTelemetry(exporter, canaries=("synthetic-canary",))
    with pytest.raises(TelemetryUnsafeAttribute):
        telemetry.emit_span("run.failed", {"error.type": "synthetic-canary"})
    assert exporter.signals == []


def test_29_telemetry_d_raw_run_identifier_is_never_exported() -> None:
    run_id = UUID("0bfbf2f8-7a68-4d68-9846-8d6f55d5c7c7")
    identifiers = TraceIdentityFactory(b"synthetic-harness-key").create(
        request_id="request-harness", run_id=run_id, behavior_digest="b" * 64
    )
    exporter = InMemoryTelemetryExporter()
    TraceTopology(
        SafeTelemetry(exporter), identifiers, sampling=TraceSamplingPolicy(success_rate_permyriad=10_000)
    ).emit()
    assert all(str(run_id) not in signal.model_dump_json() for signal in exporter.signals)
