from __future__ import annotations

import site
import sys
from pathlib import Path

import pytest
from pydantic import ValidationError


SERVICE_ROOT = Path(__file__).resolve().parents[2]
site.addsitedir(str(SERVICE_ROOT / ".venv" / "Lib" / "site-packages"))
sys.path.insert(0, str(SERVICE_ROOT))

from app.observability.logging import (  # noqa: E402
    PiiRedactor,
    PrivacyRedactionFailed,
    SafeLogger,
)
from app.observability.telemetry import (  # noqa: E402
    InMemoryTelemetryExporter,
    SafeTelemetry,
    TelemetryUnsafeAttribute,
)


def test_nested_pii_and_credentials_are_redacted() -> None:
    source = {
        "contact": "traveler.one@example.invalid",
        "nested": [{"phone": "+86 138 0013 8000", "authorization": "Bearer synthetic-value"}],
    }
    result = PiiRedactor().redact(source)
    rendered = repr(result.value)
    assert "traveler.one@example.invalid" not in rendered
    assert "+86 138 0013 8000" not in rendered
    assert "synthetic-value" not in rendered
    assert set(result.tags) == {"credential", "email", "phone"}


def test_opaque_body_prompt_response_and_reasoning_are_omitted() -> None:
    result = PiiRedactor().redact(
        {"event": "request.completed", "body": "private", "prompt": "private", "reasoning": "private"}
    )
    assert result.value == {"event": "request.completed"}
    assert result.tags == ("opaque_content_omitted",)


def test_unknown_object_fails_closed_before_export() -> None:
    with pytest.raises(PrivacyRedactionFailed):
        PiiRedactor().redact(object())


def test_minimal_log_schema_validation_is_strict() -> None:
    records: list[dict[str, object]] = []
    logger = SafeLogger(records.append)
    logger.emit(event="request.completed", level="info", outcome="success", request_id="req-1")
    assert len(records) == 1
    with pytest.raises(ValidationError):
        logger.emit(
            event="request.completed",
            level="info",
            outcome="success",
            request_id="req-2",
            body="forbidden",
        )


def test_telemetry_rejects_pii_and_unlisted_labels() -> None:
    telemetry = SafeTelemetry(InMemoryTelemetryExporter())
    with pytest.raises(TelemetryUnsafeAttribute):
        telemetry.emit_span("http.request", {"gonow.request_id": "traveler.two@example.invalid"})
    with pytest.raises(TelemetryUnsafeAttribute):
        telemetry.emit_span("http.request", {"user.name": "synthetic"})


def test_telemetry_route_must_not_include_query_values() -> None:
    telemetry = SafeTelemetry(InMemoryTelemetryExporter())
    with pytest.raises(TelemetryUnsafeAttribute):
        telemetry.emit_span("http.request", {"http.route": "/runs?user=synthetic"})
