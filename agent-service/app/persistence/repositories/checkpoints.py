"""Fenced checkpoint metadata writes without checkpoint bodies or secrets."""

from __future__ import annotations

import re
import uuid

from sqlalchemy import func, select
from sqlalchemy.orm import Session

from app.persistence.models.jobs import CheckpointMetadataRecord, JobRecord
from app.persistence.repositories.jobs import JobsRepository
from app.persistence.repositories.runs import TransactionRequired


STATE_REF_PATTERN = re.compile(r"^checkpoint://sha256/([0-9a-f]{64})$")
PENDING_REF_PATTERN = re.compile(r"^pending://sha256/[0-9a-f]{64}$")
DIGEST_PATTERN = re.compile(r"^[0-9a-f]{64}$")


class CheckpointsRepository:
    """Persist only typed content references after validating the current fence."""

    def __init__(self, session: Session) -> None:
        self._session = session

    def _require_transaction(self) -> None:
        if not self._session.in_transaction():
            raise TransactionRequired()

    def save(
        self,
        *,
        tenant_id: str,
        run_id: uuid.UUID,
        job_id: uuid.UUID,
        holder_id: str,
        fencing_token: int,
        state_ref: str,
        state_digest: str,
        state_schema_digest: str,
        pending_writes_ref: str | None,
        audit_receipt_id: str,
        parent_checkpoint_id: uuid.UUID | None = None,
    ) -> CheckpointMetadataRecord:
        self._require_transaction()
        if (
            STATE_REF_PATTERN.fullmatch(state_ref) is None
            or DIGEST_PATTERN.fullmatch(state_digest) is None
            or DIGEST_PATTERN.fullmatch(state_schema_digest) is None
            or (pending_writes_ref is not None and PENDING_REF_PATTERN.fullmatch(pending_writes_ref) is None)
            or not audit_receipt_id
        ):
            raise ValueError("checkpoint metadata must contain only approved content references")
        JobsRepository(self._session).assert_fence(
            tenant_id=tenant_id,
            job_id=job_id,
            holder_id=holder_id,
            fencing_token=fencing_token,
        )
        job = self._session.execute(
            select(JobRecord)
            .where(
                JobRecord.job_id == job_id,
                JobRecord.tenant_id == tenant_id,
                JobRecord.run_id == run_id,
            )
            .with_for_update()
        ).scalar_one()
        next_seq = self._session.execute(
            select(func.coalesce(func.max(CheckpointMetadataRecord.checkpoint_seq), 0) + 1).where(
                CheckpointMetadataRecord.run_id == run_id,
                CheckpointMetadataRecord.tenant_id == tenant_id,
            )
        ).scalar_one()
        record = CheckpointMetadataRecord(
            checkpoint_id=uuid.uuid4(),
            parent_checkpoint_id=parent_checkpoint_id,
            job_id=job.job_id,
            run_id=run_id,
            tenant_id=tenant_id,
            checkpoint_seq=next_seq,
            fencing_token=fencing_token,
            state_ref=state_ref,
            state_digest=state_digest,
            state_schema_digest=state_schema_digest,
            pending_writes_ref=pending_writes_ref,
            audit_receipt_id=audit_receipt_id,
        )
        self._session.add(record)
        self._session.flush()
        return record

    def latest(
        self,
        *,
        tenant_id: str,
        run_id: uuid.UUID,
    ) -> CheckpointMetadataRecord | None:
        self._require_transaction()
        return self._session.execute(
            select(CheckpointMetadataRecord)
            .where(
                CheckpointMetadataRecord.run_id == run_id,
                CheckpointMetadataRecord.tenant_id == tenant_id,
            )
            .order_by(CheckpointMetadataRecord.checkpoint_seq.desc())
            .limit(1)
        ).scalar_one_or_none()
