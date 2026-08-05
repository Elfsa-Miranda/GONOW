"""Durable, irreversible Knowledge deletion propagation and restore fencing."""

from __future__ import annotations

import hashlib
import re
import uuid
from dataclasses import dataclass
from typing import Mapping, Protocol

from sqlalchemy import func, select
from sqlalchemy.orm import Session

from app.persistence.models.knowledge import (
    KnowledgeDeletionRequestRecord,
    KnowledgeDeletionSurfaceRecord,
    KnowledgeDeletionTombstoneRecord,
    KnowledgeOutboxRecord,
    KnowledgeSourceRecord,
)
from app.persistence.repositories.runs import TransactionRequired


SURFACES = ("source", "chunk", "vector", "cache", "eval", "backup")
DIGEST_PATTERN = re.compile(r"^[0-9a-f]{64}$")


class KnowledgeDeletionDenied(RuntimeError):
    code = "knowledge.deletion_denied"

    def __init__(self) -> None:
        super().__init__(self.code)


class KnowledgeDeletionNotFound(RuntimeError):
    code = "knowledge.deletion_not_found"

    def __init__(self) -> None:
        super().__init__(self.code)


class KnowledgeDeletionIncomplete(RuntimeError):
    code = "knowledge.deletion_incomplete"

    def __init__(self) -> None:
        super().__init__(self.code)


class KnowledgeDeletionImmutableConflict(RuntimeError):
    code = "knowledge.deletion_immutable_conflict"

    def __init__(self) -> None:
        super().__init__(self.code)


@dataclass(frozen=True, slots=True)
class KnowledgeDeletionContext:
    tenant_id: str
    principal_id: str
    permissions: frozenset[str]
    audit_receipt_id: str


@dataclass(frozen=True, slots=True)
class KnowledgeDeletionTicket:
    deletion_id: uuid.UUID
    tenant_id: str
    source_id: uuid.UUID
    request_digest: str
    tombstone_digest: str
    status: str


class KnowledgeDeletionLedger(Protocol):
    def authorize_execution(
        self,
        *,
        context: KnowledgeDeletionContext,
        ticket: KnowledgeDeletionTicket,
    ) -> None: ...

    def mark_surface_verified(
        self,
        *,
        context: KnowledgeDeletionContext,
        ticket: KnowledgeDeletionTicket,
        surface_name: str,
        evidence_digest: str,
    ) -> None: ...

    def complete(
        self,
        *,
        context: KnowledgeDeletionContext,
        ticket: KnowledgeDeletionTicket,
    ) -> KnowledgeDeletionTicket: ...

    def is_tombstoned(self, ticket: KnowledgeDeletionTicket) -> bool: ...


class KnowledgeDeletionSurface(Protocol):
    surface_name: str

    def purge(self, ticket: KnowledgeDeletionTicket) -> str: ...

    def is_readable(self, ticket: KnowledgeDeletionTicket) -> bool: ...

    def reapply_tombstone_after_restore(
        self, ticket: KnowledgeDeletionTicket
    ) -> str: ...


class KnowledgeDeletionRepository:
    """PostgreSQL deletion ledger; callers own transaction boundaries."""

    def __init__(self, session: Session) -> None:
        self._session = session

    def _require_transaction(self) -> None:
        if not self._session.in_transaction():
            raise TransactionRequired()

    @staticmethod
    def _authorize(context: KnowledgeDeletionContext, permission: str) -> None:
        if (
            not context.tenant_id
            or not context.principal_id
            or not context.audit_receipt_id
            or permission not in context.permissions
        ):
            raise KnowledgeDeletionDenied()

    def request_source_deletion(
        self,
        *,
        context: KnowledgeDeletionContext,
        source_id: uuid.UUID,
    ) -> KnowledgeDeletionTicket:
        self._require_transaction()
        self._authorize(context, "knowledge.deletion.request")
        source = self._session.execute(
            select(KnowledgeSourceRecord)
            .where(
                KnowledgeSourceRecord.tenant_id == context.tenant_id,
                KnowledgeSourceRecord.source_id == source_id,
            )
            .with_for_update()
        ).scalar_one_or_none()
        if source is None:
            raise KnowledgeDeletionNotFound()
        existing = self._session.execute(
            select(KnowledgeDeletionTombstoneRecord).where(
                KnowledgeDeletionTombstoneRecord.tenant_id == context.tenant_id,
                KnowledgeDeletionTombstoneRecord.source_id == source_id,
            )
        ).scalar_one_or_none()
        if existing is not None:
            return self._ticket(existing.deletion_id)
        if source.status == "deleted":
            raise KnowledgeDeletionImmutableConflict()

        deletion_id = uuid.uuid4()
        request_digest = hashlib.sha256(
            f"{context.tenant_id}|{source_id}|{context.audit_receipt_id}".encode("utf-8")
        ).hexdigest()
        tombstone_digest = hashlib.sha256(
            f"{request_digest}|{deletion_id}".encode("ascii")
        ).hexdigest()
        source.status = "delete_pending"
        source.audit_receipt_id = context.audit_receipt_id
        source.updated_at = func.statement_timestamp()
        self._session.flush()

        request = KnowledgeDeletionRequestRecord(
            deletion_id=deletion_id,
            tenant_id=context.tenant_id,
            source_id=source_id,
            request_digest=request_digest,
            status="requested",
            requested_by_principal_id=context.principal_id,
            audit_receipt_id=context.audit_receipt_id,
            completed_at=None,
        )
        self._session.add(request)
        self._session.flush()
        self._session.add(
            KnowledgeDeletionTombstoneRecord(
                tombstone_id=uuid.uuid4(),
                deletion_id=deletion_id,
                tenant_id=context.tenant_id,
                source_id=source_id,
                tombstone_digest=tombstone_digest,
                deletion_generation=1,
                audit_receipt_id=context.audit_receipt_id,
            )
        )
        for surface_name in SURFACES:
            self._session.add(
                KnowledgeDeletionSurfaceRecord(
                    surface_receipt_id=uuid.uuid4(),
                    deletion_id=deletion_id,
                    tenant_id=context.tenant_id,
                    source_id=source_id,
                    surface_name=surface_name,
                    status="pending",
                    attempt_count=0,
                    evidence_digest=None,
                    audit_receipt_id=context.audit_receipt_id,
                )
            )
        self._session.add(
            KnowledgeOutboxRecord(
                outbox_id=uuid.uuid4(),
                tenant_id=context.tenant_id,
                event_type="knowledge.deletion.requested",
                aggregate_type="deletion",
                aggregate_id=deletion_id,
                idempotency_key=f"knowledge-delete:{deletion_id}",
                payload_ref=f"knowledge-event://sha256/{tombstone_digest}",
                payload_digest=tombstone_digest,
                status="pending",
                attempt_count=0,
                max_attempts=5,
                available_at=func.statement_timestamp(),
                claim_token=None,
                claimed_by=None,
                claimed_until=None,
                last_error_code=None,
                audit_receipt_id=context.audit_receipt_id,
                delivered_at=None,
            )
        )
        self._session.flush()
        return KnowledgeDeletionTicket(
            deletion_id=deletion_id,
            tenant_id=context.tenant_id,
            source_id=source_id,
            request_digest=request_digest,
            tombstone_digest=tombstone_digest,
            status="requested",
        )

    def mark_surface_verified(
        self,
        *,
        context: KnowledgeDeletionContext,
        ticket: KnowledgeDeletionTicket,
        surface_name: str,
        evidence_digest: str,
    ) -> None:
        self._require_transaction()
        self._authorize(context, "knowledge.deletion.execute")
        self._validate_ticket_scope(context, ticket)
        if surface_name not in SURFACES or DIGEST_PATTERN.fullmatch(evidence_digest) is None:
            raise ValueError("knowledge deletion surface receipt is invalid")
        receipt = self._session.execute(
            select(KnowledgeDeletionSurfaceRecord)
            .where(
                KnowledgeDeletionSurfaceRecord.tenant_id == context.tenant_id,
                KnowledgeDeletionSurfaceRecord.deletion_id == ticket.deletion_id,
                KnowledgeDeletionSurfaceRecord.surface_name == surface_name,
            )
            .with_for_update()
        ).scalar_one_or_none()
        if receipt is None:
            raise KnowledgeDeletionNotFound()
        if receipt.status == "verified":
            if receipt.evidence_digest != evidence_digest:
                raise KnowledgeDeletionImmutableConflict()
            return
        receipt.status = "verified"
        receipt.attempt_count += 1
        receipt.evidence_digest = evidence_digest
        receipt.audit_receipt_id = context.audit_receipt_id
        receipt.updated_at = func.statement_timestamp()
        request = self._request_for_update(context, ticket.deletion_id)
        request.status = "verifying"
        self._session.flush()

    def authorize_execution(
        self,
        *,
        context: KnowledgeDeletionContext,
        ticket: KnowledgeDeletionTicket,
    ) -> None:
        self._authorize(context, "knowledge.deletion.execute")
        self._validate_ticket_scope(context, ticket)
        if not self.is_tombstoned(ticket):
            raise KnowledgeDeletionIncomplete()

    def complete(
        self,
        *,
        context: KnowledgeDeletionContext,
        ticket: KnowledgeDeletionTicket,
    ) -> KnowledgeDeletionTicket:
        self._require_transaction()
        self._authorize(context, "knowledge.deletion.execute")
        self._validate_ticket_scope(context, ticket)
        request = self._request_for_update(context, ticket.deletion_id)
        receipts = self._session.execute(
            select(KnowledgeDeletionSurfaceRecord).where(
                KnowledgeDeletionSurfaceRecord.tenant_id == context.tenant_id,
                KnowledgeDeletionSurfaceRecord.deletion_id == ticket.deletion_id,
            )
        ).scalars()
        states = {record.surface_name: record.status for record in receipts}
        if set(states) != set(SURFACES) or any(
            states[surface] != "verified" for surface in SURFACES
        ):
            raise KnowledgeDeletionIncomplete()
        source = self._session.execute(
            select(KnowledgeSourceRecord)
            .where(
                KnowledgeSourceRecord.tenant_id == context.tenant_id,
                KnowledgeSourceRecord.source_id == ticket.source_id,
            )
            .with_for_update()
        ).scalar_one_or_none()
        if source is None:
            raise KnowledgeDeletionNotFound()
        source.status = "deleted"
        source.audit_receipt_id = context.audit_receipt_id
        source.updated_at = func.statement_timestamp()
        request.status = "completed"
        request.completed_at = func.statement_timestamp()
        self._session.flush()
        return KnowledgeDeletionTicket(
            deletion_id=ticket.deletion_id,
            tenant_id=ticket.tenant_id,
            source_id=ticket.source_id,
            request_digest=ticket.request_digest,
            tombstone_digest=ticket.tombstone_digest,
            status="completed",
        )

    def is_tombstoned(self, ticket: KnowledgeDeletionTicket) -> bool:
        return (
            self._session.execute(
                select(KnowledgeDeletionTombstoneRecord.tombstone_id).where(
                    KnowledgeDeletionTombstoneRecord.tenant_id == ticket.tenant_id,
                    KnowledgeDeletionTombstoneRecord.source_id == ticket.source_id,
                    KnowledgeDeletionTombstoneRecord.deletion_id == ticket.deletion_id,
                    KnowledgeDeletionTombstoneRecord.tombstone_digest
                    == ticket.tombstone_digest,
                )
            ).scalar_one_or_none()
            is not None
        )

    def _ticket(self, deletion_id: uuid.UUID) -> KnowledgeDeletionTicket:
        request = self._session.execute(
            select(KnowledgeDeletionRequestRecord).where(
                KnowledgeDeletionRequestRecord.deletion_id == deletion_id
            )
        ).scalar_one_or_none()
        tombstone = self._session.execute(
            select(KnowledgeDeletionTombstoneRecord).where(
                KnowledgeDeletionTombstoneRecord.deletion_id == deletion_id
            )
        ).scalar_one_or_none()
        if request is None or tombstone is None:
            raise KnowledgeDeletionNotFound()
        return KnowledgeDeletionTicket(
            deletion_id=request.deletion_id,
            tenant_id=request.tenant_id,
            source_id=request.source_id,
            request_digest=request.request_digest,
            tombstone_digest=tombstone.tombstone_digest,
            status=request.status,
        )

    def _request_for_update(
        self, context: KnowledgeDeletionContext, deletion_id: uuid.UUID
    ) -> KnowledgeDeletionRequestRecord:
        request = self._session.execute(
            select(KnowledgeDeletionRequestRecord)
            .where(
                KnowledgeDeletionRequestRecord.tenant_id == context.tenant_id,
                KnowledgeDeletionRequestRecord.deletion_id == deletion_id,
            )
            .with_for_update()
        ).scalar_one_or_none()
        if request is None:
            raise KnowledgeDeletionNotFound()
        return request

    @staticmethod
    def _validate_ticket_scope(
        context: KnowledgeDeletionContext, ticket: KnowledgeDeletionTicket
    ) -> None:
        if ticket.tenant_id != context.tenant_id:
            raise KnowledgeDeletionDenied()


class KnowledgeDeletionCoordinator:
    def __init__(
        self,
        *,
        ledger: KnowledgeDeletionLedger,
        surfaces: Mapping[str, KnowledgeDeletionSurface],
    ) -> None:
        if set(surfaces) != set(SURFACES) or any(
            name != adapter.surface_name for name, adapter in surfaces.items()
        ):
            raise ValueError("all deletion surfaces must be registered exactly once")
        self._ledger = ledger
        self._surfaces = dict(surfaces)

    def propagate(
        self,
        *,
        context: KnowledgeDeletionContext,
        ticket: KnowledgeDeletionTicket,
    ) -> KnowledgeDeletionTicket:
        self._ledger.authorize_execution(context=context, ticket=ticket)
        for surface_name in SURFACES:
            adapter = self._surfaces[surface_name]
            evidence_digest = adapter.purge(ticket)
            if (
                DIGEST_PATTERN.fullmatch(evidence_digest) is None
                or adapter.is_readable(ticket)
            ):
                raise KnowledgeDeletionIncomplete()
            self._ledger.mark_surface_verified(
                context=context,
                ticket=ticket,
                surface_name=surface_name,
                evidence_digest=evidence_digest,
            )
        return self._ledger.complete(context=context, ticket=ticket)

    def verify_restore_does_not_resurrect(
        self,
        *,
        context: KnowledgeDeletionContext,
        ticket: KnowledgeDeletionTicket,
    ) -> None:
        self._ledger.authorize_execution(context=context, ticket=ticket)
        for surface_name in SURFACES:
            adapter = self._surfaces[surface_name]
            evidence_digest = adapter.reapply_tombstone_after_restore(ticket)
            if (
                DIGEST_PATTERN.fullmatch(evidence_digest) is None
                or adapter.is_readable(ticket)
            ):
                raise KnowledgeDeletionIncomplete()
