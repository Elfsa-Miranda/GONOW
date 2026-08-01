from __future__ import annotations

import site
import sys
from dataclasses import replace
from pathlib import Path
from typing import cast
import uuid
from unittest.mock import Mock

import pytest
from sqlalchemy.orm import Session, sessionmaker


SERVICE_ROOT = Path(__file__).resolve().parents[3]
site.addsitedir(str(SERVICE_ROOT / ".venv" / "Lib" / "site-packages"))
sys.path.insert(0, str(SERVICE_ROOT))

from app.persistence.repositories.invocations import (  # noqa: E402
    InvocationHandlerOutcome,
    InvocationReservation,
    InvocationSnapshot,
    PhysicalInvocationLedger,
    invocation_fingerprint,
)


def _snapshot(*, status: str = "reserved") -> InvocationSnapshot:
    return InvocationSnapshot(
        invocation_id=uuid.UUID("10000000-0000-0000-0000-000000000001"),
        tenant_id="tenant-harness",
        run_id=uuid.UUID("20000000-0000-0000-0000-000000000002"),
        job_id=uuid.UUID("30000000-0000-0000-0000-000000000003"),
        tool_call_id="call-harness",
        tool_name="weather.current",
        tool_version="1.0.0",
        request_fingerprint="4" * 64,
        status=cast("object", status),  # type: ignore[arg-type]
        result_ref=None,
        result_digest=None,
        error_code=None,
    )


def _invoke(ledger: PhysicalInvocationLedger, handler: Mock):
    snapshot = _snapshot()
    return ledger.invoke(
        tenant_id=snapshot.tenant_id,
        run_id=snapshot.run_id,
        job_id=snapshot.job_id,
        holder_id="worker-harness",
        fencing_token=1,
        tool_call_id=snapshot.tool_call_id,
        tool_name=snapshot.tool_name,
        tool_version=snapshot.tool_version,
        request_fingerprint=snapshot.request_fingerprint,
        max_physical_calls=1,
        reservation_audit_receipt_id="audit-reserve-harness",
        completion_audit_receipt_id="audit-complete-harness",
        handler=handler,
    )


def test_18_invocation_ledger_s_fingerprint_is_deterministic_and_scoped() -> None:
    first = invocation_fingerprint(
        tool_name="weather.current", tool_version="1.0.0", argument_sha256="1" * 64
    )
    replay = invocation_fingerprint(
        tool_name="weather.current", tool_version="1.0.0", argument_sha256="1" * 64
    )
    changed_tool = invocation_fingerprint(
        tool_name="poi.search", tool_version="1.0.0", argument_sha256="1" * 64
    )
    assert first == replay
    assert first != changed_tool


def test_18_invocation_ledger_s_execute_calls_handler_then_persists(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    ledger = PhysicalInvocationLedger(cast(sessionmaker[Session], None))
    reserved = _snapshot()
    completed = replace(
        reserved,
        status="succeeded",
        result_ref="tool-result://sha256/" + "5" * 64,
        result_digest="5" * 64,
    )
    monkeypatch.setattr(
        ledger, "reserve", Mock(return_value=InvocationReservation("execute", reserved))
    )
    persist = Mock(return_value=completed)
    monkeypatch.setattr(ledger, "record_outcome", persist)
    handler = Mock(return_value=InvocationHandlerOutcome.succeeded("5" * 64))
    result = _invoke(ledger, handler)
    assert result.handler_called and result.invocation.status == "succeeded"
    handler.assert_called_once_with()
    persist.assert_called_once()


def test_18_invocation_ledger_i_invalid_fingerprint_input_fails_closed() -> None:
    with pytest.raises(ValueError, match="fingerprint input is invalid"):
        invocation_fingerprint(
            tool_name="weather.current",
            tool_version="latest",
            argument_sha256="not-a-digest",
        )


def test_18_invocation_ledger_d_reservation_failure_never_calls_handler(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    ledger = PhysicalInvocationLedger(cast(sessionmaker[Session], None))
    monkeypatch.setattr(ledger, "reserve", Mock(side_effect=RuntimeError("pg.unavailable")))
    handler = Mock(return_value=InvocationHandlerOutcome.succeeded("5" * 64))
    with pytest.raises(RuntimeError, match="pg.unavailable"):
        _invoke(ledger, handler)
    handler.assert_not_called()


def test_18_invocation_ledger_d_reserved_replay_requires_reconcile_without_handler(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    ledger = PhysicalInvocationLedger(cast(sessionmaker[Session], None))
    reserved = _snapshot()
    monkeypatch.setattr(
        ledger,
        "reserve",
        Mock(return_value=InvocationReservation("reconcile", reserved)),
    )
    handler = Mock(return_value=InvocationHandlerOutcome.succeeded("5" * 64))
    result = _invoke(ledger, handler)
    assert result.decision == "reconcile" and not result.handler_called
    handler.assert_not_called()
