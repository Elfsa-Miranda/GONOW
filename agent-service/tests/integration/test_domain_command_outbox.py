from __future__ import annotations

import os
import site
import sys
import uuid
from datetime import date, datetime, timedelta, timezone
from pathlib import Path

import pytest
from alembic import command as alembic_command
from alembic.config import Config
from sqlalchemy import (
    BigInteger,
    Column,
    Date,
    DateTime,
    ForeignKey,
    MetaData,
    String,
    Table,
    create_engine,
    event,
    func,
    inspect,
    insert,
    select,
    text,
)
from sqlalchemy.dialects.postgresql import JSONB, UUID
from sqlalchemy.engine import Engine, make_url
from sqlalchemy.orm import Session, sessionmaker
from sqlalchemy.schema import CreateSchema, DropSchema


SERVICE_ROOT = Path(__file__).resolve().parents[2]
site.addsitedir(str(SERVICE_ROOT / ".venv" / "Lib" / "site-packages"))
sys.path.insert(0, str(SERVICE_ROOT))

from app.auth.context import RequestContext  # noqa: E402
from app.commands.itinerary_adopt import (  # noqa: E402
    AdoptableItineraryCandidate,
    AdoptCandidateCommand,
    CandidateActivity,
    ItineraryAdoptHandler,
    candidate_hash,
    command_hash,
)
from app.persistence.models.behavior import BEHAVIOR_SCHEMA  # noqa: E402
from app.persistence.models.outbox import OutboxMessageRecord  # noqa: E402
from app.persistence.models.runtime import EventRecord, RUNTIME_SCHEMA  # noqa: E402
from app.persistence.repositories.domain_commands import (  # noqa: E402
    ApprovalRejected,
    DOMAIN_APPROVALS,
    DOMAIN_RECEIPTS,
    DomainCommandReplayConflict,
    DomainCommandRepository,
    DomainCommandStaleVersion,
    ItineraryDomainTables,
)
from app.persistence.repositories.outbox import OutboxRepository  # noqa: E402
from app.persistence.repositories.runs import RunsRepository  # noqa: E402


ALEMBIC_INI = SERVICE_ROOT / "alembic.ini"
TARGET_REVISION = "p09_006_domain_commands"
PREVIOUS_REVISION = "p05_004_invocation_ledger"
VERSION_SCHEMA = "p09_006_domain_command_test"
FIXTURE_SCHEMA = "p09_006_domain_fixture"
DATABASE_URL = os.environ.get(
    "GONOW_P09_TEST_DATABASE_URL",
    "postgresql+pg8000://gonow_migrator_test@127.0.0.1:55432/gonow_p03_test",
)
ADMIN_DATABASE_URL = (
    "postgresql+pg8000://gonow_bootstrap_admin@127.0.0.1:55432/gonow_p03_test"
)
PRINCIPALS_SQL = SERVICE_ROOT / "tests" / "security" / "fixtures" / "rls_principals.sql"
ROLES = (
    "gonow_agent_api",
    "gonow_agent_worker",
    "gonow_command_service",
    "gonow_release_operator",
    "gonow_observer",
)
TENANT = "tenant-domain-integration"
PRINCIPAL = "principal-domain-integration"
NONCE = "a" * 64

fixture_metadata = MetaData(schema=FIXTURE_SCHEMA)
ITINERARIES = Table(
    "user_itineraries",
    fixture_metadata,
    Column("id", UUID(as_uuid=True), primary_key=True),
    Column("tenant_id", String(128), nullable=False),
    Column("user_id", String(256), nullable=False),
    Column("title", String(512), nullable=False),
    Column("start_date", Date, nullable=False),
    Column("end_date", Date, nullable=False),
    Column("plan_data", JSONB, nullable=False),
    Column("version", BigInteger, nullable=False),
    Column("candidate_hash", String(64), nullable=False),
    Column(
        "updated_at",
        DateTime(timezone=True),
        nullable=False,
        server_default=func.statement_timestamp(),
    ),
)
ACTIVITIES = Table(
    "itinerary_activities",
    fixture_metadata,
    Column("id", UUID(as_uuid=True), primary_key=True),
    Column("tenant_id", String(128), nullable=False),
    Column(
        "itinerary_id",
        UUID(as_uuid=True),
        ForeignKey(f"{FIXTURE_SCHEMA}.user_itineraries.id", ondelete="CASCADE"),
        nullable=False,
    ),
    Column("position", BigInteger, nullable=False),
    Column("activity_data", JSONB, nullable=False),
    Column(
        "created_at",
        DateTime(timezone=True),
        nullable=False,
        server_default=func.statement_timestamp(),
    ),
)
DOMAIN_TABLES = ItineraryDomainTables(
    itineraries=ITINERARIES,
    activities=ACTIVITIES,
)


class OwnerSession(Session):
    pass


class ApiSession(Session):
    pass


class CommandSession(Session):
    pass


def _set_scope(connection) -> None:
    connection.execute(
        text("SELECT set_config('app.tenant_id', :tenant, true)"),
        {"tenant": TENANT},
    )
    connection.execute(
        text("SELECT set_config('app.principal_id', :principal, true)"),
        {"principal": PRINCIPAL},
    )


@event.listens_for(OwnerSession, "after_begin")
def _scope_owner(session: Session, transaction, connection) -> None:
    del session, transaction
    _set_scope(connection)


@event.listens_for(ApiSession, "after_begin")
def _scope_api(session: Session, transaction, connection) -> None:
    del session, transaction
    connection.exec_driver_sql("SET LOCAL ROLE gonow_agent_api")
    _set_scope(connection)


@event.listens_for(CommandSession, "after_begin")
def _scope_command(session: Session, transaction, connection) -> None:
    del session, transaction
    connection.exec_driver_sql("SET LOCAL ROLE gonow_command_service")
    _set_scope(connection)


def _assert_task_owned_database() -> None:
    parsed = make_url(DATABASE_URL)
    assert parsed.drivername == "postgresql+pg8000"
    assert parsed.host == "127.0.0.1"
    assert parsed.port == 55432
    assert parsed.username == "gonow_migrator_test"
    assert parsed.database == "gonow_p03_test"
    assert parsed.password is None


def _config(monkeypatch: pytest.MonkeyPatch) -> Config:
    monkeypatch.setenv("GONOW_DATABASE_URL", DATABASE_URL)
    monkeypatch.setenv("GONOW_ALEMBIC_VERSION_SCHEMA", VERSION_SCHEMA)
    return Config(str(ALEMBIC_INI))


def _reset(engine: Engine, config: Config) -> None:
    with engine.begin() as connection:
        connection.execute(DropSchema(FIXTURE_SCHEMA, cascade=True, if_exists=True))
        connection.execute(DropSchema(BEHAVIOR_SCHEMA, cascade=True, if_exists=True))
        connection.execute(DropSchema(RUNTIME_SCHEMA, cascade=True, if_exists=True))
        connection.execute(DropSchema(VERSION_SCHEMA, cascade=True, if_exists=True))
        connection.execute(CreateSchema(VERSION_SCHEMA))
    alembic_command.upgrade(config, TARGET_REVISION)
    with engine.begin() as connection:
        connection.execute(CreateSchema(FIXTURE_SCHEMA))
        fixture_metadata.create_all(connection)
        connection.exec_driver_sql(
            f"GRANT USAGE ON SCHEMA {FIXTURE_SCHEMA} TO gonow_command_service"
        )
        connection.exec_driver_sql(
            f"GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA "
            f"{FIXTURE_SCHEMA} TO gonow_command_service"
        )


def _provision_principals(admin_engine: Engine) -> None:
    with admin_engine.begin() as connection:
        connection.exec_driver_sql(PRINCIPALS_SQL.read_text(encoding="utf-8"))


def _drop_principals(admin_engine: Engine) -> None:
    with admin_engine.begin() as connection:
        for role in ROLES:
            connection.exec_driver_sql(f"DROP OWNED BY {role}")
        for role in ROLES:
            connection.exec_driver_sql(f"DROP ROLE IF EXISTS {role}")


@pytest.fixture()
def domain_database(monkeypatch: pytest.MonkeyPatch):
    _assert_task_owned_database()
    engine = create_engine(DATABASE_URL, pool_pre_ping=True)
    admin_engine = create_engine(ADMIN_DATABASE_URL, pool_pre_ping=True)
    config = _config(monkeypatch)
    _provision_principals(admin_engine)
    try:
        _reset(engine, config)
        owner_factory = sessionmaker(
            engine,
            class_=OwnerSession,
            expire_on_commit=False,
        )
        api_factory = sessionmaker(
            admin_engine,
            class_=ApiSession,
            expire_on_commit=False,
        )
        command_factory = sessionmaker(
            admin_engine,
            class_=CommandSession,
            expire_on_commit=False,
        )
        yield engine, config, owner_factory, api_factory, command_factory
    finally:
        with engine.begin() as connection:
            connection.execute(DropSchema(FIXTURE_SCHEMA, cascade=True, if_exists=True))
            connection.execute(
                DropSchema(BEHAVIOR_SCHEMA, cascade=True, if_exists=True)
            )
            connection.execute(DropSchema(RUNTIME_SCHEMA, cascade=True, if_exists=True))
            connection.execute(DropSchema(VERSION_SCHEMA, cascade=True, if_exists=True))
        engine.dispose()
        _drop_principals(admin_engine)
        admin_engine.dispose()


def _context(*, principal: str = PRINCIPAL) -> RequestContext:
    return RequestContext(
        principal_id=principal,
        tenant_id=TENANT,
        permissions=("itinerary.adopt",),
        locale="en",
        timezone="UTC",
        trace_id="trace-domain-integration",
    )


def _command(
    *,
    run_id: uuid.UUID,
    command_id: uuid.UUID | None = None,
    approval_id: uuid.UUID | None = None,
    candidate_id: uuid.UUID | None = None,
    itinerary_id: uuid.UUID | None = None,
    expected_version: int = 0,
    title: str = "Atomic itinerary",
    nonce: str = NONCE,
) -> AdoptCandidateCommand:
    return AdoptCandidateCommand(
        schema_version="1.0",
        command_id=command_id or uuid.uuid4(),
        approval_id=approval_id or uuid.uuid4(),
        target_itinerary_id=itinerary_id or uuid.uuid4(),
        run_id=run_id,
        expected_version=expected_version,
        capability_nonce=nonce,
        candidate=AdoptableItineraryCandidate(
            candidate_id=candidate_id or uuid.uuid4(),
            title=title,
            starts_on=date(2026, 10, 1),
            ends_on=date(2026, 10, 2),
            activities=(
                CandidateActivity(
                    activity_id=uuid.uuid4(),
                    day_index=1,
                    position=0,
                    title="Verified museum",
                    starts_at=datetime(2026, 10, 1, 9, tzinfo=timezone.utc),
                    note="Keep the evidence visible.",
                    evidence_ids=("ev_museum_hours",),
                ),
                CandidateActivity(
                    activity_id=uuid.uuid4(),
                    day_index=2,
                    position=0,
                    title="Verified park",
                    starts_at=None,
                    note=None,
                    evidence_ids=("ev_park_access",),
                ),
            ),
        ),
    )


def _create_run(factory: sessionmaker[Session]) -> uuid.UUID:
    with factory() as session, session.begin():
        runs = RunsRepository(session)
        thread = runs.create_thread(tenant_id=TENANT, owner_principal_id=PRINCIPAL)
        run = runs.create_or_replay_run(
            tenant_id=TENANT,
            principal_id=PRINCIPAL,
            thread_id=thread.thread_id,
            request_scope="domain-command-test",
            idempotency_key=f"domain-{uuid.uuid4()}",
            request_hash="1" * 64,
            manifest_digest="2" * 64,
            manifest={"manifest_ref": "behavior://sha256/" + ("2" * 64)},
        )
        return run.run_id


def _grant(
    factory: sessionmaker[Session],
    command: AdoptCandidateCommand,
    *,
    context: RequestContext | None = None,
) -> None:
    context = context or _context()
    digest = candidate_hash(command)
    fingerprint = command_hash(command, candidate_digest=digest)
    with factory() as session, session.begin():
        DomainCommandRepository(session, domain_tables=DOMAIN_TABLES).grant_approval(
            approval_id=command.approval_id,
            context=context,
            run_id=command.run_id,
            target_itinerary_id=command.target_itinerary_id,
            candidate_id=command.candidate.candidate_id,
            candidate_hash=digest,
            command_hash=fingerprint,
            expected_version=command.expected_version,
            capability_nonce=command.capability_nonce,
            expires_at=datetime.now(timezone.utc) + timedelta(minutes=2),
            audit_receipt_id="audit-domain-integration",
        )


def _execute(
    factory: sessionmaker[Session],
    command: AdoptCandidateCommand,
    *,
    context: RequestContext | None = None,
):
    with factory() as session, session.begin():
        return ItineraryAdoptHandler(
            DomainCommandRepository(session, domain_tables=DOMAIN_TABLES)
        ).execute(context=context or _context(), command=command)


def test_replay_has_one_itinerary_effect_and_one_outbox(domain_database) -> None:
    _, _, owner_factory, api_factory, command_factory = domain_database
    run_id = _create_run(api_factory)
    command = _command(run_id=run_id)
    _grant(command_factory, command)
    first = _execute(command_factory, command)
    replay = _execute(
        command_factory,
        command.model_copy(update={"command_id": uuid.uuid4()}),
    )
    assert not first.replayed
    assert replay.replayed
    assert replay.command_id == first.command_id
    assert replay.event_id == first.event_id
    assert replay.outbox_id == first.outbox_id
    with owner_factory() as session, session.begin():
        assert session.scalar(select(func.count()).select_from(ITINERARIES)) == 1
        assert session.scalar(select(func.count()).select_from(ACTIVITIES)) == 2
        assert session.scalar(select(func.count()).select_from(DOMAIN_RECEIPTS)) == 1
        assert session.scalar(select(func.count()).select_from(EventRecord)) == 1
        assert (
            session.scalar(select(func.count()).select_from(OutboxMessageRecord)) == 1
        )
        approval = (
            session.execute(
                select(DOMAIN_APPROVALS).where(
                    DOMAIN_APPROVALS.c.approval_id == command.approval_id
                )
            )
            .mappings()
            .one()
        )
        assert approval["status"] == "consumed"


def test_changed_replay_hash_is_rejected_without_second_effect(domain_database) -> None:
    _, _, owner_factory, api_factory, command_factory = domain_database
    run_id = _create_run(api_factory)
    command = _command(run_id=run_id)
    _grant(command_factory, command)
    _execute(command_factory, command)
    changed = command.model_copy(
        update={
            "command_id": uuid.uuid4(),
            "candidate": command.candidate.model_copy(
                update={"title": "Forged change"}
            ),
        }
    )
    with pytest.raises(DomainCommandReplayConflict):
        _execute(command_factory, changed)
    with owner_factory() as session, session.begin():
        assert session.scalar(select(func.count()).select_from(DOMAIN_RECEIPTS)) == 1
        assert (
            session.scalar(select(func.count()).select_from(OutboxMessageRecord)) == 1
        )
        assert session.scalar(select(ITINERARIES.c.version)) == 1


def test_forged_nonce_and_principal_are_denied_without_effect(domain_database) -> None:
    _, _, owner_factory, api_factory, command_factory = domain_database
    run_id = _create_run(api_factory)
    command = _command(run_id=run_id)
    _grant(command_factory, command)
    with pytest.raises(ApprovalRejected):
        _execute(
            command_factory,
            command.model_copy(update={"capability_nonce": "b" * 64}),
        )
    with pytest.raises(ApprovalRejected):
        _execute(
            command_factory,
            command,
            context=_context(principal="forged-principal"),
        )
    with owner_factory() as session, session.begin():
        assert session.scalar(select(func.count()).select_from(ITINERARIES)) == 0
        assert session.scalar(select(func.count()).select_from(DOMAIN_RECEIPTS)) == 0
        assert (
            session.scalar(select(func.count()).select_from(OutboxMessageRecord)) == 0
        )


def test_stale_version_rejects_and_preserves_candidate_approval(
    domain_database,
) -> None:
    _, _, owner_factory, api_factory, command_factory = domain_database
    run_id = _create_run(api_factory)
    itinerary_id = uuid.uuid4()
    command = _command(
        run_id=run_id,
        itinerary_id=itinerary_id,
        expected_version=1,
    )
    with owner_factory() as session, session.begin():
        session.execute(
            insert(ITINERARIES).values(
                id=itinerary_id,
                tenant_id=TENANT,
                user_id=PRINCIPAL,
                title="Collaborator update",
                start_date=date(2026, 10, 1),
                end_date=date(2026, 10, 2),
                plan_data={"source": "collaborator"},
                version=2,
                candidate_hash="3" * 64,
            )
        )
    _grant(command_factory, command)
    with pytest.raises(DomainCommandStaleVersion) as caught:
        _execute(command_factory, command)
    assert caught.value.current_version == 2
    assert len(caught.value.snapshot_hash) == 64
    with owner_factory() as session, session.begin():
        assert session.scalar(select(ITINERARIES.c.version)) == 2
        assert session.scalar(select(func.count()).select_from(DOMAIN_RECEIPTS)) == 0
        assert (
            session.scalar(select(func.count()).select_from(OutboxMessageRecord)) == 0
        )
        assert (
            session.scalar(
                select(DOMAIN_APPROVALS.c.status).where(
                    DOMAIN_APPROVALS.c.approval_id == command.approval_id
                )
            )
            == "approved"
        )


def test_outbox_failure_rolls_back_target_approval_event_and_receipt(
    domain_database,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    _, _, owner_factory, api_factory, command_factory = domain_database
    run_id = _create_run(api_factory)
    command = _command(run_id=run_id)
    _grant(command_factory, command)
    original = OutboxRepository.enqueue_event

    def fail_after_enqueue(self: OutboxRepository, **kwargs):
        original(self, **kwargs)
        raise RuntimeError("fixture.outbox_failure")

    monkeypatch.setattr(OutboxRepository, "enqueue_event", fail_after_enqueue)
    with pytest.raises(RuntimeError, match="fixture.outbox_failure"):
        _execute(command_factory, command)
    with owner_factory() as session, session.begin():
        assert session.scalar(select(func.count()).select_from(ITINERARIES)) == 0
        assert session.scalar(select(func.count()).select_from(ACTIVITIES)) == 0
        assert session.scalar(select(func.count()).select_from(DOMAIN_RECEIPTS)) == 0
        assert session.scalar(select(func.count()).select_from(EventRecord)) == 0
        assert (
            session.scalar(select(func.count()).select_from(OutboxMessageRecord)) == 0
        )
        assert (
            session.scalar(
                select(DOMAIN_APPROVALS.c.status).where(
                    DOMAIN_APPROVALS.c.approval_id == command.approval_id
                )
            )
            == "approved"
        )


def test_migration_downgrade_removes_only_domain_command_tables(
    domain_database,
) -> None:
    engine, config, _, _, _ = domain_database
    alembic_command.downgrade(config, PREVIOUS_REVISION)
    tables = set(inspect(engine).get_table_names(schema=RUNTIME_SCHEMA))
    assert "runs" in tables
    assert "outbox_messages" in tables
    assert "domain_command_approvals" not in tables
    assert "domain_command_receipts" not in tables
    alembic_command.upgrade(config, TARGET_REVISION)
    rebuilt = set(inspect(engine).get_table_names(schema=RUNTIME_SCHEMA))
    assert {"domain_command_approvals", "domain_command_receipts"} <= rebuilt
