"""Content-addressed structured Job input persistence."""

from __future__ import annotations

import re
import uuid
from datetime import datetime
from typing import Any

from sqlalchemy import select
from sqlalchemy.dialects.postgresql import insert
from sqlalchemy.orm import Session

from app.persistence.models.runtime import JobInputRecord
from app.persistence.repositories.runs import TransactionRequired


INPUT_REF_PATTERN = re.compile(r"^job-input://sha256/([0-9a-f]{64})$")


class JobInputConflict(RuntimeError):
    code = "job_input.conflict"

    def __init__(self) -> None:
        super().__init__(self.code)


class JobInputNotFound(RuntimeError):
    code = "job_input.not_found"

    def __init__(self) -> None:
        super().__init__(self.code)


class JobInputsRepository:
    def __init__(self, session: Session) -> None:
        self._session = session

    def _require_transaction(self) -> None:
        if not self._session.in_transaction():
            raise TransactionRequired()

    def put(
        self,
        *,
        tenant_id: str,
        input_ref: str,
        input_sha256: str,
        payload: dict[str, Any],
        expires_at: datetime,
    ) -> JobInputRecord:
        self._require_transaction()
        matched = INPUT_REF_PATTERN.fullmatch(input_ref)
        if (
            not tenant_id
            or matched is None
            or matched.group(1) != input_sha256
            or expires_at.tzinfo is None
            or expires_at.utcoffset() is None
        ):
            raise ValueError("job input identity is invalid")
        inserted = self._session.execute(
            insert(JobInputRecord)
            .values(
                input_id=uuid.uuid4(),
                tenant_id=tenant_id,
                input_ref=input_ref,
                input_sha256=input_sha256,
                schema_version="1.0",
                payload=payload,
                expires_at=expires_at,
            )
            .on_conflict_do_nothing(constraint="uq_job_inputs_tenant_ref")
            .returning(JobInputRecord)
        ).scalar_one_or_none()
        if inserted is not None:
            return inserted
        existing = self._session.execute(
            select(JobInputRecord).where(
                JobInputRecord.tenant_id == tenant_id,
                JobInputRecord.input_ref == input_ref,
            )
        ).scalar_one()
        if (
            existing.input_sha256 != input_sha256
            or existing.schema_version != "1.0"
            or existing.payload != payload
        ):
            raise JobInputConflict()
        return existing

    def load(self, *, tenant_id: str, input_ref: str) -> JobInputRecord:
        self._require_transaction()
        record = self._session.execute(
            select(JobInputRecord).where(
                JobInputRecord.tenant_id == tenant_id,
                JobInputRecord.input_ref == input_ref,
                JobInputRecord.deletion_requested_at.is_(None),
            )
        ).scalar_one_or_none()
        if record is None:
            raise JobInputNotFound()
        return record
