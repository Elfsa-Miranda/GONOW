from __future__ import annotations

import site
import sys
from datetime import datetime, timezone
from pathlib import Path

import pytest


SERVICE_ROOT = Path(__file__).resolve().parents[3]
site.addsitedir(str(SERVICE_ROOT / ".venv" / "Lib" / "site-packages"))
sys.path.insert(0, str(SERVICE_ROOT))

from app.observability.logging import (  # noqa: E402
    AuditIntegrityError,
    AuditLogger,
    AuditUnavailable,
    InMemoryAppendOnlyAuditRepository,
)


NOW = datetime(2026, 8, 1, tzinfo=timezone.utc)


def _record(logger: AuditLogger, receipt_id: str = "receipt-1"):
    return logger.record(
        receipt_id=receipt_id,
        event="command.authorized",
        actor_ref="actor-1",
        tenant_ref="tenant-1",
        action="itinerary.update",
        outcome="success",
        request_id="req-1",
    )


def test_28_audit_logger_s_high_risk_action_appends_receipt() -> None:
    repository = InMemoryAppendOnlyAuditRepository()
    receipt = _record(AuditLogger(repository, clock=lambda: NOW))
    assert repository.receipts() == (receipt,)
    assert repository.verify() is True


def test_28_audit_logger_i_missing_receipt_blocks_action() -> None:
    class MissingRepository:
        def tail(self):
            raise OSError("isolated unavailable")

        def append(self, receipt):
            raise AssertionError("append must not follow a missing tail")

        def verify(self):
            return False

    with pytest.raises(AuditUnavailable, match="audit.unavailable"):
        _record(AuditLogger(MissingRepository(), clock=lambda: NOW))


def test_28_audit_logger_d_tampered_receipt_is_rejected() -> None:
    repository = InMemoryAppendOnlyAuditRepository()
    receipt = _record(AuditLogger(repository, clock=lambda: NOW))
    repository._receipts[0] = receipt.model_copy(update={"action": "itinerary.delete"})
    assert repository.verify() is False
    with pytest.raises(AuditIntegrityError):
        _record(AuditLogger(repository, clock=lambda: NOW), receipt_id="receipt-2")


def test_28_audit_logger_d_repository_failure_returns_stable_code() -> None:
    class FailingRepository:
        def tail(self):
            return 0, "0" * 64

        def append(self, receipt):
            raise OSError("synthetic repository failure")

        def verify(self):
            return False

    with pytest.raises(AuditUnavailable) as captured:
        _record(AuditLogger(FailingRepository(), clock=lambda: NOW))
    assert str(captured.value) == "audit.unavailable"
