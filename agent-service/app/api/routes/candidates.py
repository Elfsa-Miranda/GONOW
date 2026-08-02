"""Owner-scoped retrieval of a durable typed itinerary Candidate."""

from __future__ import annotations

from uuid import UUID

from fastapi import APIRouter, HTTPException, Request
from fastapi.concurrency import run_in_threadpool
from sqlalchemy import func, select
from sqlalchemy.orm import Session, sessionmaker

from app.api.context_resolver import ContextResolver, resolve_request_context
from app.auth.context import AuthorizationForbidden, AuthorizationPolicy
from app.persistence.repositories.candidates import CandidateNotFound, CandidatesRepository
from app.runtime.candidate import ItineraryCandidate


class CandidateReadService:
    def __init__(self, session_factory: sessionmaker[Session]) -> None:
        self._session_factory = session_factory

    def load(self, *, tenant_id: str, principal_id: str, run_id: UUID) -> ItineraryCandidate:
        with self._session_factory.begin() as session:
            session.execute(select(func.set_config("app.tenant_id", tenant_id, True)))
            record = CandidatesRepository(session).load_for_principal(
                tenant_id=tenant_id,
                principal_id=principal_id,
                run_id=run_id,
            )
            return ItineraryCandidate.model_validate(record.payload)


def create_candidates_router(
    service: CandidateReadService,
    context_resolver: ContextResolver,
) -> APIRouter:
    router = APIRouter(prefix="/v1/runs", tags=["candidates"])
    policy = AuthorizationPolicy()

    @router.get("/{run_id}/candidate", response_model=ItineraryCandidate)
    async def get_candidate(run_id: UUID, request: Request) -> ItineraryCandidate:
        context = await resolve_request_context(context_resolver, request)
        policy.authorize(
            context,
            action="candidate.read",
            resource_tenant_id=context.tenant_id,
        )
        try:
            return await run_in_threadpool(
                service.load,
                tenant_id=context.tenant_id,
                principal_id=context.principal_id,
                run_id=run_id,
            )
        except CandidateNotFound as error:
            raise HTTPException(status_code=403, detail=AuthorizationForbidden.code) from error

    return router
