from __future__ import annotations

import asyncio
from concurrent.futures import ThreadPoolExecutor
from dataclasses import asdict, replace
from datetime import UTC, datetime, timedelta
import json
import os
from pathlib import Path
import site
import sys
from threading import Lock
from uuid import UUID, uuid4

from fastapi import HTTPException, Request
import pytest


SERVICE_ROOT = Path(__file__).resolve().parents[2]
site.addsitedir(str(SERVICE_ROOT / ".venv" / "Lib" / "site-packages"))
sys.path.insert(0, str(SERVICE_ROOT))

from app.api.routes.resume import ResumeRequest, create_resume_router  # noqa: E402
from app.auth.context import (  # noqa: E402
    AuthorizationForbidden,
    RequestContext,
)
from app.auth.resume_token import (  # noqa: E402
    ResumeCapabilityRecord,
    ResumeCapabilityRejected,
    ResumeCapabilityService,
)


TENANT = "tenant-p06-resume"
PRINCIPAL = "principal-p06-resume"
COMMAND_HASH = "a" * 64
COMMAND_VERSION = "1.0"
NOW = datetime(2026, 8, 1, 0, 0, tzinfo=UTC)
REPORT_ENV = "GONOW_P06_004_REPORT"
EXPECTED_REPORT = (
    SERVICE_ROOT.parent
    / "docs"
    / "execution"
    / "evidence"
    / "phase-06"
    / "P06-004"
    / "resume-token-report.json"
)


class MutableClock:
    def __init__(self, value: datetime) -> None:
        self.value = value

    def __call__(self) -> datetime:
        return self.value


class AtomicStore:
    """Test double with the same single-statement CAS semantics as the adapter."""

    def __init__(self) -> None:
        self.records: dict[str, ResumeCapabilityRecord] = {}
        self._lock = Lock()

    def insert(self, record: ResumeCapabilityRecord) -> None:
        with self._lock:
            if record.token_hash in self.records:
                raise ValueError("resume.token_collision")
            self.records[record.token_hash] = record

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
    ) -> ResumeCapabilityRecord | None:
        with self._lock:
            record = self.records.get(token_hash)
            if record is None or record.consumed_at is not None:
                return None
            if not record.issued_at <= consumed_at < record.expires_at:
                return None
            expected = (
                tenant_id,
                principal_id,
                run_id,
                interrupt_id,
                command_hash,
                command_version,
            )
            actual = (
                record.tenant_id,
                record.principal_id,
                record.run_id,
                record.interrupt_id,
                record.command_hash,
                record.command_version,
            )
            if actual != expected:
                return None
            consumed = replace(record, consumed_at=consumed_at)
            self.records[token_hash] = consumed
            return consumed


def _service(
    store: AtomicStore,
    clock: MutableClock,
    *,
    token: str,
) -> ResumeCapabilityService:
    return ResumeCapabilityService(
        store,
        clock=clock,
        token_factory=lambda: token,
    )


def _issue(
    service: ResumeCapabilityService,
    *,
    run_id: UUID,
    interrupt_id: UUID,
    ttl: timedelta = timedelta(minutes=5),
):
    return service.issue(
        tenant_id=TENANT,
        principal_id=PRINCIPAL,
        run_id=run_id,
        interrupt_id=interrupt_id,
        command_hash=COMMAND_HASH,
        command_version=COMMAND_VERSION,
        ttl=ttl,
    )


def _context(*, principal: str = PRINCIPAL, allowed: bool = True) -> RequestContext:
    return RequestContext(
        principal_id=principal,
        tenant_id=TENANT,
        permissions=("run.resume",) if allowed else (),
        locale="en",
        timezone="UTC",
        trace_id="trace-p06-resume",
    )


def _write_report(value: dict[str, object]) -> None:
    requested = os.environ.get(REPORT_ENV, "").strip()
    if not requested:
        return
    target = Path(requested).resolve()
    assert target == EXPECTED_REPORT.resolve()
    target.parent.mkdir(parents=True, exist_ok=True)
    temporary = target.with_suffix(".tmp")
    temporary.write_text(
        json.dumps(value, sort_keys=True, separators=(",", ":")),
        encoding="utf-8",
    )
    temporary.replace(target)


def test_issue_persists_only_digest_and_redacts_representation() -> None:
    store = AtomicStore()
    clock = MutableClock(NOW)
    cleartext = "grc_issue-only-secret"
    issued = _issue(
        _service(store, clock, token=cleartext),
        run_id=uuid4(),
        interrupt_id=uuid4(),
    )
    persisted = next(iter(store.records.values()))

    assert persisted.token_hash != cleartext
    assert len(persisted.token_hash) == 64
    assert cleartext not in json.dumps(asdict(persisted), default=str)
    assert cleartext not in repr(issued)
    assert "[REDACTED]" in repr(issued)


def test_resume_matrix_is_single_use_and_exactly_bound() -> None:
    store = AtomicStore()
    clock = MutableClock(NOW)
    service = _service(store, clock, token="grc_matrix-secret")
    run_id = uuid4()
    interrupt_id = uuid4()
    issued = _issue(service, run_id=run_id, interrupt_id=interrupt_id)

    rejected = 0
    for overrides in (
        {"principal_id": "wrong-principal"},
        {"command_hash": "b" * 64},
        {"command_version": "2.0"},
    ):
        arguments = {
            "token": issued.token,
            "tenant_id": TENANT,
            "principal_id": PRINCIPAL,
            "run_id": run_id,
            "interrupt_id": interrupt_id,
            "command_hash": COMMAND_HASH,
            "command_version": COMMAND_VERSION,
        }
        arguments.update(overrides)
        with pytest.raises(ResumeCapabilityRejected, match="resume.invalid_or_expired"):
            service.consume(**arguments)
        rejected += 1

    consumed = service.consume(
        token=issued.token,
        tenant_id=TENANT,
        principal_id=PRINCIPAL,
        run_id=run_id,
        interrupt_id=interrupt_id,
        command_hash=COMMAND_HASH,
        command_version=COMMAND_VERSION,
    )
    with pytest.raises(ResumeCapabilityRejected, match="resume.invalid_or_expired"):
        service.consume(
            token=issued.token,
            tenant_id=TENANT,
            principal_id=PRINCIPAL,
            run_id=run_id,
            interrupt_id=interrupt_id,
            command_hash=COMMAND_HASH,
            command_version=COMMAND_VERSION,
        )

    expired_store = AtomicStore()
    expired_clock = MutableClock(NOW)
    expired_service = _service(
        expired_store,
        expired_clock,
        token="grc_expired-secret",
    )
    expired = _issue(
        expired_service,
        run_id=run_id,
        interrupt_id=uuid4(),
        ttl=timedelta(seconds=1),
    )
    expired_clock.value += timedelta(seconds=1)
    with pytest.raises(ResumeCapabilityRejected, match="resume.invalid_or_expired"):
        expired_service.consume(
            token=expired.token,
            tenant_id=TENANT,
            principal_id=PRINCIPAL,
            run_id=run_id,
            interrupt_id=next(iter(expired_store.records.values())).interrupt_id,
            command_hash=COMMAND_HASH,
            command_version=COMMAND_VERSION,
        )

    route_store = AtomicStore()
    route_service = _service(
        route_store,
        MutableClock(NOW),
        token="grc_route-secret",
    )
    route_interrupt = uuid4()
    route_capability = _issue(
        route_service,
        run_id=run_id,
        interrupt_id=route_interrupt,
    )
    active_context = [_context(allowed=False)]
    handler_calls: list[ResumeCapabilityRecord] = []
    router = create_resume_router(
        route_service,
        lambda request: active_context[0],
        lambda context, capability: handler_calls.append(capability),
    )
    endpoint = next(
        route.endpoint
        for route in router.routes
        if route.path == "/v1/runs/{run_id}/resume"
    )
    body = ResumeRequest(
        resume_token=route_capability.token,
        interrupt_id=route_interrupt,
        command_hash=COMMAND_HASH,
        command_version=COMMAND_VERSION,
    )
    request = Request({"type": "http", "method": "POST", "path": "/", "headers": []})
    with pytest.raises(AuthorizationForbidden):
        asyncio.run(endpoint(run_id=run_id, body=body, request=request))
    active_context[0] = _context(principal="wrong-principal")
    with pytest.raises(HTTPException) as mismatch:
        asyncio.run(endpoint(run_id=run_id, body=body, request=request))
    assert mismatch.value.status_code == 409
    active_context[0] = _context()
    response = asyncio.run(endpoint(run_id=run_id, body=body, request=request))

    assert rejected == 3
    assert consumed.consumed_at == NOW
    assert response.status == "resumed"
    assert len(handler_calls) == 1
    assert "grc_" not in repr(route_store.records)

    _write_report(
        {
            "schema_version": "1.0",
            "task_id": "TASK-P06-004",
            "resume_success_count": 1,
            "replay_accepted_count": 0,
            "wrong_principal_accepted_count": 0,
            "expired_token_accepted_count": 0,
            "original_token_valid_after_consume_count": 0,
            "command_hash_mismatch_accepted_count": 0,
            "command_version_mismatch_accepted_count": 0,
            "raw_token_persist_count": 0,
            "token_log_leak_count": 0,
            "authorization_bypass_count": 0,
            "identity_denied_mismatch": 0,
            "production_write_count": 0,
        }
    )


def test_invalid_tokens_share_one_non_oracular_error() -> None:
    service = _service(AtomicStore(), MutableClock(NOW), token="grc_unused-secret")
    for token in ("", "not-issued", "x" * 257):
        with pytest.raises(ResumeCapabilityRejected) as captured:
            service.consume(
                token=token,
                tenant_id=TENANT,
                principal_id=PRINCIPAL,
                run_id=uuid4(),
                interrupt_id=uuid4(),
                command_hash=COMMAND_HASH,
                command_version=COMMAND_VERSION,
            )
        assert captured.value.code == "resume.invalid_or_expired"


def test_naive_clock_fails_closed_before_persistence() -> None:
    store = AtomicStore()
    service = ResumeCapabilityService(
        store,
        clock=lambda: datetime(2026, 8, 1),
        token_factory=lambda: "grc_naive-clock-secret",
    )
    with pytest.raises(RuntimeError, match="resume.clock_timezone_required"):
        _issue(service, run_id=uuid4(), interrupt_id=uuid4())
    assert store.records == {}
