from __future__ import annotations

import json
import site
import sys
from pathlib import Path
from uuid import UUID

import pytest


SERVICE_ROOT = Path(__file__).resolve().parents[2]
site.addsitedir(str(SERVICE_ROOT / ".venv" / "Lib" / "site-packages"))
sys.path.insert(0, str(SERVICE_ROOT))

from app.observability.redaction import TraceIdentityFactory, TraceRedactionError  # noqa: E402
from app.observability.telemetry import (  # noqa: E402
    InMemoryTelemetryExporter,
    SafeTelemetry,
    TelemetryUnsafeAttribute,
    TraceSamplingPolicy,
    TraceTopology,
)


KEY = b"synthetic-trace-key-material"
RUN_ID = UUID("8c1a8a4a-9f1e-4cdf-a327-82732f2fed5b")
DIGEST = "a" * 64


def _identifiers(request_id: str = "request-001"):
    return TraceIdentityFactory(KEY).create(request_id=request_id, run_id=RUN_ID, behavior_digest=DIGEST)


def test_full_topology_exports_only_pseudonymous_locators() -> None:
    exporter = InMemoryTelemetryExporter()
    identifiers = _identifiers("traveler@example.invalid")
    assert all(TraceTopology(SafeTelemetry(exporter), identifiers, sampling=TraceSamplingPolicy(success_rate_permyriad=10_000)).emit())
    rendered = json.dumps([item.model_dump() for item in exporter.signals], sort_keys=True)
    assert len(exporter.signals) == 6
    assert [item.attributes["gonow.stage"] for item in exporter.signals] == [
        "flutter", "api", "job", "worker", "tool_model", "command"
    ]
    assert str(RUN_ID) not in rendered
    assert "traveler@example.invalid" not in rendered
    assert all(item.attributes["gonow.behavior_digest"] == DIGEST for item in exporter.signals)
    assert all(item.attributes["gonow.run_ref"] == identifiers.run_ref for item in exporter.signals)


def test_trace_parent_chain_and_locator_are_deterministic() -> None:
    factory = TraceIdentityFactory(KEY)
    locator = factory.locate(request_id="request-001", run_id=RUN_ID, behavior_digest=DIGEST)
    exporter = InMemoryTelemetryExporter()
    TraceTopology(SafeTelemetry(exporter), _identifiers(), sampling=TraceSamplingPolicy(success_rate_permyriad=10_000)).emit()
    assert locator.trace_id == exporter.signals[0].trace_id
    assert locator.run_ref == exporter.signals[0].attributes["gonow.run_ref"]
    assert locator.behavior_digest == exporter.signals[0].attributes["gonow.behavior_digest"]
    assert exporter.signals[0].parent_span_id is None
    assert all(current.parent_span_id == previous.span_id for previous, current in zip(exporter.signals, exporter.signals[1:]))


def test_canary_is_rejected_before_export_even_in_allowlisted_field() -> None:
    canary = "synthetic-canary-value"
    exporter = InMemoryTelemetryExporter()
    telemetry = SafeTelemetry(exporter, canaries=(canary,))
    with pytest.raises(TelemetryUnsafeAttribute):
        telemetry.emit_span("run.failed", {"error.type": canary})
    assert exporter.signals == []


@pytest.mark.parametrize("key", ["prompt", "reasoning", "authorization", "user.email"])
def test_forbidden_or_unlisted_attribute_is_rejected(key: str) -> None:
    telemetry = SafeTelemetry(InMemoryTelemetryExporter())
    with pytest.raises(TelemetryUnsafeAttribute):
        telemetry.emit_span("run.started", {key: "synthetic-private-value"})


def test_zero_success_sampling_exports_no_success_but_keeps_failures() -> None:
    exporter = InMemoryTelemetryExporter()
    topology = TraceTopology(
        SafeTelemetry(exporter),
        _identifiers(),
        sampling=TraceSamplingPolicy(success_rate_permyriad=0),
    )
    result = topology.emit(outcomes={"worker": "failed"})
    assert result == (False, False, False, True, False, False)
    assert [item.attributes["gonow.stage"] for item in exporter.signals] == ["worker"]


@pytest.mark.parametrize(
    ("request_id", "run_id", "digest"),
    [("", RUN_ID, DIGEST), ("request-1", "not-a-uuid", DIGEST), ("request-1", RUN_ID, "bad")],
)
def test_invalid_identifier_input_fails_closed(request_id: str, run_id: UUID | str, digest: str) -> None:
    with pytest.raises(TraceRedactionError):
        TraceIdentityFactory(KEY).create(request_id=request_id, run_id=run_id, behavior_digest=digest)
