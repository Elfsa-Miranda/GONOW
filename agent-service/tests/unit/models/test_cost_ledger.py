from __future__ import annotations

from concurrent.futures import ThreadPoolExecutor
from dataclasses import fields, replace
import site
import sys
from pathlib import Path

import pytest


SERVICE_ROOT = Path(__file__).resolve().parents[3]
site.addsitedir(str(SERVICE_ROOT / ".venv" / "Lib" / "site-packages"))
sys.path.insert(0, str(SERVICE_ROOT))

from app.models.cost_ledger import (  # noqa: E402
    CostLedgerEntry,
    CostLedgerError,
    CostReservationRequest,
    LedgerOperation,
    LocalCostLedger,
    ReleaseReason,
    ReservationState,
)


SCOPE = "a" * 64
POLICY = "b" * 64
RECEIPT = "c" * 64


def _request(key: str = "reservation-001", *, amount: int = 20) -> CostReservationRequest:
    return CostReservationRequest(
        idempotency_key=key,
        run_id="run-001",
        budget_scope_digest=SCOPE,
        route_id="deepseek-v4-flash-candidate-v1",
        policy_digest=POLICY,
        price_version="deepseek-2026-08-04",
        estimated_microusd=amount,
    )


def test_reserve_commit_reconcile_are_append_only_and_exactly_idempotent() -> None:
    ledger = LocalCostLedger(budget_scope_digest=SCOPE, budget_limit_microusd=100)
    first = ledger.reserve(_request())
    duplicate = ledger.reserve(_request())
    assert first == duplicate
    assert len(ledger.entries) == 1

    committed = ledger.commit(
        idempotency_key="reservation-001",
        actual_microusd=18,
        provider_receipt_digest=RECEIPT,
    )
    duplicate_commit = ledger.commit(
        idempotency_key="reservation-001",
        actual_microusd=18,
        provider_receipt_digest=RECEIPT,
    )
    assert committed == duplicate_commit
    assert committed.state is ReservationState.COMMITTED
    assert len(ledger.entries) == 2

    reconciled = ledger.reconcile(
        idempotency_key="reservation-001",
        billed_microusd=19,
        provider_receipt_digest="d" * 64,
    )
    duplicate_reconcile = ledger.reconcile(
        idempotency_key="reservation-001",
        billed_microusd=19,
        provider_receipt_digest="d" * 64,
    )
    assert reconciled == duplicate_reconcile
    assert ledger.snapshot().committed_microusd == 19
    assert [entry.operation for entry in ledger.entries] == [
        LedgerOperation.RESERVE,
        LedgerOperation.COMMIT,
        LedgerOperation.RECONCILE,
    ]
    assert ledger.verify_chain()


def test_release_is_idempotent_and_restores_available_budget() -> None:
    ledger = LocalCostLedger(budget_scope_digest=SCOPE, budget_limit_microusd=20)
    ledger.reserve(_request())
    first = ledger.release(
        idempotency_key="reservation-001", reason=ReleaseReason.START_FAILED
    )
    second = ledger.release(
        idempotency_key="reservation-001", reason=ReleaseReason.START_FAILED
    )
    assert first == second
    assert first.state is ReservationState.RELEASED
    assert ledger.snapshot().available_microusd == 20
    assert len(ledger.entries) == 2


@pytest.mark.parametrize(
    "collision",
    [
        replace(_request(), route_id="other-route"),
        replace(_request(), policy_digest="e" * 64),
        replace(_request(), estimated_microusd=21),
    ],
)
def test_reservation_semantic_collision_has_zero_effect(
    collision: CostReservationRequest,
) -> None:
    ledger = LocalCostLedger(budget_scope_digest=SCOPE, budget_limit_microusd=100)
    ledger.reserve(_request())
    before = ledger.snapshot()
    with pytest.raises(CostLedgerError, match="cost_ledger.idempotency_collision"):
        ledger.reserve(collision)
    assert ledger.snapshot() == before


def test_commit_and_reconcile_collisions_have_zero_effect() -> None:
    ledger = LocalCostLedger(budget_scope_digest=SCOPE, budget_limit_microusd=100)
    ledger.reserve(_request())
    ledger.commit(
        idempotency_key="reservation-001",
        actual_microusd=18,
        provider_receipt_digest=RECEIPT,
    )
    committed = ledger.snapshot()
    with pytest.raises(CostLedgerError, match="cost_ledger.idempotency_collision"):
        ledger.commit(
            idempotency_key="reservation-001",
            actual_microusd=17,
            provider_receipt_digest=RECEIPT,
        )
    assert ledger.snapshot() == committed
    ledger.reconcile(
        idempotency_key="reservation-001",
        billed_microusd=19,
        provider_receipt_digest="d" * 64,
    )
    reconciled = ledger.snapshot()
    with pytest.raises(CostLedgerError, match="cost_ledger.idempotency_collision"):
        ledger.reconcile(
            idempotency_key="reservation-001",
            billed_microusd=20,
            provider_receipt_digest="d" * 64,
        )
    assert ledger.snapshot() == reconciled


def test_concurrent_unique_reservations_never_overspend() -> None:
    ledger = LocalCostLedger(budget_scope_digest=SCOPE, budget_limit_microusd=50)

    def reserve(index: int) -> str:
        try:
            ledger.reserve(_request(f"reservation-{index:03d}", amount=2))
            return "reserved"
        except CostLedgerError as error:
            return error.code

    with ThreadPoolExecutor(max_workers=20) as pool:
        outcomes = tuple(pool.map(reserve, range(100)))
    assert outcomes.count("reserved") == 25
    assert outcomes.count("cost_ledger.budget_exhausted") == 75
    snapshot = ledger.snapshot()
    assert snapshot.reserved_microusd == 50
    assert snapshot.available_microusd == 0
    assert snapshot.entry_count == 25
    assert ledger.verify_chain()


def test_concurrent_duplicate_reservation_has_one_effect() -> None:
    ledger = LocalCostLedger(budget_scope_digest=SCOPE, budget_limit_microusd=100)
    with ThreadPoolExecutor(max_workers=20) as pool:
        receipts = tuple(pool.map(lambda _: ledger.reserve(_request()), range(100)))
    assert len({receipt.last_entry_digest for receipt in receipts}) == 1
    assert ledger.snapshot().reserved_microusd == 20
    assert len(ledger.entries) == 1


def test_commit_or_reconcile_cannot_create_overspend() -> None:
    ledger = LocalCostLedger(budget_scope_digest=SCOPE, budget_limit_microusd=40)
    ledger.reserve(_request("first", amount=20))
    ledger.reserve(_request("second", amount=20))
    before_commit = ledger.snapshot()
    with pytest.raises(CostLedgerError, match="cost_ledger.budget_exhausted"):
        ledger.commit(
            idempotency_key="first",
            actual_microusd=21,
            provider_receipt_digest=RECEIPT,
        )
    assert ledger.snapshot() == before_commit
    ledger.release(idempotency_key="second", reason=ReleaseReason.NOT_NEEDED)
    ledger.commit(
        idempotency_key="first",
        actual_microusd=20,
        provider_receipt_digest=RECEIPT,
    )
    before_reconcile = ledger.snapshot()
    with pytest.raises(CostLedgerError, match="cost_ledger.budget_exhausted"):
        ledger.reconcile(
            idempotency_key="first",
            billed_microusd=41,
            provider_receipt_digest="d" * 64,
        )
    assert ledger.snapshot() == before_reconcile


def test_invalid_transitions_and_scope_fail_without_history_effect() -> None:
    ledger = LocalCostLedger(budget_scope_digest=SCOPE, budget_limit_microusd=100)
    with pytest.raises(CostLedgerError, match="cost_ledger.scope_mismatch"):
        ledger.reserve(replace(_request(), budget_scope_digest="f" * 64))
    assert ledger.entries == ()
    ledger.reserve(_request())
    ledger.release(idempotency_key="reservation-001", reason=ReleaseReason.CANCELLED)
    before = ledger.snapshot()
    with pytest.raises(CostLedgerError, match="cost_ledger.transition_invalid"):
        ledger.commit(
            idempotency_key="reservation-001",
            actual_microusd=10,
            provider_receipt_digest=RECEIPT,
        )
    assert ledger.snapshot() == before


def test_ledger_public_records_have_no_content_secret_or_raw_tenant_fields() -> None:
    forbidden = {
        "prompt",
        "response",
        "reasoning",
        "secret",
        "credential",
        "tenant_id",
        "user_id",
        "raw_pii",
        "idempotency_key",
    }
    assert {field.name for field in fields(CostLedgerEntry)}.isdisjoint(forbidden)
    assert "reservation-001" not in repr(_request())


def test_entry_tuple_is_immutable_and_snapshot_never_negative() -> None:
    ledger = LocalCostLedger(budget_scope_digest=SCOPE, budget_limit_microusd=100)
    ledger.reserve(_request())
    entries = ledger.entries
    with pytest.raises(AttributeError):
        entries[0].amount_microusd = 0  # type: ignore[misc]
    snapshot = ledger.snapshot()
    assert min(
        snapshot.reserved_microusd,
        snapshot.committed_microusd,
        snapshot.available_microusd,
    ) >= 0
