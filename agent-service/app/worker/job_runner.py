"""Durable PostgreSQL Job claim boundary for the Worker process."""

from __future__ import annotations

from dataclasses import dataclass
from enum import StrEnum

from sqlalchemy.orm import Session, sessionmaker

from app.persistence.repositories.jobs import JobClaim, JobsRepository


class ClaimState(StrEnum):
    CLAIMED = "claimed"
    REPLAYED = "replayed"
    EMPTY = "empty"


class ClaimRetryClass(StrEnum):
    NONE = "none"
    SAFE_POLL = "safe_poll"


@dataclass(frozen=True, slots=True)
class ClaimAttempt:
    state: ClaimState
    retry_class: ClaimRetryClass
    claim: JobClaim | None


class DurableJobRunner:
    """Own the transaction around exactly one durable claim attempt."""

    def __init__(self, session_factory: sessionmaker[Session]) -> None:
        self._session_factory = session_factory

    def claim_once(
        self,
        *,
        tenant_id: str,
        holder_id: str,
        audit_receipt_id: str,
        lease_seconds: int = 30,
    ) -> ClaimAttempt:
        with self._session_factory.begin() as session:
            claim = JobsRepository(session).claim_next_job(
                tenant_id=tenant_id,
                holder_id=holder_id,
                audit_receipt_id=audit_receipt_id,
                lease_seconds=lease_seconds,
            )
        if claim is None:
            return ClaimAttempt(
                state=ClaimState.EMPTY,
                retry_class=ClaimRetryClass.SAFE_POLL,
                claim=None,
            )
        return ClaimAttempt(
            state=ClaimState.REPLAYED if claim.replayed else ClaimState.CLAIMED,
            retry_class=ClaimRetryClass.NONE,
            claim=claim,
        )
