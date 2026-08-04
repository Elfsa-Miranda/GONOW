"""Fail-closed production composition for the independently deployed API."""

from __future__ import annotations

import asyncio
from datetime import UTC, datetime
import hashlib
import os
from pathlib import Path
import re
from typing import Any
from uuid import UUID

import httpx
from fastapi import Request
from sqlalchemy import create_engine, event, select, text
from sqlalchemy.engine import Engine, make_url
from sqlalchemy.orm import Session, sessionmaker

from app.api.health import DependencySnapshot, HealthService
from app.api.main import ApiDependencies, SPECIFICATION_PATH
from app.api.middleware.auth import AuthMiddleware
from app.api.routes.candidates import CandidateReadService
from app.api.routes.contracts import SchemaRegistry
from app.auth.context import RequestContext
from app.auth.jwt import AuthVerifier, HttpJwksProvider, JwksCache
from app.auth.resume_token import ResumeCapabilityService
from app.persistence.repositories.behavior import BehaviorRepository
from app.persistence.repositories.resume_capabilities import PostgresResumeCapabilityStore
from app.runtime.behavior_manifest import digest_behavior_manifest, parse_manifest_json
from app.runtime.behavior_package import BehaviorPackageResolver, RunBehaviorPin
from app.runtime.cancellation import CancellationService
from app.runtime.event_writer import EventWriter
from app.runtime.resume import ResumeTransitionService
from app.runtime.run_start import RunStartService


SHA256_PATTERN = re.compile(r"^[0-9a-f]{64}$")
BEHAVIOR_KEY_PATTERN = re.compile(r"^[a-z][a-z0-9_.-]{0,126}$")
ENVIRONMENT_PATTERN = re.compile(r"^[a-z][a-z0-9-]{0,62}$")


class ApiCompositionError(RuntimeError):
    code = "service.unavailable"

    def __init__(self) -> None:
        super().__init__(self.code)


class _UnavailableCommandService:
    """Fail closed until an explicit, reviewed business-table adapter is supplied."""

    def execute(self, **_: Any) -> Any:
        raise ApiCompositionError()

    def lookup(self, **_: Any) -> Any:
        raise ApiCompositionError()


class ApiDatabaseSession(Session):
    pass


@event.listens_for(ApiDatabaseSession, "after_begin")
def _api_role(session: Session, transaction: Any, connection: Any) -> None:
    del session, transaction
    connection.exec_driver_sql("SET LOCAL ROLE gonow_agent_api")


def _required_environment(name: str) -> str:
    value = os.environ.get(name, "").strip()
    if not value:
        raise ApiCompositionError()
    return value


class ImmutableManifestFileStore:
    """Read one explicitly hashed manifest; never infer or rewrite its identity."""

    def __init__(self, path: Path, expected_sha256: str) -> None:
        if not path.is_absolute() or SHA256_PATTERN.fullmatch(expected_sha256) is None:
            raise ApiCompositionError()
        self._path = path
        self._expected_sha256 = expected_sha256

    def load(self, package_digest: str) -> dict[str, object]:
        try:
            raw = self._path.read_bytes()
            if hashlib.sha256(raw).hexdigest() != self._expected_sha256:
                raise ApiCompositionError()
            manifest = parse_manifest_json(raw.decode("utf-8"))
            if digest_behavior_manifest(manifest).sha256 != package_digest:
                raise ApiCompositionError()
            return manifest
        except ApiCompositionError:
            raise
        except Exception as error:
            raise ApiCompositionError() from error


class DatabaseBehaviorPinProvider:
    def __init__(
        self,
        session_factory: sessionmaker[Session],
        *,
        manifests: ImmutableManifestFileStore,
        behavior_key: str,
        environment: str,
    ) -> None:
        if (
            BEHAVIOR_KEY_PATTERN.fullmatch(behavior_key) is None
            or ENVIRONMENT_PATTERN.fullmatch(environment) is None
        ):
            raise ApiCompositionError()
        self._session_factory = session_factory
        self._manifests = manifests
        self._behavior_key = behavior_key
        self._environment = environment

    def pin(self) -> RunBehaviorPin:
        try:
            with self._session_factory.begin() as session:
                resolver = BehaviorPackageResolver(
                    releases=BehaviorRepository(session),
                    manifests=self._manifests,
                )
                return resolver.pin_for_new_run(
                    behavior_key=self._behavior_key,
                    environment=self._environment,
                )
        except Exception as error:
            raise ApiCompositionError() from error


class ProductionApiLifecycle:
    def __init__(self, engine: Engine, jwks: JwksCache) -> None:
        self._engine = engine
        self._jwks = jwks
        self._closed = False

    def snapshot(self) -> DependencySnapshot:
        try:
            with self._engine.begin() as connection:
                connection.exec_driver_sql("SET LOCAL ROLE gonow_agent_api")
                database_epoch = float(
                    connection.scalar(text("SELECT EXTRACT(EPOCH FROM clock_timestamp())"))
                )
            offset = database_epoch - datetime.now(UTC).timestamp()
            return DependencySnapshot(
                jwks_ready=self._jwks.ready,
                database_ready=True,
                clock_offset_seconds=offset,
            )
        except Exception:
            return DependencySnapshot(
                jwks_ready=self._jwks.ready,
                database_ready=False,
                clock_offset_seconds=0,
            )

    async def startup(self) -> None:
        try:
            await self._jwks.warm()
            snapshot = await asyncio.to_thread(self.snapshot)
            if not snapshot.jwks_ready or not snapshot.database_ready:
                raise ApiCompositionError()
        except ApiCompositionError:
            raise
        except Exception as error:
            raise ApiCompositionError() from error

    async def shutdown(self) -> None:
        if not self._closed:
            await asyncio.to_thread(self._engine.dispose)
            self._closed = True


def _audit_receipt(context: Any, run_id: UUID) -> str:
    return hashlib.sha256(
        (
            "gonow:cancel:"
            + context.tenant_id
            + ":"
            + context.principal_id
            + ":"
            + context.trace_id
            + ":"
            + str(run_id)
        ).encode("utf-8")
    ).hexdigest()


def build_api_dependencies_from_environment(
    *,
    jwks_transport: httpx.AsyncBaseTransport | None = None,
) -> ApiDependencies:
    database_url = _required_environment("GONOW_DATABASE_URL")
    jwks_url = _required_environment("GONOW_JWKS_URL")
    allowed_hosts = tuple(
        value.strip().lower()
        for value in _required_environment("GONOW_JWKS_ALLOWED_HOSTS").split(",")
        if value.strip()
    )
    issuer = _required_environment("GONOW_JWT_ISSUER")
    audience = _required_environment("GONOW_JWT_AUDIENCE")
    manifest_path = Path(_required_environment("GONOW_BEHAVIOR_MANIFEST_PATH"))
    manifest_sha256 = _required_environment("GONOW_BEHAVIOR_MANIFEST_SHA256")
    behavior_key = _required_environment("GONOW_BEHAVIOR_KEY")
    behavior_environment = _required_environment("GONOW_BEHAVIOR_ENVIRONMENT")
    if not allowed_hosts or len(set(allowed_hosts)) != len(allowed_hosts):
        raise ApiCompositionError()
    if any(host == "*" or not host or "/" in host or ":" in host for host in allowed_hosts):
        raise ApiCompositionError()
    try:
        parsed_database = make_url(database_url)
        parsed_issuer = httpx.URL(issuer)
    except Exception as error:
        raise ApiCompositionError() from error
    if (
        parsed_database.drivername != "postgresql+pg8000"
        or not parsed_database.host
        or not parsed_database.database
        or parsed_issuer.scheme != "https"
        or parsed_issuer.host is None
        or parsed_issuer.userinfo
        or len(audience) > 256
    ):
        raise ApiCompositionError()

    provider = HttpJwksProvider(
        jwks_url,
        allowed_hosts=allowed_hosts,
        transport=jwks_transport,
    )
    jwks = JwksCache(provider)
    verifier = AuthVerifier(issuer=issuer, audience=audience, jwks=jwks)
    auth = AuthMiddleware(verifier)

    async def resolve_context(request: Request) -> RequestContext:
        return await auth.authenticate(request.headers)

    engine = create_engine(database_url, pool_pre_ping=True)
    factory = sessionmaker(
        engine,
        class_=ApiDatabaseSession,
        expire_on_commit=False,
    )
    manifests = ImmutableManifestFileStore(manifest_path, manifest_sha256)
    behavior_pin = DatabaseBehaviorPinProvider(
        factory,
        manifests=manifests,
        behavior_key=behavior_key,
        environment=behavior_environment,
    )
    lifecycle = ProductionApiLifecycle(engine, jwks)
    return ApiDependencies(
        health=HealthService(lifecycle.snapshot),
        contracts=SchemaRegistry(SPECIFICATION_PATH),
        run_start=RunStartService(factory, behavior_pin=behavior_pin),
        candidate_read=CandidateReadService(factory),
        events=EventWriter(factory),
        resume_capabilities=ResumeCapabilityService(
            PostgresResumeCapabilityStore(factory)
        ),
        cancellation=CancellationService(factory),
        context_resolver=resolve_context,
        resume_handler=ResumeTransitionService(factory),
        audit_receipt_resolver=_audit_receipt,
        itinerary_basic_info_command=_UnavailableCommandService(),
        itinerary_basic_info_command_enabled=False,
        startup=lifecycle.startup,
        shutdown=lifecycle.shutdown,
    )
