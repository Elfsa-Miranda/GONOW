"""Atomic persistence for the one selected Basic Info Domain Command.

The business table is an explicit composition input. This module never
reflects, creates, or assumes a production ``user_itineraries`` schema.
"""

from __future__ import annotations

import hashlib
import uuid
from collections.abc import Callable
from dataclasses import dataclass
from datetime import UTC, datetime, timedelta
from typing import Any

from sqlalchemy import (
    BigInteger,
    Column,
    Date,
    DateTime,
    MetaData,
    Numeric,
    String,
    Table,
    and_,
    func,
    insert,
    or_,
    select,
    update,
)
from sqlalchemy.dialects.postgresql import JSONB, UUID
from sqlalchemy.orm import Session, sessionmaker

from app.auth.context import RequestContext
from app.commands.itinerary_basic_info import (
    COMMAND_TYPE,
    LOW_RISK_POLICY_REFERENCE,
    CommandOutcome,
    ItineraryBasicInfoReceipt,
    UpdateItineraryBasicInfoCommand,
    authorize_basic_info_update,
    policy_digest,
    principal_digest,
    schema_digest,
    scoped_idempotency_digest,
    semantic_command_hash,
    target_digest,
)
from app.runtime.behavior_manifest import canonicalize_jcs


COMMAND_SCHEMA = "domain_command"
REQUIRED_BUSINESS_COLUMNS = frozenset(
    {
        "id",
        "tenant_id",
        "user_id",
        "title",
        "destination_city",
        "start_date",
        "end_date",
        "budget",
        "actual_cost",
        "tags",
        "version",
        "updated_at",
    }
)
FaultInjector = Callable[[str], None]

_metadata = MetaData(schema=COMMAND_SCHEMA)
ATTEMPTS = Table(
    "itinerary_basic_info_attempts",
    _metadata,
    Column("attempt_id", UUID(as_uuid=True)),
    Column("tenant_id", String),
    Column("command_id", UUID(as_uuid=True)),
    Column("command_type", String),
    Column("target_itinerary_id", UUID(as_uuid=True)),
    Column("target_digest", String),
    Column("principal_digest", String),
    Column("idempotency_digest", String),
    Column("command_hash", String),
    Column("policy_digest", String),
    Column("schema_digest", String),
    Column("expected_version", BigInteger),
    Column("state", String),
    Column("actual_version", BigInteger),
    Column("event_id", UUID(as_uuid=True)),
    Column("outbox_id", UUID(as_uuid=True)),
    Column("created_at", DateTime(timezone=True)),
    Column("resolved_at", DateTime(timezone=True)),
)
OUTBOX = Table(
    "itinerary_basic_info_outbox",
    _metadata,
    Column("outbox_id", UUID(as_uuid=True)),
    Column("tenant_id", String),
    Column("attempt_id", UUID(as_uuid=True)),
    Column("event_id", UUID(as_uuid=True)),
    Column("event_type", String),
    Column("target_digest", String),
    Column("payload_ref", String),
    Column("payload_digest", String),
    Column("state", String),
    Column("attempt_count", BigInteger),
    Column("max_attempts", BigInteger),
    Column("available_at", DateTime(timezone=True)),
    Column("claim_token", UUID(as_uuid=True)),
    Column("claimed_by", String),
    Column("claimed_until", DateTime(timezone=True)),
    Column("last_error_code", String),
    Column("created_at", DateTime(timezone=True)),
    Column("delivered_at", DateTime(timezone=True)),
)
RECEIPTS = Table(
    "itinerary_basic_info_receipts",
    _metadata,
    Column("receipt_id", UUID(as_uuid=True)),
    Column("tenant_id", String),
    Column("attempt_id", UUID(as_uuid=True)),
    Column("command_id", UUID(as_uuid=True)),
    Column("command_type", String),
    Column("state", String),
    Column("target_digest", String),
    Column("principal_digest", String),
    Column("idempotency_digest", String),
    Column("command_hash", String),
    Column("policy_digest", String),
    Column("schema_digest", String),
    Column("approval_reference", String),
    Column("expected_version", BigInteger),
    Column("actual_version", BigInteger),
    Column("event_id", UUID(as_uuid=True)),
    Column("outbox_id", UUID(as_uuid=True)),
    Column("recorded_at", DateTime(timezone=True)),
)


class DomainCommandPersistenceError(RuntimeError):
    code = "service.unavailable"

    def __init__(self) -> None:
        super().__init__(self.code)


class DomainCommandTargetDenied(RuntimeError):
    code = "auth.forbidden"

    def __init__(self) -> None:
        super().__init__(self.code)


class DomainCommandIdempotencyConflict(RuntimeError):
    code = "idempotency.conflict"

    def __init__(self) -> None:
        super().__init__(self.code)


class DomainCommandReceiptNotFound(RuntimeError):
    code = "domain_command.receipt_not_found"

    def __init__(self) -> None:
        super().__init__(self.code)


class BusinessTableContractInvalid(RuntimeError):
    code = "service.unavailable"

    def __init__(self) -> None:
        super().__init__(self.code)


@dataclass(frozen=True, slots=True)
class ItineraryBasicInfoOutboxClaim:
    outbox_id: uuid.UUID
    event_id: uuid.UUID
    tenant_id: str
    target_digest: str
    payload_ref: str
    payload_digest: str
    claim_token: uuid.UUID
    claimed_until: datetime
    attempt_count: int


def isolated_business_projection(metadata: MetaData, *, schema: str) -> Table:
    """Build the test-only projection; callers must create it explicitly."""

    return Table(
        "user_itineraries_projection",
        metadata,
        Column("id", UUID(as_uuid=True), primary_key=True),
        Column("tenant_id", String(128), nullable=False),
        Column("user_id", String(256), nullable=False),
        Column("title", String(160), nullable=False),
        Column("destination_city", String(160), nullable=False),
        Column("start_date", Date, nullable=False),
        Column("end_date", Date, nullable=False),
        Column("budget", Numeric(12, 2), nullable=False),
        Column("actual_cost", Numeric(12, 2), nullable=False),
        Column("tags", JSONB, nullable=False),
        Column("version", BigInteger, nullable=False),
        Column("updated_at", DateTime(timezone=True), nullable=False),
        schema=schema,
    )


def _validate_business_table(table: Table) -> None:
    if set(table.c.keys()) != REQUIRED_BUSINESS_COLUMNS or not table.schema:
        raise BusinessTableContractInvalid()


def _sha256(value: object) -> str:
    return hashlib.sha256(canonicalize_jcs(value)).hexdigest()


def _inject(injector: FaultInjector | None, stage: str) -> None:
    if injector is not None:
        injector(stage)


class ItineraryBasicInfoCommandRepository:
    """Execute the command inside the caller-owned database transaction."""

    def __init__(self, session: Session, *, business_table: Table) -> None:
        if not session.in_transaction():
            raise DomainCommandPersistenceError()
        _validate_business_table(business_table)
        self._session = session
        self._business = business_table

    def execute(
        self,
        *,
        context: RequestContext,
        command: UpdateItineraryBasicInfoCommand,
        fault_injector: FaultInjector | None = None,
    ) -> ItineraryBasicInfoReceipt:
        self._set_tenant(context.tenant_id)
        command_digest = semantic_command_hash(command)
        idempotency_digest = scoped_idempotency_digest(context, command)
        existing = self._find_receipt(
            command_id=command.command_id,
            idempotency_digest=idempotency_digest,
        )
        if existing is not None:
            return self._replay(
                existing,
                context=context,
                command=command,
                command_digest=command_digest,
                idempotency_digest=idempotency_digest,
            )

        authorize_basic_info_update(context, resource_tenant_id=context.tenant_id)
        _inject(fault_injector, "after_authorization_before_attempt")
        now = datetime.now(UTC)
        attempt_id = uuid.uuid4()
        digests = {
            "target_digest": target_digest(context, command),
            "principal_digest": principal_digest(context),
            "idempotency_digest": idempotency_digest,
            "command_hash": command_digest,
            "policy_digest": policy_digest(),
            "schema_digest": schema_digest(),
        }
        self._session.execute(
            insert(ATTEMPTS).values(
                attempt_id=attempt_id,
                tenant_id=context.tenant_id,
                command_id=command.command_id,
                command_type=COMMAND_TYPE,
                target_itinerary_id=command.target_itinerary_id,
                **digests,
                expected_version=command.expected_version,
                state="received",
            )
        )

        current = (
            self._session.execute(
                select(self._business)
                .where(
                    self._business.c.id == command.target_itinerary_id,
                    self._business.c.tenant_id == context.tenant_id,
                    self._business.c.user_id == context.principal_id,
                )
                .with_for_update()
            )
            .mappings()
            .one_or_none()
        )
        if current is None:
            return self._persist_noncommitted(
                context=context,
                command=command,
                attempt_id=attempt_id,
                digests=digests,
                outcome=CommandOutcome.DENIED,
                now=now,
            )
        if int(current["version"]) != command.expected_version:
            return self._persist_noncommitted(
                context=context,
                command=command,
                attempt_id=attempt_id,
                digests=digests,
                outcome=CommandOutcome.CONFLICT,
                now=now,
            )

        _inject(fault_injector, "after_authorization_before_business_mutation")
        actual_version = command.expected_version + 1
        snapshot = command.patch.legacy_compatible_snapshot()
        mutation = self._session.execute(
            update(self._business)
            .where(
                self._business.c.id == command.target_itinerary_id,
                self._business.c.tenant_id == context.tenant_id,
                self._business.c.user_id == context.principal_id,
                self._business.c.version == command.expected_version,
            )
            .values(
                title=snapshot["title"],
                destination_city=snapshot["destination_city"],
                start_date=command.patch.start_date,
                end_date=command.patch.end_date,
                budget=command.patch.budget,
                actual_cost=command.patch.actual_cost,
                tags=list(command.patch.tags),
                version=actual_version,
                updated_at=now,
            )
        )
        if mutation.rowcount != 1:
            raise DomainCommandPersistenceError()
        _inject(fault_injector, "after_business_mutation_before_outbox")

        event_id = uuid.uuid4()
        outbox_id = uuid.uuid4()
        event_metadata = {
            "event_type": "itinerary.basic_info.updated",
            "command_id": str(command.command_id),
            "target_digest": digests["target_digest"],
            "receipt_lookup_digest": idempotency_digest,
            "result_version": actual_version,
        }
        payload_digest = _sha256(event_metadata)
        self._session.execute(
            insert(OUTBOX).values(
                outbox_id=outbox_id,
                tenant_id=context.tenant_id,
                attempt_id=attempt_id,
                event_id=event_id,
                event_type="itinerary.basic_info.updated",
                target_digest=digests["target_digest"],
                payload_ref=f"domain-command-event://sha256/{payload_digest}",
                payload_digest=payload_digest,
                state="pending",
                attempt_count=0,
                max_attempts=5,
                available_at=now,
            )
        )
        _inject(fault_injector, "after_outbox_before_receipt")
        self._session.execute(
            update(ATTEMPTS)
            .where(
                ATTEMPTS.c.attempt_id == attempt_id,
                ATTEMPTS.c.tenant_id == context.tenant_id,
                ATTEMPTS.c.state == "received",
            )
            .values(
                state=CommandOutcome.COMMITTED.value,
                actual_version=actual_version,
                event_id=event_id,
                outbox_id=outbox_id,
                resolved_at=now,
            )
        )
        receipt = self._insert_receipt(
            context=context,
            command=command,
            attempt_id=attempt_id,
            digests=digests,
            outcome=CommandOutcome.COMMITTED,
            now=now,
            actual_version=actual_version,
            event_id=event_id,
            outbox_id=outbox_id,
        )
        _inject(fault_injector, "after_receipt_before_commit")
        self._session.flush()
        return receipt

    def lookup(
        self,
        *,
        context: RequestContext,
        target_itinerary_id: uuid.UUID,
        idempotency_key: str,
    ) -> ItineraryBasicInfoReceipt | None:
        self._set_tenant(context.tenant_id)
        synthetic = UpdateItineraryBasicInfoCommand.model_construct(
            schema_version="1.0",
            command_id=uuid.UUID(int=0),
            idempotency_key=idempotency_key,
            target_itinerary_id=target_itinerary_id,
            expected_version=0,
            patch=None,
        )
        digest = scoped_idempotency_digest(context, synthetic)
        row = self._session.execute(
            select(RECEIPTS).where(
                RECEIPTS.c.tenant_id == context.tenant_id,
                RECEIPTS.c.idempotency_digest == digest,
            )
        ).mappings().one_or_none()
        return None if row is None else self._receipt_from_row(row, replayed=True)

    def _set_tenant(self, tenant_id: str) -> None:
        self._session.execute(select(func.set_config("app.tenant_id", tenant_id, True)))

    def _find_receipt(
        self, *, command_id: uuid.UUID, idempotency_digest: str
    ) -> Any | None:
        return self._session.execute(
            select(RECEIPTS).where(
                or_(
                    RECEIPTS.c.command_id == command_id,
                    RECEIPTS.c.idempotency_digest == idempotency_digest,
                )
            )
        ).mappings().one_or_none()

    def _replay(
        self,
        row: Any,
        *,
        context: RequestContext,
        command: UpdateItineraryBasicInfoCommand,
        command_digest: str,
        idempotency_digest: str,
    ) -> ItineraryBasicInfoReceipt:
        if (
            row["tenant_id"] != context.tenant_id
            or row["principal_digest"] != principal_digest(context)
            or row["target_digest"] != target_digest(context, command)
            or row["idempotency_digest"] != idempotency_digest
            or row["command_hash"] != command_digest
        ):
            raise DomainCommandIdempotencyConflict()
        return self._receipt_from_row(row, replayed=True)

    def _persist_noncommitted(
        self,
        *,
        context: RequestContext,
        command: UpdateItineraryBasicInfoCommand,
        attempt_id: uuid.UUID,
        digests: dict[str, str],
        outcome: CommandOutcome,
        now: datetime,
    ) -> ItineraryBasicInfoReceipt:
        changed = self._session.execute(
            update(ATTEMPTS)
            .where(
                ATTEMPTS.c.attempt_id == attempt_id,
                ATTEMPTS.c.tenant_id == context.tenant_id,
                ATTEMPTS.c.state == "received",
            )
            .values(state=outcome.value, resolved_at=now)
        )
        if changed.rowcount != 1:
            raise DomainCommandPersistenceError()
        return self._insert_receipt(
            context=context,
            command=command,
            attempt_id=attempt_id,
            digests=digests,
            outcome=outcome,
            now=now,
        )

    def _insert_receipt(
        self,
        *,
        context: RequestContext,
        command: UpdateItineraryBasicInfoCommand,
        attempt_id: uuid.UUID,
        digests: dict[str, str],
        outcome: CommandOutcome,
        now: datetime,
        actual_version: int | None = None,
        event_id: uuid.UUID | None = None,
        outbox_id: uuid.UUID | None = None,
    ) -> ItineraryBasicInfoReceipt:
        receipt_id = uuid.uuid4()
        self._session.execute(
            insert(RECEIPTS).values(
                receipt_id=receipt_id,
                tenant_id=context.tenant_id,
                attempt_id=attempt_id,
                command_id=command.command_id,
                command_type=COMMAND_TYPE,
                state=outcome.value,
                **digests,
                approval_reference=LOW_RISK_POLICY_REFERENCE,
                expected_version=command.expected_version,
                actual_version=actual_version,
                event_id=event_id,
                outbox_id=outbox_id,
                recorded_at=now,
            )
        )
        return ItineraryBasicInfoReceipt(
            schema_version="1.0",
            command_type=COMMAND_TYPE,
            command_id=command.command_id,
            state=outcome,
            **digests,
            approval_reference=LOW_RISK_POLICY_REFERENCE,
            expected_version=command.expected_version,
            actual_version=actual_version,
            event_id=event_id,
            outbox_id=outbox_id,
            recorded_at=now,
            replayed=False,
        )

    @staticmethod
    def _receipt_from_row(row: Any, *, replayed: bool) -> ItineraryBasicInfoReceipt:
        return ItineraryBasicInfoReceipt(
            schema_version="1.0",
            command_type=COMMAND_TYPE,
            command_id=row["command_id"],
            state=CommandOutcome(row["state"]),
            target_digest=row["target_digest"],
            principal_digest=row["principal_digest"],
            idempotency_digest=row["idempotency_digest"],
            command_hash=row["command_hash"],
            approval_reference=row["approval_reference"],
            expected_version=int(row["expected_version"]),
            actual_version=None
            if row["actual_version"] is None
            else int(row["actual_version"]),
            event_id=row["event_id"],
            outbox_id=row["outbox_id"],
            policy_digest=row["policy_digest"],
            schema_digest=row["schema_digest"],
            recorded_at=row["recorded_at"],
            replayed=replayed,
        )


class ItineraryBasicInfoCommandService:
    """Own one transaction per command and expose receipt-safe replay."""

    def __init__(
        self,
        session_factory: sessionmaker[Session],
        *,
        business_table: Table,
        fault_injector: FaultInjector | None = None,
    ) -> None:
        _validate_business_table(business_table)
        self._session_factory = session_factory
        self._business_table = business_table
        self._fault_injector = fault_injector

    def execute(
        self,
        *,
        context: RequestContext,
        command: UpdateItineraryBasicInfoCommand,
    ) -> ItineraryBasicInfoReceipt:
        with self._session_factory.begin() as session:
            receipt = ItineraryBasicInfoCommandRepository(
                session, business_table=self._business_table
            ).execute(
                context=context,
                command=command,
                fault_injector=self._fault_injector,
            )
        _inject(self._fault_injector, "after_commit_before_response")
        return receipt

    def lookup(
        self,
        *,
        context: RequestContext,
        target_itinerary_id: uuid.UUID,
        idempotency_key: str,
    ) -> ItineraryBasicInfoReceipt | None:
        with self._session_factory.begin() as session:
            return ItineraryBasicInfoCommandRepository(
                session, business_table=self._business_table
            ).lookup(
                context=context,
                target_itinerary_id=target_itinerary_id,
                idempotency_key=idempotency_key,
            )


class ItineraryBasicInfoOutboxRepository:
    """Tenant-scoped relay claims with compare-and-swap fencing tokens."""

    def __init__(self, session: Session) -> None:
        if not session.in_transaction():
            raise DomainCommandPersistenceError()
        self._session = session

    def claim_one(
        self,
        *,
        tenant_id: str,
        dispatcher_id: str,
        lease_seconds: int,
    ) -> ItineraryBasicInfoOutboxClaim | None:
        if not dispatcher_id or len(dispatcher_id) > 128 or not 1 <= lease_seconds <= 300:
            raise ValueError("domain_command.outbox_claim_invalid")
        self._session.execute(select(func.set_config("app.tenant_id", tenant_id, True)))
        database_now = self._session.scalar(select(func.statement_timestamp()))
        if not isinstance(database_now, datetime):
            raise DomainCommandPersistenceError()
        row = (
            self._session.execute(
                select(OUTBOX)
                .where(
                    OUTBOX.c.tenant_id == tenant_id,
                    or_(
                        and_(
                            OUTBOX.c.state == "pending",
                            OUTBOX.c.available_at <= database_now,
                        ),
                        and_(
                            OUTBOX.c.state == "claimed",
                            OUTBOX.c.claimed_until < database_now,
                        ),
                    ),
                )
                .order_by(OUTBOX.c.available_at, OUTBOX.c.created_at)
                .limit(1)
                .with_for_update(skip_locked=True)
            )
            .mappings()
            .one_or_none()
        )
        if row is None:
            return None
        claim_token = uuid.uuid4()
        claimed_until = database_now + timedelta(seconds=lease_seconds)
        attempt_count = int(row["attempt_count"]) + 1
        changed = self._session.execute(
            update(OUTBOX)
            .where(
                OUTBOX.c.outbox_id == row["outbox_id"],
                OUTBOX.c.tenant_id == tenant_id,
                OUTBOX.c.state == row["state"],
                OUTBOX.c.attempt_count == row["attempt_count"],
            )
            .values(
                state="claimed",
                attempt_count=attempt_count,
                claim_token=claim_token,
                claimed_by=dispatcher_id,
                claimed_until=claimed_until,
                last_error_code=None,
            )
        )
        if changed.rowcount != 1:
            raise DomainCommandPersistenceError()
        return ItineraryBasicInfoOutboxClaim(
            outbox_id=row["outbox_id"],
            event_id=row["event_id"],
            tenant_id=tenant_id,
            target_digest=row["target_digest"],
            payload_ref=row["payload_ref"],
            payload_digest=row["payload_digest"],
            claim_token=claim_token,
            claimed_until=claimed_until,
            attempt_count=attempt_count,
        )

    def mark_delivered(
        self,
        *,
        tenant_id: str,
        outbox_id: uuid.UUID,
        claim_token: uuid.UUID,
    ) -> bool:
        self._session.execute(select(func.set_config("app.tenant_id", tenant_id, True)))
        database_now = self._session.scalar(select(func.statement_timestamp()))
        changed = self._session.execute(
            update(OUTBOX)
            .where(
                OUTBOX.c.outbox_id == outbox_id,
                OUTBOX.c.tenant_id == tenant_id,
                OUTBOX.c.state == "claimed",
                OUTBOX.c.claim_token == claim_token,
                OUTBOX.c.claimed_until >= database_now,
            )
            .values(
                state="delivered",
                claim_token=None,
                claimed_by=None,
                claimed_until=None,
                delivered_at=database_now,
            )
        )
        return changed.rowcount == 1
