"""Fenced persistence and owner-scoped reads for typed itinerary Candidates."""

from __future__ import annotations

from dataclasses import dataclass
import hashlib
from uuid import UUID, uuid4

from sqlalchemy import select
from sqlalchemy.dialects.postgresql import insert
from sqlalchemy.orm import Session

from app.persistence.models.runtime import CandidateRecord, RunRecord
from app.persistence.repositories.jobs import JobsRepository
from app.persistence.repositories.runs import TransactionRequired
from app.runtime.behavior_manifest import canonicalize_jcs
from app.runtime.candidate import ItineraryCandidate


class CandidateConflict(RuntimeError):
    code = "candidate.conflict"

    def __init__(self) -> None:
        super().__init__(self.code)


class CandidateNotFound(RuntimeError):
    code = "candidate.not_found"

    def __init__(self) -> None:
        super().__init__(self.code)


@dataclass(frozen=True, slots=True)
class CandidatePersistenceResult:
    candidate_ref: str
    candidate_digest: str
    replayed: bool


class CandidatesRepository:
    def __init__(self, session: Session) -> None:
        self._session = session

    def _require_transaction(self) -> None:
        if not self._session.in_transaction():
            raise TransactionRequired()

    def persist_fenced(
        self,
        *,
        tenant_id: str,
        job_id: UUID,
        holder_id: str,
        fencing_token: int,
        candidate: ItineraryCandidate,
    ) -> CandidatePersistenceResult:
        self._require_transaction()
        JobsRepository(self._session).assert_fence(
            tenant_id=tenant_id,
            job_id=job_id,
            holder_id=holder_id,
            fencing_token=fencing_token,
        )
        try:
            run_id = UUID(candidate.run_id)
        except ValueError as error:
            raise CandidateConflict() from error
        payload = candidate.model_dump(mode="json")
        digest = hashlib.sha256(canonicalize_jcs(payload)).hexdigest()
        candidate_ref = f"candidate://sha256/{digest}"
        inserted = self._session.execute(
            insert(CandidateRecord)
            .values(
                candidate_record_id=uuid4(),
                candidate_id=candidate.candidate_id,
                candidate_ref=candidate_ref,
                candidate_digest=digest,
                tenant_id=tenant_id,
                run_id=run_id,
                source_job_id=job_id,
                fencing_token=fencing_token,
                behavior_digest=candidate.behavior_digest,
                input_digest=candidate.input_digest,
                schema_version=candidate.schema_version,
                payload=payload,
            )
            .on_conflict_do_nothing(constraint="uq_candidates_tenant_run")
            .returning(CandidateRecord.candidate_ref)
        ).scalar_one_or_none()
        if inserted is not None:
            return CandidatePersistenceResult(candidate_ref, digest, False)
        existing = self._session.execute(
            select(CandidateRecord).where(
                CandidateRecord.tenant_id == tenant_id,
                CandidateRecord.run_id == run_id,
            )
        ).scalar_one()
        if (
            existing.candidate_digest != digest
            or existing.candidate_id != candidate.candidate_id
            or existing.payload != payload
        ):
            raise CandidateConflict()
        return CandidatePersistenceResult(existing.candidate_ref, digest, True)

    def load_for_principal(
        self,
        *,
        tenant_id: str,
        principal_id: str,
        run_id: UUID,
    ) -> CandidateRecord:
        self._require_transaction()
        record = self._session.execute(
            select(CandidateRecord)
            .join(
                RunRecord,
                (RunRecord.run_id == CandidateRecord.run_id)
                & (RunRecord.tenant_id == CandidateRecord.tenant_id),
            )
            .where(
                CandidateRecord.tenant_id == tenant_id,
                CandidateRecord.run_id == run_id,
                CandidateRecord.deletion_requested_at.is_(None),
                RunRecord.principal_id == principal_id,
            )
        ).scalar_one_or_none()
        if record is None:
            raise CandidateNotFound()
        return record
