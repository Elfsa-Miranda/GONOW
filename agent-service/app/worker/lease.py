"""Transaction-owned lease heartbeat and recovery boundaries."""

from __future__ import annotations

import uuid

from sqlalchemy.orm import Session, sessionmaker

from app.persistence.models.jobs import LeaseRecord
from app.persistence.repositories.jobs import JobClaim, JobsRepository


class DurableLeaseCoordinator:
    """Perform one bounded lease action per PostgreSQL transaction."""

    def __init__(self, session_factory: sessionmaker[Session]) -> None:
        self._session_factory = session_factory

    def renew_once(
        self,
        *,
        tenant_id: str,
        job_id: uuid.UUID,
        holder_id: str,
        fencing_token: int,
        lease_seconds: int = 30,
    ) -> LeaseRecord:
        with self._session_factory.begin() as session:
            return JobsRepository(session).renew_lease(
                tenant_id=tenant_id,
                job_id=job_id,
                holder_id=holder_id,
                fencing_token=fencing_token,
                lease_seconds=lease_seconds,
            )

    def reclaim_once(
        self,
        *,
        tenant_id: str,
        holder_id: str,
        audit_receipt_id: str,
        lease_seconds: int = 30,
    ) -> JobClaim | None:
        with self._session_factory.begin() as session:
            return JobsRepository(session).reclaim_expired_job(
                tenant_id=tenant_id,
                holder_id=holder_id,
                audit_receipt_id=audit_receipt_id,
                lease_seconds=lease_seconds,
            )
