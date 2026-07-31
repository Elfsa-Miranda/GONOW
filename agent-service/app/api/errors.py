"""Stable public error envelopes that never expose exception details."""

from __future__ import annotations

import re
from typing import Any

from pydantic import BaseModel, ConfigDict, Field


_REQUEST_ID = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$")
_PUBLIC_ERRORS: dict[str, tuple[int, str]] = {
    "auth.invalid_token": (401, "Authentication failed."),
    "auth.forbidden": (403, "This action is not allowed."),
    "context.invalid": (400, "The request context is invalid."),
    "tenant.scope_missing": (403, "A tenant scope is required."),
    "rate.limit": (429, "Too many requests."),
    "service.unavailable": (503, "The service is temporarily unavailable."),
}


class PublicError(BaseModel):
    model_config = ConfigDict(extra="forbid", frozen=True)

    code: str = Field(pattern=r"^[a-z][a-z0-9_.]+$")
    message: str = Field(min_length=1, max_length=160)
    request_id: str = Field(min_length=1, max_length=128)
    retry_after_seconds: int | None = Field(default=None, ge=1, le=86_400)


class ErrorEnvelope(BaseModel):
    model_config = ConfigDict(extra="forbid", frozen=True)

    error: PublicError


class SafeApiError(RuntimeError):
    """An internal exception carrying only a registered public error code."""

    def __init__(self, code: str, *, retry_after_seconds: int | None = None) -> None:
        if code not in _PUBLIC_ERRORS:
            raise ValueError("unregistered public error code")
        super().__init__(code)
        self.code = code
        self.retry_after_seconds = retry_after_seconds


def _safe_request_id(request_id: str) -> str:
    return request_id if _REQUEST_ID.fullmatch(request_id) else "unavailable"


def build_error_envelope(
    error: BaseException,
    *,
    request_id: str,
    status_code: int | None = None,
) -> tuple[int, ErrorEnvelope]:
    """Map an exception to an allowlisted response without inspecting its text."""

    candidate_code = getattr(error, "code", "internal.error")
    code = candidate_code if isinstance(candidate_code, str) and candidate_code in _PUBLIC_ERRORS else "internal.error"
    registered_status, message = _PUBLIC_ERRORS.get(
        code,
        (500, "The service could not complete the request."),
    )
    resolved_status = registered_status if status_code is None else status_code
    if resolved_status >= 500:
        code = "internal.error"
        message = "The service could not complete the request."
    retry_after = getattr(error, "retry_after_seconds", None)
    if not isinstance(retry_after, int) or retry_after < 1 or code != "rate.limit":
        retry_after = None
    envelope = ErrorEnvelope(
        error=PublicError(
            code=code,
            message=message,
            request_id=_safe_request_id(request_id),
            retry_after_seconds=retry_after,
        )
    )
    return resolved_status, envelope


def error_response_payload(envelope: ErrorEnvelope) -> dict[str, Any]:
    """Return the exact JSON-safe response schema, omitting absent optional fields."""

    return envelope.model_dump(mode="json", exclude_none=True)
