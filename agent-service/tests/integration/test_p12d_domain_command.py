from __future__ import annotations

import os
import site
import sys
import uuid
from datetime import date, datetime, timezone
from decimal import Decimal
from pathlib import Path
from typing import Any

import pytest
from alembic import command
from alembic.config import Config
from sqlalchemy import MetaData, create_engine, event, func, insert, select, text
from sqlalchemy.engine import Engine, make_url
from sqlalchemy.orm import Session, sessionmaker
from sqlalchemy.schema import CreateSchema, DropSchema


SERVICE_ROOT = Path(__file__).resolve().parents[2]
site.addsitedir(str(SERVICE_ROOT / ".venv" / "Lib" / "site-packages"))
sys.path.insert(0, str(SERVICE_ROOT))

from app.auth.context import RequestContext  # noqa: E402
from app.commands.itinerary_basic_info import (  # noqa: E402
    CommandOutcome,
    ItineraryBasicInfoPatch,
    UpdateItineraryBasicInfoCommand,
)
from app.persistence.repositories.itinerary_basic_info_commands import (  # noqa: E402
    ATTEMPTS,
    OUTBOX,
    RECEIPTS,
    DomainCommandIdempotencyConflict,
    ItineraryBasicInfoCommandService,
    ItineraryBasicInfoOutboxRepository,
    isolated_business_projection,
)


ALEMBIC_INI = SERVICE_ROOT / "alembic.ini"
TARGET_REVISION = "p12d_001_commands"
VERSION_SCHEMA = "p12d_040_command_test"
BUSINESS_SCHEMA = "p12d_business_projection"
DATABASE_URL = os.environ.get(
    "GONOW_P12D_TEST_DATABASE_URL",
    "postgresql+pg8000://gonow_migrator_test@127.0.0.1:55432/gonow_p03_test",
)
ADMIN_DATABASE_URL = (
    "postgresql+pg8000://gonow_bootstrap_admin@127.0.0.1:55432/gonow_p03_test"
)
ROLES = (
    "gonow_agent_api",
    "gonow_agent_worker",
    "gonow_command_service",
    "gonow_release_operator",
    "gonow_observer",
)
SCHEMAS = (
    BUSINESS_SCHEMA,
    "domain_command",
    "agent_knowledge",
    "agent_behavior",
    "agent_runtime",
    VERSION_SCHEMA,
)
TENANT = "tenant-p12d-alpha"
PRINCIPAL = "principal-p12d-alpha"
TARGET = uuid.UUID("10000000-0000-4000-8000-000000000001")


class CommandSession(Session):
    pass


@event.listens_for(CommandSession, "after_begin")
def _command_role(session: Session, transaction: Any, connection: Any) -> None:
    del session, transaction
    connection.exec_driver_sql("SET LOCAL ROLE gonow_command_service")


def _assert_isolated() -> None:
    parsed = make_url(DATABASE_URL)
    assert (
        parsed.host,
        parsed.port,
        parsed.username,
        parsed.database,
        parsed.password,
    ) == ("127.0.0.1", 55432, "gonow_migrator_test", "gonow_p03_test", None)


def _config(monkeypatch: pytest.MonkeyPatch) -> Config:
    monkeypatch.setenv("GONOW_DATABASE_URL", DATABASE_URL)
    monkeypatch.setenv("GONOW_ALEMBIC_VERSION_SCHEMA", VERSION_SCHEMA)
    return Config(str(ALEMBIC_INI))


def _reset_schemas(engine: Engine) -> None:
    with engine.begin() as connection:
        for schema in SCHEMAS:
            connection.execute(DropSchema(schema, cascade=True, if_exists=True))
        connection.execute(CreateSchema(VERSION_SCHEMA))


def _provision_roles(admin_engine: Engine) -> None:
    with admin_engine.begin() as connection:
        for role in ROLES:
            connection.exec_driver_sql(
                f"""
                DO $$ BEGIN
                  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = '{role}') THEN
                    CREATE ROLE {role} NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE
                      NOINHERIT NOREPLICATION NOBYPASSRLS;
                  END IF;
                  ALTER ROLE {role} NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE
                    NOINHERIT NOREPLICATION NOBYPASSRLS;
                END $$
                """
            )


def _drop_roles(admin_engine: Engine) -> None:
    with admin_engine.begin() as connection:
        for role in ROLES:
            connection.exec_driver_sql(f"DROP OWNED BY {role}")
        for role in ROLES:
            connection.exec_driver_sql(f"DROP ROLE IF EXISTS {role}")


@pytest.fixture()
def command_database(monkeypatch: pytest.MonkeyPatch):
    _assert_isolated()
    engine = create_engine(DATABASE_URL, pool_pre_ping=True)
    admin_engine = create_engine(ADMIN_DATABASE_URL, pool_pre_ping=True)
    _reset_schemas(engine)
    _provision_roles(admin_engine)
    command.upgrade(_config(monkeypatch), TARGET_REVISION)
    metadata = MetaData()
    business = isolated_business_projection(metadata, schema=BUSINESS_SCHEMA)
    with engine.begin() as connection:
        connection.execute(CreateSchema(BUSINESS_SCHEMA))
        metadata.create_all(connection)
        connection.exec_driver_sql(f"REVOKE ALL ON SCHEMA {BUSINESS_SCHEMA} FROM PUBLIC")
        connection.exec_driver_sql(
            f"GRANT USAGE ON SCHEMA {BUSINESS_SCHEMA} TO gonow_command_service"
        )
        connection.exec_driver_sql(
            f"GRANT SELECT, UPDATE ON {BUSINESS_SCHEMA}.{business.name} "
            "TO gonow_command_service"
        )
        connection.exec_driver_sql(
            f"ALTER TABLE {BUSINESS_SCHEMA}.{business.name} ENABLE ROW LEVEL SECURITY"
        )
        connection.exec_driver_sql(
            f"ALTER TABLE {BUSINESS_SCHEMA}.{business.name} FORCE ROW LEVEL SECURITY"
        )
        connection.exec_driver_sql(
            f"CREATE POLICY tenant_isolation ON {BUSINESS_SCHEMA}.{business.name} "
            "USING (tenant_id = agent_runtime.current_tenant_id()) "
            "WITH CHECK (tenant_id = agent_runtime.current_tenant_id())"
        )
        connection.execute(select(func.set_config("app.tenant_id", TENANT, True)))
        connection.execute(
            insert(business).values(
                id=TARGET,
                tenant_id=TENANT,
                user_id=PRINCIPAL,
                title="Legacy title",
                destination_city="Hangzhou",
                start_date=date(2026, 9, 1),
                end_date=date(2026, 9, 2),
                budget=Decimal("100.00"),
                actual_cost=Decimal("10.00"),
                tags=["legacy"],
                version=5,
                updated_at=datetime(2026, 8, 4, 9, 0, tzinfo=timezone.utc),
            )
        )
    factory = sessionmaker(
        admin_engine,
        class_=CommandSession,
        expire_on_commit=False,
    )
    try:
        yield engine, business, factory
    finally:
        engine.dispose()
        cleanup = create_engine(DATABASE_URL)
        try:
            _reset_schemas(cleanup)
        finally:
            cleanup.dispose()
        _drop_roles(admin_engine)
        admin_engine.dispose()


def _context(
    *, tenant: str = TENANT, principal: str = PRINCIPAL
) -> RequestContext:
    return RequestContext(
        principal_id=principal,
        tenant_id=tenant,
        permissions=("itinerary.basic_info.update",),
        locale="en",
        timezone="UTC",
        trace_id="trace-p12d-domain-command",
    )


def _command(
    *,
    command_id: uuid.UUID = uuid.UUID("20000000-0000-4000-8000-000000000001"),
    idempotency_key: str = "p12d-basic-info-command-0001",
    expected_version: int = 5,
    title: str = "Domain Command title",
) -> UpdateItineraryBasicInfoCommand:
    return UpdateItineraryBasicInfoCommand(
        schema_version="1.0",
        command_id=command_id,
        idempotency_key=idempotency_key,
        target_itinerary_id=TARGET,
        expected_version=expected_version,
        patch=ItineraryBasicInfoPatch(
            title=title,
            destination="Shanghai",
            start_date=date(2026, 10, 1),
            end_date=date(2026, 10, 3),
            budget=Decimal("1200.00"),
            actual_cost=Decimal("50.00"),
            tags=("city", "museum"),
        ),
    )


def _business_row(engine: Engine, business) -> dict[str, object]:
    with engine.begin() as connection:
        connection.execute(select(func.set_config("app.tenant_id", TENANT, True)))
        return dict(
            connection.execute(
                select(business).where(business.c.id == TARGET)
            ).mappings().one()
        )


def _effect_counts(engine: Engine) -> tuple[int, int, int]:
    with engine.begin() as connection:
        connection.execute(select(func.set_config("app.tenant_id", TENANT, True)))
        return (
            int(connection.scalar(select(func.count()).select_from(ATTEMPTS)) or 0),
            int(connection.scalar(select(func.count()).select_from(RECEIPTS)) or 0),
            int(connection.scalar(select(func.count()).select_from(OUTBOX)) or 0),
        )


def test_atomic_business_mutation_receipt_and_outbox(command_database) -> None:
    engine, business, factory = command_database
    service = ItineraryBasicInfoCommandService(factory, business_table=business)
    receipt = service.execute(context=_context(), command=_command())
    assert receipt.state is CommandOutcome.COMMITTED
    assert receipt.actual_version == 6
    assert receipt.event_id is not None and receipt.outbox_id is not None
    row = _business_row(engine, business)
    assert row["title"] == "Domain Command title"
    assert row["destination_city"] == "Shanghai"
    assert row["version"] == 6
    assert _effect_counts(engine) == (1, 1, 1)
    lookup = service.lookup(
        context=_context(),
        target_itinerary_id=TARGET,
        idempotency_key="p12d-basic-info-command-0001",
    )
    assert lookup is not None
    assert lookup.command_id == receipt.command_id
    assert lookup.replayed is True


def test_stale_conflict_has_no_business_or_outbox_effect(command_database) -> None:
    engine, business, factory = command_database
    service = ItineraryBasicInfoCommandService(factory, business_table=business)
    receipt = service.execute(
        context=_context(), command=_command(expected_version=4)
    )
    assert receipt.state is CommandOutcome.CONFLICT
    assert receipt.actual_version is receipt.event_id is receipt.outbox_id is None
    assert _business_row(engine, business)["version"] == 5
    assert _effect_counts(engine) == (1, 1, 0)


def test_semantic_retry_replays_once_and_collision_has_zero_effect(
    command_database,
) -> None:
    engine, business, factory = command_database
    service = ItineraryBasicInfoCommandService(factory, business_table=business)
    first = service.execute(context=_context(), command=_command())
    replay = service.execute(context=_context(), command=_command())
    assert replay.command_id == first.command_id
    assert replay.outbox_id == first.outbox_id
    assert replay.replayed is True
    assert _effect_counts(engine) == (1, 1, 1)
    with pytest.raises(DomainCommandIdempotencyConflict):
        service.execute(
            context=_context(), command=_command(title="Collision body")
        )
    assert _effect_counts(engine) == (1, 1, 1)


def test_fault_after_business_mutation_rolls_back_every_effect(
    command_database,
) -> None:
    engine, business, factory = command_database

    def fail(stage: str) -> None:
        if stage == "after_business_mutation_before_outbox":
            raise RuntimeError("synthetic.p12d.after_business_mutation")

    service = ItineraryBasicInfoCommandService(
        factory,
        business_table=business,
        fault_injector=fail,
    )
    with pytest.raises(RuntimeError, match="synthetic.p12d"):
        service.execute(context=_context(), command=_command())
    row = _business_row(engine, business)
    assert row["title"] == "Legacy title"
    assert row["version"] == 5
    assert _effect_counts(engine) == (0, 0, 0)


def test_outbox_delivery_requires_the_live_fencing_token(command_database) -> None:
    engine, business, factory = command_database
    receipt = ItineraryBasicInfoCommandService(
        factory, business_table=business
    ).execute(context=_context(), command=_command())
    assert receipt.outbox_id is not None
    with factory.begin() as session:
        claim = ItineraryBasicInfoOutboxRepository(session).claim_one(
            tenant_id=TENANT,
            dispatcher_id="p12d-dispatcher",
            lease_seconds=30,
        )
    assert claim is not None and claim.outbox_id == receipt.outbox_id
    with factory.begin() as session:
        stale_allowed = ItineraryBasicInfoOutboxRepository(session).mark_delivered(
            tenant_id=TENANT,
            outbox_id=claim.outbox_id,
            claim_token=uuid.UUID("ffffffff-ffff-4fff-8fff-ffffffffffff"),
        )
    assert stale_allowed is False
    with factory.begin() as session:
        delivered = ItineraryBasicInfoOutboxRepository(session).mark_delivered(
            tenant_id=TENANT,
            outbox_id=claim.outbox_id,
            claim_token=claim.claim_token,
        )
    assert delivered is True
    with engine.begin() as connection:
        connection.execute(select(func.set_config("app.tenant_id", TENANT, True)))
        row = connection.execute(
            select(OUTBOX.c.state, OUTBOX.c.claim_token).where(
                OUTBOX.c.outbox_id == claim.outbox_id
            )
        ).one()
    assert row.state == "delivered"
    assert row.claim_token is None
