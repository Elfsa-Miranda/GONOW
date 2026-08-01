"""Transaction-bound durable Job and Lease metadata operations."""

from __future__ import annotations

import re
import uuid
from dataclasses import dataclass
from datetime import timedelta

from sqlalchemy import func, select, update
from sqlalchemy.orm import Session

from app.persistence.models.jobs import JobRecord, LeaseRecord
from app.persistence.repositories.runs import TransactionRequired


JOB_REF_PATTERN = re.compile(r"^job-input://sha256/[0-9a-f]{64}$")


@dataclass(frozen=True, slots=True)
class JobClaim:
    """A transactionally acquired Job and its durable fencing identity."""

    job_id: uuid.UUID
    run_id: uuid.UUID
    tenant_id: str
    job_type: str
    input_ref: str
    lease_id: uuid.UUID
    holder_id: str
    fencing_token: int
    attempt_count: int
    replayed: bool


class JobNotFound(RuntimeError):
    code = "job.not_found"

    def __init__(self) -> None:
        super().__init__(self.code)


class LeaseHeld(RuntimeError):
    code = "lease.held"

    def __init__(self) -> None:
        super().__init__(self.code)


class StaleFence(RuntimeError):
    code = "consistency.stale_fence"

    def __init__(self) -> None:
        super().__init__(self.code)


class JobAttemptsExhausted(RuntimeError):
    code = "job.attempts_exhausted"

    def __init__(self) -> None:
        super().__init__(self.code)


class JobsRepository:
    """Callers own commit/rollback; every mutation requires an active transaction."""

    def __init__(self, session: Session) -> None:
        self._session = session

    def _require_transaction(self) -> None:
        if not self._session.in_transaction():
            raise TransactionRequired()

    def create_job(
        self,
        *,
        tenant_id: str,
        run_id: uuid.UUID,
        job_type: str,
        input_ref: str,
        audit_receipt_id: str,
        max_attempts: int = 2,
        job_id: uuid.UUID | None = None,
    ) -> JobRecord:
        self._require_transaction()
        if not tenant_id or not job_type or not audit_receipt_id:
            raise ValueError("tenant, job type, and audit receipt are required")
        if JOB_REF_PATTERN.fullmatch(input_ref) is None:
            raise ValueError("input_ref must be a content-addressed internal reference")
        if max_attempts not in (1, 2):
            raise ValueError("max_attempts must be one or two")
        record = JobRecord(
            job_id=job_id or uuid.uuid4(),
            run_id=run_id,
            tenant_id=tenant_id,
            job_type=job_type,
            status="queued",
            input_ref=input_ref,
            current_fencing_token=0,
            attempt_count=0,
            max_attempts=max_attempts,
            audit_receipt_id=audit_receipt_id,
        )
        self._session.add(record)
        self._session.flush()
        return record

    def claim_next_job(
        self,
        *,
        tenant_id: str,
        holder_id: str,
        audit_receipt_id: str,
        lease_seconds: int,
    ) -> JobClaim | None:
        """Claim one ready Job without blocking concurrent claimers.

        ``holder_id`` is the durable identity of one physical claim attempt. A
        response-lost retry with the same holder replays its live lease and
        fencing token instead of consuming a second attempt or Job.
        """

        self._require_transaction()
        if not tenant_id or not holder_id or not audit_receipt_id:
            raise ValueError("tenant, holder, and audit receipt are required")
        if not 1 <= lease_seconds <= 300:
            raise ValueError("lease duration must be between one and 300 seconds")

        replay = self._session.execute(
            select(JobRecord, LeaseRecord)
            .join(
                LeaseRecord,
                (LeaseRecord.job_id == JobRecord.job_id)
                & (LeaseRecord.tenant_id == JobRecord.tenant_id),
            )
            .where(
                JobRecord.tenant_id == tenant_id,
                JobRecord.status == "leased",
                LeaseRecord.tenant_id == tenant_id,
                LeaseRecord.holder_id == holder_id,
                LeaseRecord.released_at.is_(None),
                LeaseRecord.expires_at > func.statement_timestamp(),
            )
            .order_by(LeaseRecord.acquired_at, LeaseRecord.lease_id)
            .with_for_update(skip_locked=True)
            .limit(1)
        ).one_or_none()
        if replay is not None:
            job, lease = replay
            return JobClaim(
                job_id=job.job_id,
                run_id=job.run_id,
                tenant_id=job.tenant_id,
                job_type=job.job_type,
                input_ref=job.input_ref,
                lease_id=lease.lease_id,
                holder_id=lease.holder_id,
                fencing_token=lease.fencing_token,
                attempt_count=job.attempt_count,
                replayed=True,
            )

        job = self._session.execute(
            select(JobRecord)
            .where(
                JobRecord.tenant_id == tenant_id,
                JobRecord.status == "queued",
                JobRecord.available_at <= func.statement_timestamp(),
                JobRecord.attempt_count < JobRecord.max_attempts,
            )
            .order_by(JobRecord.available_at, JobRecord.created_at, JobRecord.job_id)
            .with_for_update(skip_locked=True)
            .limit(1)
        ).scalar_one_or_none()
        if job is None:
            return None

        job.current_fencing_token += 1
        job.status = "leased"
        job.attempt_count += 1
        job.updated_at = func.statement_timestamp()
        self._session.flush()
        lease = LeaseRecord(
            lease_id=uuid.uuid4(),
            job_id=job.job_id,
            tenant_id=tenant_id,
            holder_id=holder_id,
            fencing_token=job.current_fencing_token,
            audit_receipt_id=audit_receipt_id,
            expires_at=func.statement_timestamp() + timedelta(seconds=lease_seconds),
        )
        self._session.add(lease)
        self._session.flush()
        return JobClaim(
            job_id=job.job_id,
            run_id=job.run_id,
            tenant_id=job.tenant_id,
            job_type=job.job_type,
            input_ref=job.input_ref,
            lease_id=lease.lease_id,
            holder_id=lease.holder_id,
            fencing_token=lease.fencing_token,
            attempt_count=job.attempt_count,
            replayed=False,
        )

    def reclaim_expired_job(
        self,
        *,
        tenant_id: str,
        holder_id: str,
        audit_receipt_id: str,
        lease_seconds: int,
    ) -> JobClaim | None:
        """Claim one expired Job with a strictly newer fencing token.

        The old lease is released through an expiry CAS before the Job token is
        advanced. A concurrent heartbeat therefore either wins and preserves
        the old owner, or loses and can never revive after the new lease exists.
        """

        self._require_transaction()
        if not tenant_id or not holder_id or not audit_receipt_id:
            raise ValueError("tenant, holder, and audit receipt are required")
        if not 1 <= lease_seconds <= 300:
            raise ValueError("lease duration must be between one and 300 seconds")

        expired = self._session.execute(
            select(JobRecord, LeaseRecord)
            .join(
                LeaseRecord,
                (LeaseRecord.job_id == JobRecord.job_id)
                & (LeaseRecord.tenant_id == JobRecord.tenant_id),
            )
            .where(
                JobRecord.tenant_id == tenant_id,
                JobRecord.status == "leased",
                JobRecord.attempt_count < JobRecord.max_attempts,
                LeaseRecord.tenant_id == tenant_id,
                LeaseRecord.released_at.is_(None),
                LeaseRecord.expires_at <= func.statement_timestamp(),
            )
            .order_by(LeaseRecord.expires_at, JobRecord.job_id)
            .with_for_update(of=JobRecord, skip_locked=True)
            .limit(1)
        ).one_or_none()
        if expired is None:
            return None
        job, old_lease = expired

        released_lease_id = self._session.execute(
            update(LeaseRecord)
            .where(
                LeaseRecord.lease_id == old_lease.lease_id,
                LeaseRecord.tenant_id == tenant_id,
                LeaseRecord.fencing_token == old_lease.fencing_token,
                LeaseRecord.released_at.is_(None),
                LeaseRecord.expires_at <= func.statement_timestamp(),
            )
            .values(released_at=func.statement_timestamp())
            .returning(LeaseRecord.lease_id)
        ).scalar_one_or_none()
        if released_lease_id is None:
            return None

        job.current_fencing_token += 1
        job.attempt_count += 1
        job.updated_at = func.statement_timestamp()
        self._session.flush()
        lease = LeaseRecord(
            lease_id=uuid.uuid4(),
            job_id=job.job_id,
            tenant_id=tenant_id,
            holder_id=holder_id,
            fencing_token=job.current_fencing_token,
            audit_receipt_id=audit_receipt_id,
            expires_at=func.statement_timestamp() + timedelta(seconds=lease_seconds),
        )
        self._session.add(lease)
        self._session.flush()
        return JobClaim(
            job_id=job.job_id,
            run_id=job.run_id,
            tenant_id=job.tenant_id,
            job_type=job.job_type,
            input_ref=job.input_ref,
            lease_id=lease.lease_id,
            holder_id=lease.holder_id,
            fencing_token=lease.fencing_token,
            attempt_count=job.attempt_count,
            replayed=False,
        )

    def renew_lease(
        self,
        *,
        tenant_id: str,
        job_id: uuid.UUID,
        holder_id: str,
        fencing_token: int,
        lease_seconds: int,
    ) -> LeaseRecord:
        """CAS-renew a live lease using only PostgreSQL time and fencing state."""

        self._require_transaction()
        if not tenant_id or not holder_id or fencing_token <= 0:
            raise ValueError("tenant, holder, and a positive fencing token are required")
        if not 1 <= lease_seconds <= 300:
            raise ValueError("lease duration must be between one and 300 seconds")
        current_job = select(JobRecord.job_id).where(
            JobRecord.job_id == job_id,
            JobRecord.tenant_id == tenant_id,
            JobRecord.current_fencing_token == fencing_token,
            JobRecord.status == "leased",
        )
        renewed = self._session.execute(
            update(LeaseRecord)
            .where(
                LeaseRecord.job_id == job_id,
                LeaseRecord.tenant_id == tenant_id,
                LeaseRecord.holder_id == holder_id,
                LeaseRecord.fencing_token == fencing_token,
                LeaseRecord.released_at.is_(None),
                LeaseRecord.expires_at > func.statement_timestamp(),
                current_job.exists(),
            )
            .values(
                heartbeat_at=func.statement_timestamp(),
                expires_at=func.statement_timestamp() + timedelta(seconds=lease_seconds),
            )
            .returning(LeaseRecord)
        ).scalar_one_or_none()
        if renewed is None:
            raise StaleFence()
        return renewed

    def acquire_lease(
        self,
        *,
        tenant_id: str,
        job_id: uuid.UUID,
        holder_id: str,
        audit_receipt_id: str,
        lease_seconds: int,
    ) -> LeaseRecord:
        self._require_transaction()
        if not holder_id or not audit_receipt_id or not 1 <= lease_seconds <= 300:
            raise ValueError("holder, audit receipt, and bounded lease duration are required")
        job = self._session.execute(
            select(JobRecord)
            .where(JobRecord.job_id == job_id, JobRecord.tenant_id == tenant_id)
            .with_for_update()
        ).scalar_one_or_none()
        if job is None:
            raise JobNotFound()
        if job.attempt_count >= job.max_attempts:
            raise JobAttemptsExhausted()
        active = self._session.execute(
            select(LeaseRecord)
            .where(
                LeaseRecord.job_id == job_id,
                LeaseRecord.tenant_id == tenant_id,
                LeaseRecord.released_at.is_(None),
            )
            .with_for_update()
        ).scalar_one_or_none()
        if active is not None:
            still_valid = self._session.execute(
                select(LeaseRecord.lease_id).where(
                    LeaseRecord.lease_id == active.lease_id,
                    LeaseRecord.expires_at > func.statement_timestamp(),
                )
            ).scalar_one_or_none()
            if still_valid is not None:
                raise LeaseHeld()
            active.released_at = func.statement_timestamp()
            self._session.flush()

        job.current_fencing_token += 1
        job.status = "leased"
        job.attempt_count += 1
        job.updated_at = func.statement_timestamp()
        self._session.flush()
        lease = LeaseRecord(
            lease_id=uuid.uuid4(),
            job_id=job.job_id,
            tenant_id=tenant_id,
            holder_id=holder_id,
            fencing_token=job.current_fencing_token,
            audit_receipt_id=audit_receipt_id,
            expires_at=func.statement_timestamp() + timedelta(seconds=lease_seconds),
        )
        self._session.add(lease)
        self._session.flush()
        return lease

    def assert_fence(
        self,
        *,
        tenant_id: str,
        job_id: uuid.UUID,
        holder_id: str,
        fencing_token: int,
    ) -> LeaseRecord:
        self._require_transaction()
        lease = self._session.execute(
            select(LeaseRecord)
            .join(
                JobRecord,
                (JobRecord.job_id == LeaseRecord.job_id)
                & (JobRecord.tenant_id == LeaseRecord.tenant_id),
            )
            .where(
                JobRecord.job_id == job_id,
                JobRecord.tenant_id == tenant_id,
                JobRecord.current_fencing_token == fencing_token,
                LeaseRecord.holder_id == holder_id,
                LeaseRecord.fencing_token == fencing_token,
                LeaseRecord.released_at.is_(None),
                LeaseRecord.expires_at > func.statement_timestamp(),
            )
        ).scalar_one_or_none()
        if lease is None:
            raise StaleFence()
        return lease

    def release_lease(
        self,
        *,
        tenant_id: str,
        job_id: uuid.UUID,
        holder_id: str,
        fencing_token: int,
    ) -> None:
        self._require_transaction()
        self.assert_fence(
            tenant_id=tenant_id,
            job_id=job_id,
            holder_id=holder_id,
            fencing_token=fencing_token,
        )
        changed = self._session.execute(
            update(LeaseRecord)
            .where(
                LeaseRecord.job_id == job_id,
                LeaseRecord.tenant_id == tenant_id,
                LeaseRecord.holder_id == holder_id,
                LeaseRecord.fencing_token == fencing_token,
                LeaseRecord.released_at.is_(None),
            )
            .values(released_at=func.statement_timestamp())
        ).rowcount
        if changed != 1:
            raise StaleFence()
