"""PostgreSQL CAS adapter for one-use resume capabilities."""

from __future__ import annotations

from datetime import datetime
from uuid import UUID

from sqlalchemy import func, select, update
from sqlalchemy.orm import Session, sessionmaker

from app.auth.resume_token import ResumeCapabilityRecord
from app.persistence.models.runtime import ResumeCapabilityRow


class PostgresResumeCapabilityStore:
    def __init__(self, session_factory: sessionmaker[Session]) -> None:
        self._session_factory = session_factory

    @staticmethod
    def _set_tenant(session: Session, tenant_id: str) -> None:
        session.execute(select(func.set_config("app.tenant_id", tenant_id, True)))

    def insert(self, record: ResumeCapabilityRecord) -> None:
        with self._session_factory.begin() as session:
            self._set_tenant(session, record.tenant_id)
            session.add(
                ResumeCapabilityRow(
                    capability_id=record.capability_id,
                    token_hash=record.token_hash,
                    nonce=record.nonce,
                    tenant_id=record.tenant_id,
                    principal_id=record.principal_id,
                    run_id=record.run_id,
                    interrupt_id=record.interrupt_id,
                    command_hash=record.command_hash,
                    command_version=record.command_version,
                    issued_at=record.issued_at,
                    expires_at=record.expires_at,
                    consumed_at=record.consumed_at,
                )
            )

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
        with self._session_factory.begin() as session:
            self._set_tenant(session, tenant_id)
            row = session.execute(
                update(ResumeCapabilityRow)
                .where(
                    ResumeCapabilityRow.token_hash == token_hash,
                    ResumeCapabilityRow.tenant_id == tenant_id,
                    ResumeCapabilityRow.principal_id == principal_id,
                    ResumeCapabilityRow.run_id == run_id,
                    ResumeCapabilityRow.interrupt_id == interrupt_id,
                    ResumeCapabilityRow.command_hash == command_hash,
                    ResumeCapabilityRow.command_version == command_version,
                    ResumeCapabilityRow.consumed_at.is_(None),
                    ResumeCapabilityRow.expires_at > consumed_at,
                )
                .values(consumed_at=consumed_at)
                .returning(ResumeCapabilityRow)
            ).scalar_one_or_none()
            if row is None:
                return None
            return ResumeCapabilityRecord(
                capability_id=row.capability_id,
                token_hash=row.token_hash,
                nonce=row.nonce,
                tenant_id=row.tenant_id,
                principal_id=row.principal_id,
                run_id=row.run_id,
                interrupt_id=row.interrupt_id,
                command_hash=row.command_hash,
                command_version=row.command_version,
                issued_at=row.issued_at,
                expires_at=row.expires_at,
                consumed_at=row.consumed_at,
            )
