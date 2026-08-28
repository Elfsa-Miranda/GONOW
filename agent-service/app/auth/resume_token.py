"""Opaque, single-use resume capabilities bound to an exact command."""

from __future__ import annotations

from collections.abc import Callable
from dataclasses import dataclass, field
from datetime import UTC, datetime, timedelta
import hashlib
import secrets
from typing import Protocol
from uuid import UUID, uuid4


SHA256_PATTERN = frozenset("0123456789abcdef")


class ResumeCapabilityRejected(RuntimeError):
    """Non-oracular rejection for replay, expiry or any binding mismatch."""

    code = "resume.invalid_or_expired"

    def __init__(self) -> None:
        super().__init__(self.code)


@dataclass(frozen=True, slots=True)
class ResumeCapabilityRecord:
    capability_id: UUID
    token_hash: str
    nonce: UUID
    tenant_id: str
    principal_id: str
    run_id: UUID
    interrupt_id: UUID
    command_hash: str
    command_version: str
    issued_at: datetime
    expires_at: datetime
    consumed_at: datetime | None = None


@dataclass(frozen=True, slots=True)
class IssuedResumeCapability:
    capability_id: UUID
    token: str = field(repr=False)
    expires_at: datetime

    def __repr__(self) -> str:
        return (
            "IssuedResumeCapability("
            f"capability_id={self.capability_id!r}, token='[REDACTED]', "
            f"expires_at={self.expires_at!r})"
        )


class ResumeCapabilityStore(Protocol):
    """Durable adapter contract; consume must be one atomic compare-and-swap."""

    def insert(self, record: ResumeCapabilityRecord) -> None: ...

    def consume_once(
        self,
        *,
        token_hash: str,
        tenant_id: str,
        principal_id: str,
        run_id: UUID,
        interrupt_id: UUID,
        command_hash: str,
        command_version: str,
        consumed_at: datetime,
    ) -> ResumeCapabilityRecord | None: ...


Clock = Callable[[], datetime]
TokenFactory = Callable[[], str]


def _utc_now() -> datetime:
    return datetime.now(UTC)


def _new_token() -> str:
    return "grc_" + secrets.token_urlsafe(32)


def token_digest(token: str) -> str:
    if not token or len(token) > 256:
        raise ResumeCapabilityRejected()
    return hashlib.sha256(token.encode("utf-8")).hexdigest()


def _validate_binding(
    *, tenant_id: str, principal_id: str, command_hash: str, command_version: str
) -> None:
    if not tenant_id or len(tenant_id) > 256 or not principal_id or len(principal_id) > 256:
        raise ValueError("resume.binding_invalid")
    if len(command_hash) != 64 or any(character not in SHA256_PATTERN for character in command_hash):
        raise ValueError("resume.command_hash_invalid")
    pieces = command_version.split(".")
    if len(pieces) != 2 or any(not piece.isdigit() for piece in pieces):
        raise ValueError("resume.command_version_invalid")


class ResumeCapabilityService:
    """Issue cleartext once, persist only its hash, and consume by exact binding."""

    def __init__(
        self,
        store: ResumeCapabilityStore,
        *,
        clock: Clock = _utc_now,
        token_factory: TokenFactory = _new_token,
        maximum_ttl: timedelta = timedelta(minutes=15),
    ) -> None:
        if maximum_ttl <= timedelta(0) or maximum_ttl > timedelta(hours=1):
            raise ValueError("resume.maximum_ttl_invalid")
        self._store = store
        self._clock = clock
        self._token_factory = token_factory
        self._maximum_ttl = maximum_ttl

    def issue(
        self,
        *,
        tenant_id: str,
        principal_id: str,
        run_id: UUID,
        interrupt_id: UUID,
        command_hash: str,
        command_version: str,
        ttl: timedelta,
    ) -> IssuedResumeCapability:
        _validate_binding(
            tenant_id=tenant_id,
            principal_id=principal_id,
            command_hash=command_hash,
            command_version=command_version,
        )
        if ttl <= timedelta(0) or ttl > self._maximum_ttl:
            raise ValueError("resume.ttl_invalid")
        issued_at = self._aware_now()
        token = self._token_factory()
        record = ResumeCapabilityRecord(
            capability_id=uuid4(),
            token_hash=token_digest(token),
            nonce=uuid4(),
            tenant_id=tenant_id,
            principal_id=principal_id,
            run_id=run_id,
            interrupt_id=interrupt_id,
            command_hash=command_hash,
            command_version=command_version,
            issued_at=issued_at,
            expires_at=issued_at + ttl,
        )
        self._store.insert(record)
        return IssuedResumeCapability(
            capability_id=record.capability_id,
            token=token,
            expires_at=record.expires_at,
        )

    def consume(
        self,
        *,
        token: str,
        tenant_id: str,
        principal_id: str,
        run_id: UUID,
        interrupt_id: UUID,
        command_hash: str,
        command_version: str,
    ) -> ResumeCapabilityRecord:
        try:
            _validate_binding(
                tenant_id=tenant_id,
                principal_id=principal_id,
                command_hash=command_hash,
                command_version=command_version,
            )
            consumed_at = self._aware_now()
            record = self._store.consume_once(
                token_hash=token_digest(token),
                tenant_id=tenant_id,
                principal_id=principal_id,
                run_id=run_id,
                interrupt_id=interrupt_id,
                command_hash=command_hash,
                command_version=command_version,
                consumed_at=consumed_at,
            )
        except (TypeError, ValueError):
            record = None
        if record is None:
            raise ResumeCapabilityRejected()
        return record

    def _aware_now(self) -> datetime:
        value = self._clock()
        if value.tzinfo is None or value.utcoffset() is None:
            raise RuntimeError("resume.clock_timezone_required")
        return value
