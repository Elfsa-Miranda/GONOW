"""Thread-safe, content-free local reference ledger for cost routing.

This module proves accounting semantics only.  It is intentionally in-memory
and does not claim durable or distributed production enforcement.
"""

from __future__ import annotations

import hashlib
import json
import re
from dataclasses import dataclass, field
from enum import StrEnum
from threading import RLock
from typing import Any


_SHA256 = re.compile(r"^[0-9a-f]{64}$")
_IDENTIFIER = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.:-]{0,127}$")
_EMPTY_DIGEST = hashlib.sha256(b"").hexdigest()


class CostLedgerError(RuntimeError):
    def __init__(self, code: str) -> None:
        self.code = code
        super().__init__(code)


class LedgerOperation(StrEnum):
    RESERVE = "reserve"
    COMMIT = "commit"
    RELEASE = "release"
    RECONCILE = "reconcile"


class ReservationState(StrEnum):
    RESERVED = "reserved"
    COMMITTED = "committed"
    RELEASED = "released"


class ReleaseReason(StrEnum):
    START_FAILED = "start_failed"
    CANCELLED = "cancelled"
    NOT_NEEDED = "not_needed"


@dataclass(frozen=True, slots=True, repr=False)
class CostReservationRequest:
    idempotency_key: str = field(repr=False)
    run_id: str
    budget_scope_digest: str
    route_id: str
    policy_digest: str
    price_version: str
    estimated_microusd: int

    def __post_init__(self) -> None:
        if (
            _IDENTIFIER.fullmatch(self.idempotency_key) is None
            or _IDENTIFIER.fullmatch(self.run_id) is None
            or _SHA256.fullmatch(self.budget_scope_digest) is None
            or _IDENTIFIER.fullmatch(self.route_id) is None
            or _SHA256.fullmatch(self.policy_digest) is None
            or _IDENTIFIER.fullmatch(self.price_version) is None
            or self.estimated_microusd <= 0
        ):
            raise CostLedgerError("cost_ledger.request_invalid")

    def __repr__(self) -> str:
        return (
            "CostReservationRequest(idempotency_key=<redacted>, "
            f"run_id={self.run_id!r}, route_id={self.route_id!r}, "
            f"estimated_microusd={self.estimated_microusd})"
        )


@dataclass(frozen=True, slots=True)
class CostLedgerEntry:
    sequence: int
    operation: LedgerOperation
    operation_key_digest: str
    reservation_key_digest: str
    semantic_digest: str
    run_id: str
    budget_scope_digest: str
    route_id: str
    policy_digest: str
    price_version: str
    amount_microusd: int
    budget_delta_microusd: int
    provider_receipt_digest: str | None
    release_reason: ReleaseReason | None
    previous_entry_digest: str
    entry_digest: str


@dataclass(frozen=True, slots=True)
class ReservationReceipt:
    reservation_key_digest: str
    state: ReservationState
    estimated_microusd: int
    accounted_microusd: int
    last_entry_digest: str


@dataclass(frozen=True, slots=True)
class CostBudgetSnapshot:
    budget_scope_digest: str
    budget_limit_microusd: int
    reserved_microusd: int
    committed_microusd: int
    available_microusd: int
    entry_count: int
    chain_head_digest: str


@dataclass(slots=True)
class _Reservation:
    request: CostReservationRequest = field(repr=False)
    state: ReservationState
    accounted_microusd: int
    last_entry: CostLedgerEntry
    operations: dict[str, tuple[str, CostLedgerEntry]] = field(default_factory=dict)


def _digest(value: Any) -> str:
    return hashlib.sha256(
        json.dumps(
            value,
            ensure_ascii=True,
            sort_keys=True,
            separators=(",", ":"),
        ).encode("utf-8")
    ).hexdigest()


def _key_digest(value: str) -> str:
    return hashlib.sha256(value.encode("utf-8")).hexdigest()


def _request_semantics(request: CostReservationRequest) -> dict[str, Any]:
    return {
        "run_id": request.run_id,
        "budget_scope_digest": request.budget_scope_digest,
        "route_id": request.route_id,
        "policy_digest": request.policy_digest,
        "price_version": request.price_version,
        "estimated_microusd": request.estimated_microusd,
    }


class LocalCostLedger:
    """Atomic local budget effects plus immutable chained event history."""

    def __init__(
        self, *, budget_scope_digest: str, budget_limit_microusd: int
    ) -> None:
        if (
            _SHA256.fullmatch(budget_scope_digest) is None
            or budget_limit_microusd <= 0
        ):
            raise CostLedgerError("cost_ledger.policy_invalid")
        self._budget_scope_digest = budget_scope_digest
        self._budget_limit_microusd = budget_limit_microusd
        self._reservations: dict[str, _Reservation] = {}
        self._entries: list[CostLedgerEntry] = []
        self._lock = RLock()

    @property
    def entries(self) -> tuple[CostLedgerEntry, ...]:
        with self._lock:
            return tuple(self._entries)

    def _totals(self) -> tuple[int, int]:
        reserved = sum(
            item.request.estimated_microusd
            for item in self._reservations.values()
            if item.state is ReservationState.RESERVED
        )
        committed = sum(
            item.accounted_microusd
            for item in self._reservations.values()
            if item.state is ReservationState.COMMITTED
        )
        return reserved, committed

    def snapshot(self) -> CostBudgetSnapshot:
        with self._lock:
            reserved, committed = self._totals()
            return CostBudgetSnapshot(
                budget_scope_digest=self._budget_scope_digest,
                budget_limit_microusd=self._budget_limit_microusd,
                reserved_microusd=reserved,
                committed_microusd=committed,
                available_microusd=(
                    self._budget_limit_microusd - reserved - committed
                ),
                entry_count=len(self._entries),
                chain_head_digest=(
                    self._entries[-1].entry_digest if self._entries else _EMPTY_DIGEST
                ),
            )

    @staticmethod
    def _receipt(reservation: _Reservation) -> ReservationReceipt:
        return ReservationReceipt(
            reservation_key_digest=_key_digest(reservation.request.idempotency_key),
            state=reservation.state,
            estimated_microusd=reservation.request.estimated_microusd,
            accounted_microusd=reservation.accounted_microusd,
            last_entry_digest=reservation.last_entry.entry_digest,
        )

    def _append(
        self,
        *,
        operation: LedgerOperation,
        operation_key: str,
        request: CostReservationRequest,
        semantic_digest: str,
        amount_microusd: int,
        budget_delta_microusd: int,
        provider_receipt_digest: str | None = None,
        release_reason: ReleaseReason | None = None,
    ) -> CostLedgerEntry:
        previous = self._entries[-1].entry_digest if self._entries else _EMPTY_DIGEST
        values = {
            "sequence": len(self._entries) + 1,
            "operation": operation.value,
            "operation_key_digest": _key_digest(operation_key),
            "reservation_key_digest": _key_digest(request.idempotency_key),
            "semantic_digest": semantic_digest,
            "run_id": request.run_id,
            "budget_scope_digest": request.budget_scope_digest,
            "route_id": request.route_id,
            "policy_digest": request.policy_digest,
            "price_version": request.price_version,
            "amount_microusd": amount_microusd,
            "budget_delta_microusd": budget_delta_microusd,
            "provider_receipt_digest": provider_receipt_digest,
            "release_reason": release_reason.value if release_reason else None,
            "previous_entry_digest": previous,
        }
        entry = CostLedgerEntry(
            sequence=values["sequence"],
            operation=operation,
            operation_key_digest=values["operation_key_digest"],
            reservation_key_digest=values["reservation_key_digest"],
            semantic_digest=semantic_digest,
            run_id=request.run_id,
            budget_scope_digest=request.budget_scope_digest,
            route_id=request.route_id,
            policy_digest=request.policy_digest,
            price_version=request.price_version,
            amount_microusd=amount_microusd,
            budget_delta_microusd=budget_delta_microusd,
            provider_receipt_digest=provider_receipt_digest,
            release_reason=release_reason,
            previous_entry_digest=previous,
            entry_digest=_digest(values),
        )
        self._entries.append(entry)
        return entry

    def reserve(self, request: CostReservationRequest) -> ReservationReceipt:
        semantic = _digest(_request_semantics(request))
        with self._lock:
            if request.budget_scope_digest != self._budget_scope_digest:
                raise CostLedgerError("cost_ledger.scope_mismatch")
            existing = self._reservations.get(request.idempotency_key)
            if existing is not None:
                recorded_semantic = existing.operations[LedgerOperation.RESERVE.value][0]
                if recorded_semantic != semantic:
                    raise CostLedgerError("cost_ledger.idempotency_collision")
                return self._receipt(existing)
            snapshot = self.snapshot()
            if request.estimated_microusd > snapshot.available_microusd:
                raise CostLedgerError("cost_ledger.budget_exhausted")
            entry = self._append(
                operation=LedgerOperation.RESERVE,
                operation_key=f"reserve:{request.idempotency_key}",
                request=request,
                semantic_digest=semantic,
                amount_microusd=request.estimated_microusd,
                budget_delta_microusd=request.estimated_microusd,
            )
            reservation = _Reservation(
                request=request,
                state=ReservationState.RESERVED,
                accounted_microusd=0,
                last_entry=entry,
            )
            reservation.operations[LedgerOperation.RESERVE.value] = (semantic, entry)
            self._reservations[request.idempotency_key] = reservation
            return self._receipt(reservation)

    def _require(self, idempotency_key: str) -> _Reservation:
        reservation = self._reservations.get(idempotency_key)
        if reservation is None:
            raise CostLedgerError("cost_ledger.reservation_missing")
        return reservation

    @staticmethod
    def _validate_receipt_digest(value: str) -> None:
        if _SHA256.fullmatch(value) is None:
            raise CostLedgerError("cost_ledger.receipt_invalid")

    def commit(
        self,
        *,
        idempotency_key: str,
        actual_microusd: int,
        provider_receipt_digest: str,
    ) -> ReservationReceipt:
        self._validate_receipt_digest(provider_receipt_digest)
        if actual_microusd < 0:
            raise CostLedgerError("cost_ledger.amount_invalid")
        semantics = _digest(
            {
                "actual_microusd": actual_microusd,
                "provider_receipt_digest": provider_receipt_digest,
            }
        )
        with self._lock:
            reservation = self._require(idempotency_key)
            existing = reservation.operations.get(LedgerOperation.COMMIT.value)
            if existing is not None:
                if existing[0] != semantics:
                    raise CostLedgerError("cost_ledger.idempotency_collision")
                return self._receipt(reservation)
            if reservation.state is not ReservationState.RESERVED:
                raise CostLedgerError("cost_ledger.transition_invalid")
            snapshot = self.snapshot()
            projected = (
                snapshot.reserved_microusd
                + snapshot.committed_microusd
                - reservation.request.estimated_microusd
                + actual_microusd
            )
            if projected > self._budget_limit_microusd:
                raise CostLedgerError("cost_ledger.budget_exhausted")
            entry = self._append(
                operation=LedgerOperation.COMMIT,
                operation_key=f"commit:{idempotency_key}",
                request=reservation.request,
                semantic_digest=semantics,
                amount_microusd=actual_microusd,
                budget_delta_microusd=(
                    actual_microusd - reservation.request.estimated_microusd
                ),
                provider_receipt_digest=provider_receipt_digest,
            )
            reservation.state = ReservationState.COMMITTED
            reservation.accounted_microusd = actual_microusd
            reservation.last_entry = entry
            reservation.operations[LedgerOperation.COMMIT.value] = (semantics, entry)
            return self._receipt(reservation)

    def release(
        self, *, idempotency_key: str, reason: ReleaseReason
    ) -> ReservationReceipt:
        semantics = _digest({"release_reason": reason.value})
        with self._lock:
            reservation = self._require(idempotency_key)
            existing = reservation.operations.get(LedgerOperation.RELEASE.value)
            if existing is not None:
                if existing[0] != semantics:
                    raise CostLedgerError("cost_ledger.idempotency_collision")
                return self._receipt(reservation)
            if reservation.state is not ReservationState.RESERVED:
                raise CostLedgerError("cost_ledger.transition_invalid")
            entry = self._append(
                operation=LedgerOperation.RELEASE,
                operation_key=f"release:{idempotency_key}",
                request=reservation.request,
                semantic_digest=semantics,
                amount_microusd=0,
                budget_delta_microusd=-reservation.request.estimated_microusd,
                release_reason=reason,
            )
            reservation.state = ReservationState.RELEASED
            reservation.last_entry = entry
            reservation.operations[LedgerOperation.RELEASE.value] = (semantics, entry)
            return self._receipt(reservation)

    def reconcile(
        self,
        *,
        idempotency_key: str,
        billed_microusd: int,
        provider_receipt_digest: str,
    ) -> ReservationReceipt:
        self._validate_receipt_digest(provider_receipt_digest)
        if billed_microusd < 0:
            raise CostLedgerError("cost_ledger.amount_invalid")
        semantics = _digest(
            {
                "billed_microusd": billed_microusd,
                "provider_receipt_digest": provider_receipt_digest,
            }
        )
        with self._lock:
            reservation = self._require(idempotency_key)
            existing = reservation.operations.get(LedgerOperation.RECONCILE.value)
            if existing is not None:
                if existing[0] != semantics:
                    raise CostLedgerError("cost_ledger.idempotency_collision")
                return self._receipt(reservation)
            if reservation.state is not ReservationState.COMMITTED:
                raise CostLedgerError("cost_ledger.transition_invalid")
            snapshot = self.snapshot()
            projected = (
                snapshot.reserved_microusd
                + snapshot.committed_microusd
                - reservation.accounted_microusd
                + billed_microusd
            )
            if projected > self._budget_limit_microusd:
                raise CostLedgerError("cost_ledger.budget_exhausted")
            delta = billed_microusd - reservation.accounted_microusd
            entry = self._append(
                operation=LedgerOperation.RECONCILE,
                operation_key=f"reconcile:{idempotency_key}",
                request=reservation.request,
                semantic_digest=semantics,
                amount_microusd=billed_microusd,
                budget_delta_microusd=delta,
                provider_receipt_digest=provider_receipt_digest,
            )
            reservation.accounted_microusd = billed_microusd
            reservation.last_entry = entry
            reservation.operations[LedgerOperation.RECONCILE.value] = (semantics, entry)
            return self._receipt(reservation)

    def verify_chain(self) -> bool:
        with self._lock:
            previous = _EMPTY_DIGEST
            for expected_sequence, entry in enumerate(self._entries, start=1):
                values = {
                    "sequence": entry.sequence,
                    "operation": entry.operation.value,
                    "operation_key_digest": entry.operation_key_digest,
                    "reservation_key_digest": entry.reservation_key_digest,
                    "semantic_digest": entry.semantic_digest,
                    "run_id": entry.run_id,
                    "budget_scope_digest": entry.budget_scope_digest,
                    "route_id": entry.route_id,
                    "policy_digest": entry.policy_digest,
                    "price_version": entry.price_version,
                    "amount_microusd": entry.amount_microusd,
                    "budget_delta_microusd": entry.budget_delta_microusd,
                    "provider_receipt_digest": entry.provider_receipt_digest,
                    "release_reason": (
                        entry.release_reason.value if entry.release_reason else None
                    ),
                    "previous_entry_digest": entry.previous_entry_digest,
                }
                if (
                    entry.sequence != expected_sequence
                    or entry.previous_entry_digest != previous
                    or entry.entry_digest != _digest(values)
                ):
                    return False
                previous = entry.entry_digest
            return True
