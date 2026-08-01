from __future__ import annotations

import site
import sys
from pathlib import Path

import pytest
from pydantic import ValidationError


SERVICE_ROOT = Path(__file__).resolve().parents[3]
site.addsitedir(str(SERVICE_ROOT / ".venv" / "Lib" / "site-packages"))
sys.path.insert(0, str(SERVICE_ROOT))

from app.api.errors import (  # noqa: E402
    ErrorEnvelope,
    SafeApiError,
    build_error_envelope,
    error_response_payload,
)


def test_registered_error_has_stable_envelope() -> None:
    status, envelope = build_error_envelope(SafeApiError("auth.forbidden"), request_id="req-1")
    assert status == 403
    assert error_response_payload(envelope) == {
        "error": {"code": "auth.forbidden", "message": "This action is not allowed.", "request_id": "req-1"}
    }


def test_rate_limit_preserves_only_bounded_retry_hint() -> None:
    status, envelope = build_error_envelope(
        SafeApiError("rate.limit", retry_after_seconds=9), request_id="req-2"
    )
    assert status == 429
    assert envelope.error.retry_after_seconds == 9


def test_unsafe_5xx_body_is_never_returned() -> None:
    internal_detail = "database path and request body must stay private"
    status, envelope = build_error_envelope(RuntimeError(internal_detail), request_id="req-3")
    serialized = envelope.model_dump_json()
    assert status == 500
    assert envelope.error.code == "internal.error"
    assert internal_detail not in serialized


def test_explicit_5xx_overrides_a_public_client_error() -> None:
    _, envelope = build_error_envelope(
        SafeApiError("context.invalid"), request_id="req-4", status_code=503
    )
    assert envelope.error.code == "internal.error"


def test_invalid_request_id_is_not_reflected() -> None:
    unsafe = "request id with newline\nand path"
    _, envelope = build_error_envelope(RuntimeError(), request_id=unsafe)
    assert envelope.error.request_id == "unavailable"
    assert unsafe not in envelope.model_dump_json()


def test_unregistered_public_error_code_is_rejected() -> None:
    with pytest.raises(ValueError, match="unregistered"):
        SafeApiError("unknown.detail")


def test_error_schema_forbids_unplanned_fields() -> None:
    with pytest.raises(ValidationError):
        ErrorEnvelope.model_validate(
            {"error": {"code": "auth.forbidden", "message": "safe", "request_id": "req", "stack": "no"}}
        )
