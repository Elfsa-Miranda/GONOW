"""Fail-closed trace minimization and deterministic correlation identifiers."""

from __future__ import annotations

import hashlib
import hmac
import json
import math
import re
from collections.abc import Mapping, Sequence
from typing import Any
from uuid import UUID

from pydantic import BaseModel, ConfigDict, Field

from app.observability.logging import PiiRedactor, PrivacyRedactionFailed


TRACE_STAGES = ("flutter", "api", "job", "worker", "tool_model", "command")
TRACE_ATTRIBUTE_ALLOWLIST = frozenset(
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
        "gonow.stage",
        "gonow.run_ref",
        "gonow.behavior_digest",
    }
)

_HEX_64 = re.compile(r"^[a-f0-9]{64}$")
_LOW_CARDINALITY = re.compile(r"^[a-z][a-z0-9_.-]{0,95}$")
_REQUEST_REFERENCE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$")
_FORBIDDEN_KEY_PARTS = ("authorization", "body", "cookie", "jwt", "password", "prompt", "reasoning", "secret", "token")


class TraceRedactionError(RuntimeError):
    code = "telemetry.trace_redaction_failed"

    def __init__(self) -> None:
        super().__init__(self.code)


class TraceIdentifiers(BaseModel):
    """Export-safe identifiers; raw request and run identifiers never enter a signal."""

    model_config = ConfigDict(extra="forbid", frozen=True)

    trace_id: str = Field(pattern=r"^[a-f0-9]{32}$")
    run_ref: str = Field(pattern=r"^[a-f0-9]{64}$")
    behavior_digest: str = Field(pattern=r"^[a-f0-9]{64}$")


class TraceLocator(BaseModel):
    model_config = ConfigDict(extra="forbid", frozen=True)

    trace_id: str = Field(pattern=r"^[a-f0-9]{32}$")
    run_ref: str = Field(pattern=r"^[a-f0-9]{64}$")
    behavior_digest: str = Field(pattern=r"^[a-f0-9]{64}$")


def _keyed_digest(key: bytes, namespace: str, value: str) -> str:
    return hmac.new(key, f"{namespace}\0{value}".encode(), hashlib.sha256).hexdigest()


class TraceIdentityFactory:
    """Create searchable pseudonymous references with a caller-supplied secret key."""

    def __init__(self, correlation_key: bytes) -> None:
        if not isinstance(correlation_key, bytes) or len(correlation_key) < 16:
            raise ValueError("correlation_key must contain at least 16 bytes")
        self._correlation_key = correlation_key

    def create(self, *, request_id: str, run_id: UUID | str, behavior_digest: str) -> TraceIdentifiers:
        if not request_id or len(request_id) > 256 or not _HEX_64.fullmatch(behavior_digest):
            raise TraceRedactionError()
        try:
            normalized_run_id = str(UUID(str(run_id)))
        except (ValueError, TypeError, AttributeError) as error:
            raise TraceRedactionError() from error
        trace_id = _keyed_digest(self._correlation_key, "trace", request_id)[:32]
        run_ref = _keyed_digest(self._correlation_key, "run", normalized_run_id)
        return TraceIdentifiers(trace_id=trace_id, run_ref=run_ref, behavior_digest=behavior_digest)

    def locate(self, *, request_id: str, run_id: UUID | str, behavior_digest: str) -> TraceLocator:
        identifiers = self.create(request_id=request_id, run_id=run_id, behavior_digest=behavior_digest)
        return TraceLocator(**identifiers.model_dump())


class TraceRedactor:
    """Accept only low-cardinality, already-safe trace attributes."""

    def __init__(self, pii_redactor: PiiRedactor | None = None) -> None:
        self._pii_redactor = pii_redactor or PiiRedactor()

    def attributes(self, values: Mapping[str, Any]) -> dict[str, str | int | float | bool]:
        if set(values) - TRACE_ATTRIBUTE_ALLOWLIST:
            raise TraceRedactionError()
        if any(part in key.lower() for key in values for part in _FORBIDDEN_KEY_PARTS):
            raise TraceRedactionError()
        try:
            result = self._pii_redactor.redact(dict(values))
        except PrivacyRedactionFailed as error:
            raise TraceRedactionError() from error
        if result.tags or not isinstance(result.value, dict) or result.value != dict(values):
            raise TraceRedactionError()
        normalized: dict[str, str | int | float | bool] = {}
        for key, value in result.value.items():
            if not isinstance(value, (str, int, float, bool)) or (
                isinstance(value, float) and not math.isfinite(value)
            ):
                raise TraceRedactionError()
            self._validate_value(key, value)
            normalized[key] = value
        return normalized

    def assert_canaries_absent(self, payload: Any, canaries: Sequence[str]) -> None:
        rendered = json.dumps(payload, ensure_ascii=True, separators=(",", ":"), sort_keys=True)
        if any(canary and canary in rendered for canary in canaries):
            raise TraceRedactionError()

    @staticmethod
    def _validate_value(key: str, value: str | int | float | bool) -> None:
        if key in {"gonow.run_ref", "gonow.behavior_digest"} and (
            not isinstance(value, str) or not _HEX_64.fullmatch(value)
        ):
            raise TraceRedactionError()
        if key == "gonow.stage" and value not in TRACE_STAGES:
            raise TraceRedactionError()
        if key == "gonow.outcome" and value not in {"success", "denied", "failed", "degraded"}:
            raise TraceRedactionError()
        if key == "gonow.request_id" and (
            not isinstance(value, str) or not _REQUEST_REFERENCE.fullmatch(value)
        ):
            raise TraceRedactionError()
        if key in {"service.name", "service.version", "deployment.environment.name", "error.type"} and (
            not isinstance(value, str) or not _LOW_CARDINALITY.fullmatch(value)
        ):
            raise TraceRedactionError()
        if key == "http.route" and (
            not isinstance(value, str) or len(value) > 160 or "?" in value or "#" in value
        ):
            raise TraceRedactionError()
        if key == "http.request.method" and value not in {"DELETE", "GET", "PATCH", "POST", "PUT"}:
            raise TraceRedactionError()
        if key == "http.response.status_code" and (
            isinstance(value, bool) or not isinstance(value, int) or not 100 <= value <= 599
        ):
            raise TraceRedactionError()
