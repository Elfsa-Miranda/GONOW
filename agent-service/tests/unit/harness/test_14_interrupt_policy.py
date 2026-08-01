from __future__ import annotations

from concurrent.futures import ThreadPoolExecutor
from dataclasses import replace
from datetime import UTC, datetime, timedelta
from pathlib import Path
import site
import sys
from threading import Lock
from uuid import UUID, uuid4

import pytest


SERVICE_ROOT = Path(__file__).resolve().parents[3]
site.addsitedir(str(SERVICE_ROOT / ".venv" / "Lib" / "site-packages"))
sys.path.insert(0, str(SERVICE_ROOT))

from app.auth.resume_token import (  # noqa: E402
    ResumeCapabilityRecord,
    ResumeCapabilityRejected,
    ResumeCapabilityService,
)


NOW = datetime(2026, 8, 1, tzinfo=UTC)
TENANT = "tenant-harness-14"
PRINCIPAL = "principal-harness-14"
COMMAND_HASH = "c" * 64


class AtomicStore:
    def __init__(self) -> None:
        self.records: dict[str, ResumeCapabilityRecord] = {}
        self.lock = Lock()

    def insert(self, record: ResumeCapabilityRecord) -> None:
        with self.lock:
            assert record.token_hash not in self.records
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
        with self.lock:
            record = self.records.get(token_hash)
            if record is None or record.consumed_at is not None:
                return None
            if not record.issued_at <= consumed_at < record.expires_at:
                return None
            if (
                record.tenant_id,
                record.principal_id,
                record.run_id,
                record.interrupt_id,
                record.command_hash,
                record.command_version,
            ) != (
                tenant_id,
                principal_id,
                run_id,
                interrupt_id,
                command_hash,
                command_version,
            ):
                return None
            consumed = replace(record, consumed_at=consumed_at)
            self.records[token_hash] = consumed
            return consumed


def _fixture(*, ttl: timedelta = timedelta(minutes=5)):
    store = AtomicStore()
    service = ResumeCapabilityService(
        store,
        clock=lambda: NOW,
        token_factory=lambda: f"grc_{uuid4().hex}",
    )
    run_id = uuid4()
    interrupt_id = uuid4()
    issued = service.issue(
        tenant_id=TENANT,
        principal_id=PRINCIPAL,
        run_id=run_id,
        interrupt_id=interrupt_id,
        command_hash=COMMAND_HASH,
        command_version="1.0",
        ttl=ttl,
    )
    return store, service, issued, run_id, interrupt_id


def _consume(service, issued, run_id, interrupt_id, **overrides):
    arguments = {
        "token": issued.token,
        "tenant_id": TENANT,
        "principal_id": PRINCIPAL,
        "run_id": run_id,
        "interrupt_id": interrupt_id,
        "command_hash": COMMAND_HASH,
        "command_version": "1.0",
    }
    arguments.update(overrides)
    return service.consume(**arguments)


def test_14_interrupt_policy_s_persists_digest_not_capability() -> None:
    store, _, issued, _, _ = _fixture()
    record = next(iter(store.records.values()))
    assert record.token_hash != issued.token
    assert issued.token not in repr(store.records)
    assert record.nonce.version == 4


def test_14_interrupt_policy_i_concurrent_resume_has_one_winner() -> None:
    _, service, issued, run_id, interrupt_id = _fixture()

    def consume_once(_: int) -> bool:
        try:
            _consume(service, issued, run_id, interrupt_id)
        except ResumeCapabilityRejected:
            return False
        return True

    with ThreadPoolExecutor(max_workers=8) as executor:
        results = list(executor.map(consume_once, range(8)))
    assert results.count(True) == 1
    assert results.count(False) == 7


def test_14_interrupt_policy_d_identity_mismatch_does_not_burn_token() -> None:
    _, service, issued, run_id, interrupt_id = _fixture()
    with pytest.raises(ResumeCapabilityRejected, match="resume.invalid_or_expired"):
        _consume(
            service,
            issued,
            run_id,
            interrupt_id,
            principal_id="wrong-principal",
        )
    assert _consume(service, issued, run_id, interrupt_id).consumed_at == NOW


def test_14_interrupt_policy_d_expired_capability_is_rejected() -> None:
    store = AtomicStore()
    issue_time = NOW
    current = [issue_time]
    service = ResumeCapabilityService(
        store,
        clock=lambda: current[0],
        token_factory=lambda: "grc_harness-expired",
    )
    run_id = uuid4()
    interrupt_id = uuid4()
    issued = service.issue(
        tenant_id=TENANT,
        principal_id=PRINCIPAL,
        run_id=run_id,
        interrupt_id=interrupt_id,
        command_hash=COMMAND_HASH,
        command_version="1.0",
        ttl=timedelta(seconds=1),
    )
    current[0] += timedelta(seconds=1)
    with pytest.raises(ResumeCapabilityRejected, match="resume.invalid_or_expired"):
        _consume(service, issued, run_id, interrupt_id)
    assert next(iter(store.records.values())).consumed_at is None
