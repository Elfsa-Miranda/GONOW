"""Transactional approval, CAS, receipt, event, and outbox repository."""

from __future__ import annotations

import hashlib
import hmac
import re
import uuid
from collections.abc import Callable
from dataclasses import dataclass
from datetime import datetime
from typing import Any

from sqlalchemy import (
    BigInteger,
    Column,
    DateTime,
    MetaData,
    String,
    Table,
    and_,
    delete,
    func,
    insert,
    or_,
    select,
    update,
)
from sqlalchemy.dialects.postgresql import UUID
from sqlalchemy.orm import Session

from app.auth.context import RequestContext
from app.commands.itinerary_adopt import AdoptCandidateCommand, AdoptCandidateReceipt
from app.persistence.models.runtime import RUNTIME_SCHEMA, RunRecord
from app.persistence.repositories.events import EventsRepository
from app.persistence.repositories.outbox import OutboxRepository
from app.persistence.repositories.runs import TransactionRequired
from app.runtime.behavior_manifest import canonicalize_jcs


SHA256_PATTERN = re.compile(r"^[0-9a-f]{64}$")
ACTION = "itinerary.adopt"

_metadata = MetaData(schema=RUNTIME_SCHEMA)
DOMAIN_APPROVALS = Table(
    "domain_command_approvals",
    _metadata,
    Column("approval_id", UUID(as_uuid=True)),
    Column("tenant_id", String),
    Column("principal_id", String),
    Column("run_id", UUID(as_uuid=True)),
    Column("action", String),
    Column("target_itinerary_id", UUID(as_uuid=True)),
    Column("candidate_id", UUID(as_uuid=True)),
    Column("candidate_hash", String),
    Column("command_hash", String),
    Column("expected_version", BigInteger),
    Column("assurance", String),
    Column("nonce_hash", String),
    Column("status", String),
    Column("expires_at", DateTime(timezone=True)),
    Column("audit_receipt_id", String),
    Column("created_at", DateTime(timezone=True)),
    Column("consumed_at", DateTime(timezone=True)),
    Column("consumed_command_id", UUID(as_uuid=True)),
)
DOMAIN_RECEIPTS = Table(
    "domain_command_receipts",
    _metadata,
    Column("command_id", UUID(as_uuid=True)),
    Column("tenant_id", String),
    Column("principal_id", String),
    Column("run_id", UUID(as_uuid=True)),
    Column("action", String),
    Column("approval_id", UUID(as_uuid=True)),
    Column("candidate_id", UUID(as_uuid=True)),
    Column("candidate_hash", String),
    Column("command_hash", String),
    Column("target_itinerary_id", UUID(as_uuid=True)),
    Column("expected_version", BigInteger),
    Column("result_version", BigInteger),
    Column("event_id", UUID(as_uuid=True)),
    Column("outbox_id", UUID(as_uuid=True)),
    Column("audit_receipt_id", String),
    Column("created_at", DateTime(timezone=True)),
)


class DomainCommandRejected(RuntimeError):
    code = "domain_command.rejected"

    def __init__(self) -> None:
        super().__init__(self.code)


class ApprovalRejected(RuntimeError):
    code = "approval.rejected"

    def __init__(self) -> None:
        super().__init__(self.code)


class DomainCommandReplayConflict(RuntimeError):
    code = "domain_command.idempotency_conflict"

    def __init__(self) -> None:
        super().__init__(self.code)


class DomainCommandTargetContractInvalid(RuntimeError):
    code = "domain_command.target_contract_invalid"

    def __init__(self) -> None:
        super().__init__(self.code)


class DomainCommandStaleVersion(RuntimeError):
    code = "domain_command.stale_version"

    def __init__(self, *, current_version: int, snapshot_hash: str) -> None:
        self.current_version = current_version
        self.snapshot_hash = snapshot_hash
        super().__init__(self.code)


@dataclass(frozen=True, slots=True)
class ItineraryDomainTables:
    """Explicit adapter for the independently inventoried formal tables."""

    itineraries: Table
    activities: Table

    def validate(self) -> None:
        itinerary_columns = {
            "id",
            "tenant_id",
            "user_id",
            "title",
            "start_date",
            "end_date",
            "plan_data",
            "version",
            "candidate_hash",
            "updated_at",
        }
        activity_columns = {
            "id",
            "tenant_id",
            "itinerary_id",
            "position",
            "activity_data",
            "created_at",
        }
        if not itinerary_columns <= set(
            self.itineraries.c.keys()
        ) or not activity_columns <= set(self.activities.c.keys()):
            raise DomainCommandTargetContractInvalid()


def nonce_hash(nonce: str) -> str:
    return hashlib.sha256(nonce.encode("utf-8")).hexdigest()


def _snapshot_hash(value: Any) -> str:
    return hashlib.sha256(canonicalize_jcs(value)).hexdigest()


class DomainCommandRepository:
    """Execute one AdoptCandidate effect inside the caller-owned transaction."""

    def __init__(
        self, session: Session, *, domain_tables: ItineraryDomainTables
    ) -> None:
        self._session = session
        self._tables = domain_tables
        self._tables.validate()

    def _require_transaction(self) -> None:
        if not self._session.in_transaction():
            raise TransactionRequired()

    def grant_approval(
        self,
        *,
        approval_id: uuid.UUID,
        context: RequestContext,
        run_id: uuid.UUID,
        target_itinerary_id: uuid.UUID,
        candidate_id: uuid.UUID,
        candidate_hash: str,
        command_hash: str,
        expected_version: int,
        capability_nonce: str,
        expires_at: datetime,
        audit_receipt_id: str,
    ) -> None:
        """Persist a server-issued AAL2 grant; never serialize the nonce itself."""

        self._require_transaction()
        database_now = self._session.scalar(select(func.statement_timestamp()))
        if (
            not context.principal_id
            or not context.tenant_id
            or not audit_receipt_id
            or expected_version < 0
            or not 32 <= len(capability_nonce) <= 512
            or SHA256_PATTERN.fullmatch(candidate_hash) is None
            or SHA256_PATTERN.fullmatch(command_hash) is None
            or expires_at <= database_now
            or (expires_at - database_now).total_seconds() > 300
        ):
            raise ApprovalRejected()
        self._session.execute(
            insert(DOMAIN_APPROVALS).values(
                approval_id=approval_id,
                tenant_id=context.tenant_id,
                principal_id=context.principal_id,
                run_id=run_id,
                action=ACTION,
                target_itinerary_id=target_itinerary_id,
                candidate_id=candidate_id,
                candidate_hash=candidate_hash,
                command_hash=command_hash,
                expected_version=expected_version,
                assurance="aal2",
                nonce_hash=nonce_hash(capability_nonce),
                status="approved",
                expires_at=expires_at,
                audit_receipt_id=audit_receipt_id,
                consumed_at=None,
                consumed_command_id=None,
            )
        )
        self._session.flush()

    def adopt_candidate(
        self,
        *,
        context: RequestContext,
        command: AdoptCandidateCommand,
        candidate_hash: str,
        command_hash: str,
        candidate_snapshot: dict[str, object],
        activity_snapshots: tuple[dict[str, object], ...],
        commit_authorize: Callable[[], None],
    ) -> AdoptCandidateReceipt:
        self._require_transaction()
        if (
            SHA256_PATTERN.fullmatch(candidate_hash) is None
            or SHA256_PATTERN.fullmatch(command_hash) is None
            or len(activity_snapshots) == 0
        ):
            raise DomainCommandRejected()

        existing = self._find_receipt(context=context, command=command)
        if existing is not None:
            commit_authorize()
            return self._replay_receipt(
                existing,
                context=context,
                command=command,
                command_hash=command_hash,
            )

        approval = (
            self._session.execute(
                select(DOMAIN_APPROVALS)
                .where(
                    DOMAIN_APPROVALS.c.approval_id == command.approval_id,
                    DOMAIN_APPROVALS.c.tenant_id == context.tenant_id,
                )
                .with_for_update()
            )
            .mappings()
            .one_or_none()
        )
        if approval is None:
            raise ApprovalRejected()

        concurrent_receipt = self._find_receipt(context=context, command=command)
        if concurrent_receipt is not None:
            commit_authorize()
            return self._replay_receipt(
                concurrent_receipt,
                context=context,
                command=command,
                command_hash=command_hash,
            )

        database_now = self._session.scalar(select(func.statement_timestamp()))
        expected_approval = {
            "principal_id": context.principal_id,
            "run_id": command.run_id,
            "action": ACTION,
            "target_itinerary_id": command.target_itinerary_id,
            "candidate_id": command.candidate.candidate_id,
            "candidate_hash": candidate_hash,
            "command_hash": command_hash,
            "expected_version": command.expected_version,
            "assurance": "aal2",
            "status": "approved",
        }
        if any(approval[key] != value for key, value in expected_approval.items()):
            raise ApprovalRejected()
        if approval["expires_at"] <= database_now or not hmac.compare_digest(
            str(approval["nonce_hash"]), nonce_hash(command.capability_nonce)
        ):
            raise ApprovalRejected()

        run = self._session.execute(
            select(RunRecord)
            .where(
                RunRecord.run_id == command.run_id,
                RunRecord.tenant_id == context.tenant_id,
                RunRecord.principal_id == context.principal_id,
            )
            .with_for_update()
        ).scalar_one_or_none()
        if run is None:
            raise DomainCommandRejected()

        current = (
            self._session.execute(
                select(self._tables.itineraries)
                .where(
                    self._tables.itineraries.c.id == command.target_itinerary_id,
                    self._tables.itineraries.c.tenant_id == context.tenant_id,
                )
                .with_for_update()
            )
            .mappings()
            .one_or_none()
        )
        current_version = 0 if current is None else int(current["version"])
        if current_version != command.expected_version:
            raise DomainCommandStaleVersion(
                current_version=current_version,
                snapshot_hash=_snapshot_hash(
                    None if current is None else current["plan_data"]
                ),
            )
        if current is not None and current["user_id"] != context.principal_id:
            raise DomainCommandRejected()

        commit_authorize()
        consumed = self._session.execute(
            update(DOMAIN_APPROVALS)
            .where(
                DOMAIN_APPROVALS.c.approval_id == command.approval_id,
                DOMAIN_APPROVALS.c.tenant_id == context.tenant_id,
                DOMAIN_APPROVALS.c.status == "approved",
            )
            .values(
                status="consumed",
                consumed_at=func.statement_timestamp(),
                consumed_command_id=command.command_id,
            )
        )
        if consumed.rowcount != 1:
            raise ApprovalRejected()

        result_version = current_version + 1
        itinerary_values = {
            "tenant_id": context.tenant_id,
            "user_id": context.principal_id,
            "title": command.candidate.title,
            "start_date": command.candidate.starts_on,
            "end_date": command.candidate.ends_on,
            "plan_data": candidate_snapshot,
            "version": result_version,
            "candidate_hash": candidate_hash,
            "updated_at": func.statement_timestamp(),
        }
        if current is None:
            self._session.execute(
                insert(self._tables.itineraries).values(
                    id=command.target_itinerary_id,
                    **itinerary_values,
                )
            )
        else:
            cas = self._session.execute(
                update(self._tables.itineraries)
                .where(
                    self._tables.itineraries.c.id == command.target_itinerary_id,
                    self._tables.itineraries.c.tenant_id == context.tenant_id,
                    self._tables.itineraries.c.user_id == context.principal_id,
                    self._tables.itineraries.c.version == command.expected_version,
                )
                .values(**itinerary_values)
            )
            if cas.rowcount != 1:
                raise DomainCommandStaleVersion(
                    current_version=current_version,
                    snapshot_hash=_snapshot_hash(current["plan_data"]),
                )

        self._session.execute(
            delete(self._tables.activities).where(
                self._tables.activities.c.itinerary_id == command.target_itinerary_id,
                self._tables.activities.c.tenant_id == context.tenant_id,
            )
        )
        self._session.execute(
            insert(self._tables.activities),
            [
                {
                    "id": uuid.UUID(str(activity["activity_id"])),
                    "tenant_id": context.tenant_id,
                    "itinerary_id": command.target_itinerary_id,
                    "position": index,
                    "activity_data": activity,
                }
                for index, activity in enumerate(activity_snapshots)
            ],
        )

        audit_receipt_id = str(approval["audit_receipt_id"])
        event = EventsRepository(self._session).append(
            tenant_id=context.tenant_id,
            run_id=command.run_id,
            event_type="itinerary.adopted",
            payload={
                "command_id": str(command.command_id),
                "candidate_id": str(command.candidate.candidate_id),
                "itinerary_id": str(command.target_itinerary_id),
                "candidate_hash": candidate_hash,
                "result_version": result_version,
            },
            audit_receipt_id=audit_receipt_id,
        )
        outbox = OutboxRepository(self._session).enqueue_event(
            tenant_id=context.tenant_id,
            event_id=event.event_id,
            topic="itinerary.adopted",
            audit_receipt_id=audit_receipt_id,
        )
        self._session.execute(
            insert(DOMAIN_RECEIPTS).values(
                command_id=command.command_id,
                tenant_id=context.tenant_id,
                principal_id=context.principal_id,
                run_id=command.run_id,
                action=ACTION,
                approval_id=command.approval_id,
                candidate_id=command.candidate.candidate_id,
                candidate_hash=candidate_hash,
                command_hash=command_hash,
                target_itinerary_id=command.target_itinerary_id,
                expected_version=command.expected_version,
                result_version=result_version,
                event_id=event.event_id,
                outbox_id=outbox.outbox_id,
                audit_receipt_id=audit_receipt_id,
            )
        )
        self._session.flush()
        return AdoptCandidateReceipt(
            command_id=command.command_id,
            approval_id=command.approval_id,
            candidate_id=command.candidate.candidate_id,
            itinerary_id=command.target_itinerary_id,
            result_version=result_version,
            candidate_hash=candidate_hash,
            command_hash=command_hash,
            event_id=event.event_id,
            outbox_id=outbox.outbox_id,
            audit_receipt_id=audit_receipt_id,
            replayed=False,
        )

    def _find_receipt(
        self,
        *,
        context: RequestContext,
        command: AdoptCandidateCommand,
    ) -> Any | None:
        return (
            self._session.execute(
                select(DOMAIN_RECEIPTS).where(
                    or_(
                        DOMAIN_RECEIPTS.c.command_id == command.command_id,
                        and_(
                            DOMAIN_RECEIPTS.c.tenant_id == context.tenant_id,
                            DOMAIN_RECEIPTS.c.candidate_id
                            == command.candidate.candidate_id,
                            DOMAIN_RECEIPTS.c.approval_id == command.approval_id,
                        ),
                    )
                )
            )
            .mappings()
            .one_or_none()
        )

    @staticmethod
    def _replay_receipt(
        row: Any,
        *,
        context: RequestContext,
        command: AdoptCandidateCommand,
        command_hash: str,
    ) -> AdoptCandidateReceipt:
        if (
            row["tenant_id"] != context.tenant_id
            or row["principal_id"] != context.principal_id
            or row["candidate_id"] != command.candidate.candidate_id
            or row["approval_id"] != command.approval_id
        ):
            raise ApprovalRejected()
        if row["command_hash"] != command_hash:
            raise DomainCommandReplayConflict()
        return AdoptCandidateReceipt(
            command_id=row["command_id"],
            approval_id=row["approval_id"],
            candidate_id=row["candidate_id"],
            itinerary_id=row["target_itinerary_id"],
            result_version=int(row["result_version"]),
            candidate_hash=row["candidate_hash"],
            command_hash=row["command_hash"],
            event_id=row["event_id"],
            outbox_id=row["outbox_id"],
            audit_receipt_id=row["audit_receipt_id"],
            replayed=True,
        )
