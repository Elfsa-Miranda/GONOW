"""Privacy-first structured logging and append-only audit receipts."""

from __future__ import annotations

import hashlib
import json
import re
from collections.abc import Mapping
from datetime import datetime, timezone
from typing import Any, Callable, Literal, Protocol

from pydantic import BaseModel, ConfigDict, Field


_EMAIL = re.compile(r"\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}\b")
_PHONE = re.compile(r"(?<!\d)(?:\+?\d[\d ()-]{7,}\d)(?!\d)")
_BEARER = re.compile(r"(?i)\bbearer\s+[A-Za-z0-9._~+/=-]+")
_JWT = re.compile(r"\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\b")
_SECRET_KEYS = frozenset({"authorization", "cookie", "password", "secret", "token", "access_token"})
_OPAQUE_KEYS = frozenset({"body", "prompt", "response", "reasoning", "chain_of_thought"})


class PrivacyRedactionFailed(RuntimeError):
    code = "privacy.redaction_failed"

    def __init__(self) -> None:
        super().__init__(self.code)


class AuditUnavailable(RuntimeError):
    code = "audit.unavailable"

    def __init__(self) -> None:
        super().__init__(self.code)


class AuditIntegrityError(RuntimeError):
    code = "audit.integrity_failed"

    def __init__(self) -> None:
        super().__init__(self.code)


class RedactionResult(BaseModel):
    model_config = ConfigDict(extra="forbid", frozen=True)

    value: Any
    tags: tuple[str, ...]


class PiiRedactor:
    """Recursively minimize synthetic PII without retaining the source value."""

    def redact(self, payload: Any) -> RedactionResult:
        tags: set[str] = set()
        try:
            value = self._redact(payload, tags)
        except PrivacyRedactionFailed:
            raise
        except Exception as error:
            raise PrivacyRedactionFailed() from error
        return RedactionResult(value=value, tags=tuple(sorted(tags)))

    def _redact(self, value: Any, tags: set[str]) -> Any:
        if value is None or isinstance(value, (bool, int, float)):
            return value
        if isinstance(value, str):
            redacted = _EMAIL.sub("[REDACTED_EMAIL]", value)
            if redacted != value:
                tags.add("email")
            updated = _PHONE.sub("[REDACTED_PHONE]", redacted)
            if updated != redacted:
                tags.add("phone")
            redacted = _BEARER.sub("Bearer [REDACTED]", updated)
            if redacted != updated:
                tags.add("credential")
            updated = _JWT.sub("[REDACTED_TOKEN]", redacted)
            if updated != redacted:
                tags.add("credential")
            return updated
        if isinstance(value, Mapping):
            output: dict[str, Any] = {}
            for key, item in value.items():
                if not isinstance(key, str):
                    raise PrivacyRedactionFailed()
                normalized = key.lower()
                if normalized in _OPAQUE_KEYS:
                    tags.add("opaque_content_omitted")
                    continue
                if normalized in _SECRET_KEYS:
                    output[key] = "[REDACTED]"
                    tags.add("credential")
                    continue
                output[key] = self._redact(item, tags)
            return output
        if isinstance(value, (list, tuple)):
            return [self._redact(item, tags) for item in value]
        raise PrivacyRedactionFailed()


class SafeLogRecord(BaseModel):
    model_config = ConfigDict(extra="forbid", frozen=True)

    event: str = Field(pattern=r"^[a-z][a-z0-9_.]+$", max_length=96)
    level: Literal["debug", "info", "warning", "error"]
    outcome: Literal["success", "denied", "failed", "degraded"]
    request_id: str = Field(min_length=1, max_length=128)
    trace_id: str | None = Field(default=None, max_length=128)
    route: str | None = Field(default=None, max_length=160)
    status_code: int | None = Field(default=None, ge=100, le=599)
    error_code: str | None = Field(default=None, pattern=r"^[a-z][a-z0-9_.]+$")
    duration_ms: int | None = Field(default=None, ge=0, le=86_400_000)


class SafeLogger:
    """Validate the fixed log schema, then redact before handing off a record."""

    def __init__(self, sink: Callable[[dict[str, Any]], None], redactor: PiiRedactor | None = None) -> None:
        self._sink = sink
        self._redactor = redactor or PiiRedactor()

    def emit(self, **fields: Any) -> dict[str, Any]:
        record = SafeLogRecord.model_validate(fields)
        result = self._redactor.redact(record.model_dump(exclude_none=True))
        if not isinstance(result.value, dict):
            raise PrivacyRedactionFailed()
        self._sink(result.value)
        return result.value


class AuditReceipt(BaseModel):
    model_config = ConfigDict(extra="forbid", frozen=True)

    receipt_id: str = Field(min_length=1, max_length=128)
    sequence: int = Field(ge=1)
    occurred_at: str
    event: str = Field(pattern=r"^[a-z][a-z0-9_.]+$")
    actor_ref: str = Field(min_length=1, max_length=128)
    tenant_ref: str = Field(min_length=1, max_length=128)
    action: str = Field(pattern=r"^[a-z][a-z0-9_.]+$")
    outcome: Literal["success", "denied", "failed"]
    request_id: str = Field(min_length=1, max_length=128)
    previous_hash: str = Field(pattern=r"^[a-f0-9]{64}$")
    receipt_hash: str = Field(pattern=r"^[a-f0-9]{64}$")


class AuditRepository(Protocol):
    def tail(self) -> tuple[int, str]:
        """Return the current sequence and immutable chain tail."""

    def append(self, receipt: AuditReceipt) -> None:
        """Append exactly once or raise."""

    def verify(self) -> bool:
        """Verify ordering and receipt hashes."""


def _receipt_hash(fields: Mapping[str, Any]) -> str:
    canonical = json.dumps(dict(fields), ensure_ascii=True, separators=(",", ":"), sort_keys=True)
    return hashlib.sha256(canonical.encode("utf-8")).hexdigest()


class InMemoryAppendOnlyAuditRepository:
    """Isolated-test repository; production persistence arrives in later phases."""

    def __init__(self) -> None:
        self._receipts: list[AuditReceipt] = []

    def tail(self) -> tuple[int, str]:
        if not self._receipts:
            return 0, "0" * 64
        latest = self._receipts[-1]
        return latest.sequence, latest.receipt_hash

    def append(self, receipt: AuditReceipt) -> None:
        sequence, previous_hash = self.tail()
        if receipt.sequence != sequence + 1 or receipt.previous_hash != previous_hash:
            raise AuditIntegrityError()
        if any(item.receipt_id == receipt.receipt_id for item in self._receipts):
            raise AuditIntegrityError()
        self._receipts.append(receipt)

    def verify(self) -> bool:
        previous_hash = "0" * 64
        for expected_sequence, receipt in enumerate(self._receipts, start=1):
            content = receipt.model_dump(exclude={"receipt_hash"})
            if (
                receipt.sequence != expected_sequence
                or receipt.previous_hash != previous_hash
                or receipt.receipt_hash != _receipt_hash(content)
            ):
                return False
            previous_hash = receipt.receipt_hash
        return True

    def receipts(self) -> tuple[AuditReceipt, ...]:
        return tuple(self._receipts)


class AuditLogger:
    """Fail closed when a high-risk action cannot produce a valid receipt."""

    def __init__(
        self,
        repository: AuditRepository,
        *,
        redactor: PiiRedactor | None = None,
        clock: Callable[[], datetime] | None = None,
    ) -> None:
        self._repository = repository
        self._redactor = redactor or PiiRedactor()
        self._clock = clock or (lambda: datetime.now(timezone.utc))

    def record(
        self,
        *,
        receipt_id: str,
        event: str,
        actor_ref: str,
        tenant_ref: str,
        action: str,
        outcome: Literal["success", "denied", "failed"],
        request_id: str,
    ) -> AuditReceipt:
        try:
            minimized = self._redactor.redact({"actor_ref": actor_ref, "tenant_ref": tenant_ref})
            if not isinstance(minimized.value, dict):
                raise PrivacyRedactionFailed()
            sequence, previous_hash = self._repository.tail()
            content = {
                "receipt_id": receipt_id,
                "sequence": sequence + 1,
                "occurred_at": self._clock().astimezone(timezone.utc).isoformat(),
                "event": event,
                "actor_ref": minimized.value["actor_ref"],
                "tenant_ref": minimized.value["tenant_ref"],
                "action": action,
                "outcome": outcome,
                "request_id": request_id,
                "previous_hash": previous_hash,
            }
            receipt = AuditReceipt(**content, receipt_hash=_receipt_hash(content))
            self._repository.append(receipt)
            if not self._repository.verify():
                raise AuditIntegrityError()
            return receipt
        except (PrivacyRedactionFailed, AuditIntegrityError):
            raise
        except Exception as error:
            raise AuditUnavailable() from error
