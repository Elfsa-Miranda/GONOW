from __future__ import annotations

import hashlib
import site
import sys
import uuid
from dataclasses import replace
from pathlib import Path

import pytest


SERVICE_ROOT = Path(__file__).resolve().parents[2]
site.addsitedir(str(SERVICE_ROOT / ".venv" / "Lib" / "site-packages"))
sys.path.insert(0, str(SERVICE_ROOT))

from app.persistence.models.knowledge import (  # noqa: E402
    KnowledgeDeletionRequestRecord,
    KnowledgeDeletionSurfaceRecord,
    KnowledgeDeletionTombstoneRecord,
)
from app.rag.deletion import (  # noqa: E402
    SURFACES,
    KnowledgeDeletionContext,
    KnowledgeDeletionCoordinator,
    KnowledgeDeletionDenied,
    KnowledgeDeletionIncomplete,
    KnowledgeDeletionTicket,
)


TENANT = "tenant-deletion-test"
SOURCE_ID = uuid.UUID("50000000-0000-4000-8000-000000001108")


def _digest(value: str) -> str:
    return hashlib.sha256(value.encode("utf-8")).hexdigest()


def _ticket() -> KnowledgeDeletionTicket:
    return KnowledgeDeletionTicket(
        deletion_id=uuid.UUID("60000000-0000-4000-8000-000000001108"),
        tenant_id=TENANT,
        source_id=SOURCE_ID,
        request_digest=_digest("request"),
        tombstone_digest=_digest("tombstone"),
        status="requested",
    )


def _context(tenant_id: str = TENANT) -> KnowledgeDeletionContext:
    return KnowledgeDeletionContext(
        tenant_id=tenant_id,
        principal_id="privacy-worker",
        permissions=frozenset({"knowledge.deletion.execute"}),
        audit_receipt_id="audit-delete-worker",
    )


class _Ledger:
    def __init__(self, ticket: KnowledgeDeletionTicket) -> None:
        self.ticket = ticket
        self.tombstoned = True
        self.receipts: dict[str, str] = {}
        self.completed = False

    def authorize_execution(
        self,
        *,
        context: KnowledgeDeletionContext,
        ticket: KnowledgeDeletionTicket,
    ) -> None:
        if context.tenant_id != ticket.tenant_id:
            raise KnowledgeDeletionDenied()
        if not self.is_tombstoned(ticket):
            raise KnowledgeDeletionIncomplete()

    def mark_surface_verified(
        self,
        *,
        context: KnowledgeDeletionContext,
        ticket: KnowledgeDeletionTicket,
        surface_name: str,
        evidence_digest: str,
    ) -> None:
        if context.tenant_id != ticket.tenant_id:
            raise KnowledgeDeletionDenied()
        previous = self.receipts.get(surface_name)
        if previous is not None and previous != evidence_digest:
            raise RuntimeError("knowledge.deletion_immutable_conflict")
        self.receipts[surface_name] = evidence_digest

    def complete(
        self,
        *,
        context: KnowledgeDeletionContext,
        ticket: KnowledgeDeletionTicket,
    ) -> KnowledgeDeletionTicket:
        if context.tenant_id != ticket.tenant_id:
            raise KnowledgeDeletionDenied()
        if set(self.receipts) != set(SURFACES):
            raise KnowledgeDeletionIncomplete()
        self.completed = True
        return replace(ticket, status="completed")

    def is_tombstoned(self, ticket: KnowledgeDeletionTicket) -> bool:
        return self.tombstoned and ticket == self.ticket


class _Surface:
    def __init__(self, surface_name: str, order: list[str]) -> None:
        self.surface_name = surface_name
        self.readable = True
        self.order = order
        self.restore_reconciliations = 0

    def purge(self, ticket: KnowledgeDeletionTicket) -> str:
        self.order.append(self.surface_name)
        self.readable = False
        return _digest(f"purge|{ticket.tombstone_digest}|{self.surface_name}")

    def is_readable(self, ticket: KnowledgeDeletionTicket) -> bool:
        return self.readable

    def reapply_tombstone_after_restore(
        self, ticket: KnowledgeDeletionTicket
    ) -> str:
        self.readable = True
        self.restore_reconciliations += 1
        self.readable = False
        return _digest(f"restore|{ticket.tombstone_digest}|{self.surface_name}")


def _fixture():
    ticket = _ticket()
    ledger = _Ledger(ticket)
    order: list[str] = []
    surfaces = {name: _Surface(name, order) for name in SURFACES}
    coordinator = KnowledgeDeletionCoordinator(ledger=ledger, surfaces=surfaces)
    return ticket, ledger, surfaces, order, coordinator


def test_request_tombstone_fanout_makes_every_surface_unreadable() -> None:
    ticket, ledger, surfaces, order, coordinator = _fixture()
    completed = coordinator.propagate(context=_context(), ticket=ticket)
    assert completed.status == "completed"
    assert ledger.completed
    assert order == list(SURFACES)
    assert set(ledger.receipts) == set(SURFACES)
    assert not any(surface.is_readable(ticket) for surface in surfaces.values())


def test_restore_reapplies_tombstone_and_never_resurrects_any_surface() -> None:
    ticket, _, surfaces, _, coordinator = _fixture()
    coordinator.propagate(context=_context(), ticket=ticket)
    coordinator.verify_restore_does_not_resurrect(context=_context(), ticket=ticket)
    assert not any(surface.is_readable(ticket) for surface in surfaces.values())
    assert all(surface.restore_reconciliations == 1 for surface in surfaces.values())


def test_fanout_retry_is_idempotent_and_keeps_same_evidence() -> None:
    ticket, ledger, _, _, coordinator = _fixture()
    first = coordinator.propagate(context=_context(), ticket=ticket)
    first_receipts = dict(ledger.receipts)
    second = coordinator.propagate(context=_context(), ticket=ticket)
    assert first.status == second.status == "completed"
    assert ledger.receipts == first_receipts


def test_readable_surface_fails_closed_without_completion() -> None:
    ticket, ledger, surfaces, _, coordinator = _fixture()
    failing = surfaces["eval"]
    original_purge = failing.purge

    def incomplete_purge(value: KnowledgeDeletionTicket) -> str:
        digest = original_purge(value)
        failing.readable = True
        return digest

    failing.purge = incomplete_purge  # type: ignore[method-assign]
    with pytest.raises(KnowledgeDeletionIncomplete, match="deletion_incomplete"):
        coordinator.propagate(context=_context(), ticket=ticket)
    assert not ledger.completed
    assert "eval" not in ledger.receipts
    assert "backup" not in ledger.receipts


def test_tenant_boundary_denies_foreign_deletion_progress() -> None:
    ticket, ledger, _, order, coordinator = _fixture()
    with pytest.raises(KnowledgeDeletionDenied, match="deletion_denied"):
        coordinator.propagate(
            context=_context(tenant_id="tenant-foreign"), ticket=ticket
        )
    assert not ledger.completed
    assert not order


def test_missing_tombstone_blocks_delete_and_restore_paths() -> None:
    ticket, ledger, _, _, coordinator = _fixture()
    ledger.tombstoned = False
    with pytest.raises(KnowledgeDeletionIncomplete, match="deletion_incomplete"):
        coordinator.propagate(context=_context(), ticket=ticket)
    with pytest.raises(KnowledgeDeletionIncomplete, match="deletion_incomplete"):
        coordinator.verify_restore_does_not_resurrect(
            context=_context(), ticket=ticket
        )


def test_all_surface_contract_and_database_guards_are_frozen() -> None:
    assert SURFACES == ("source", "chunk", "vector", "cache", "eval", "backup")
    assert {
        KnowledgeDeletionRequestRecord.__tablename__,
        KnowledgeDeletionTombstoneRecord.__tablename__,
        KnowledgeDeletionSurfaceRecord.__tablename__,
    } == {
        "deletion_requests",
        "deletion_tombstones",
        "deletion_surface_receipts",
    }
    migration = (
        SERVICE_ROOT
        / "migrations"
        / "versions"
        / "p11_008_knowledge_tombstones.py"
    ).read_text(encoding="utf-8")
    for required in (
        "FORCE ROW LEVEL SECURITY",
        "block_tombstoned_source_writes",
        "knowledge.deleted_source_cannot_be_restored",
        "deletion_surface_receipts",
        "forward-fix only",
    ):
        assert required in migration


def test_surface_registry_rejects_missing_or_duplicate_contract() -> None:
    ticket = _ticket()
    ledger = _Ledger(ticket)
    order: list[str] = []
    incomplete = {name: _Surface(name, order) for name in SURFACES[:-1]}
    with pytest.raises(ValueError, match="surfaces must be registered"):
        KnowledgeDeletionCoordinator(ledger=ledger, surfaces=incomplete)
