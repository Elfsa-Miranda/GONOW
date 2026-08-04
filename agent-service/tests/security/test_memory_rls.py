from __future__ import annotations

import os
import uuid
from pathlib import Path

import pytest
from alembic import command
from alembic.config import Config
from sqlalchemy import create_engine, inspect, text
from sqlalchemy.engine import make_url
from sqlalchemy.exc import DBAPIError
from sqlalchemy.schema import CreateSchema, DropSchema


def _source() -> str:
    return Path("migrations/versions/p12a_001_structured_memory.py").read_text(encoding="utf-8")


def test_every_memory_table_has_forced_rls() -> None:
    source = _source()
    assert "for table in TABLES" in source
    assert "ENABLE ROW LEVEL SECURITY" in source
    assert "FORCE ROW LEVEL SECURITY" in source


def test_rls_binds_tenant_and_principal() -> None:
    source = _source()
    assert "tenant_id = agent_runtime.current_tenant_id()" in source
    assert "principal_id = {SCHEMA}.current_principal_id()" in source
    assert "WITH CHECK" in source


def test_worker_cannot_update_formal_memory() -> None:
    source = _source()
    assert "GRANT SELECT, INSERT ON {SCHEMA}.candidates, {SCHEMA}.outbox_events TO gonow_agent_worker" in source
    assert "GRANT UPDATE ON ALL TABLES IN SCHEMA {SCHEMA} TO gonow_agent_worker" not in source


def test_service_role_or_public_bypass_is_not_granted() -> None:
    source = _source()
    assert "TO service_role" not in source
    assert "TO PUBLIC" not in source.replace("REVOKE ALL", "")


SERVICE_ROOT = Path(__file__).resolve().parents[2]
DATABASE_URL = os.environ.get("GONOW_P12A_TEST_DATABASE_URL", "postgresql+pg8000://gonow_migrator_test@127.0.0.1:55432/gonow_p03_test")
ADMIN_URL = "postgresql+pg8000://gonow_bootstrap_admin@127.0.0.1:55432/gonow_p03_test"
VERSION_SCHEMA = "p12a_memory_rls_test"
SCHEMAS = ("agent_memory", "domain_command", "agent_knowledge", "agent_behavior", "agent_runtime", VERSION_SCHEMA)
ROLES = ("gonow_agent_api", "gonow_agent_worker", "gonow_command_service", "gonow_release_operator", "gonow_observer")


def _reset(engine) -> None:
    with engine.begin() as connection:
        for schema in SCHEMAS:
            connection.execute(DropSchema(schema, cascade=True, if_exists=True))
        connection.execute(CreateSchema(VERSION_SCHEMA))


def _roles(admin_engine) -> tuple[str, ...]:
    created: list[str] = []
    with admin_engine.begin() as connection:
        for role in ROLES:
            exists = connection.execute(
                text("SELECT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = :role)"),
                {"role": role},
            ).scalar_one()
            if not exists:
                connection.exec_driver_sql(
                    f"CREATE ROLE {role} NOLOGIN NOSUPERUSER NOCREATEDB "
                    "NOCREATEROLE NOINHERIT NOREPLICATION NOBYPASSRLS"
                )
                created.append(role)
    return tuple(created)


def _drop_created_roles(admin_engine, roles: tuple[str, ...]) -> None:
    with admin_engine.begin() as connection:
        for role in roles:
            connection.exec_driver_sql(f"DROP OWNED BY {role}")
        for role in roles:
            connection.exec_driver_sql(f"DROP ROLE {role}")


@pytest.fixture()
def memory_database(monkeypatch: pytest.MonkeyPatch):
    parsed = make_url(DATABASE_URL)
    assert (parsed.host, parsed.port, parsed.database, parsed.password) == ("127.0.0.1", 55432, "gonow_p03_test", None)
    engine = create_engine(DATABASE_URL, pool_pre_ping=True)
    admin = create_engine(ADMIN_URL, pool_pre_ping=True)
    _reset(engine)
    created_roles = _roles(admin)
    monkeypatch.setenv("GONOW_DATABASE_URL", DATABASE_URL)
    monkeypatch.setenv("GONOW_ALEMBIC_VERSION_SCHEMA", VERSION_SCHEMA)
    command.upgrade(Config(str(SERVICE_ROOT / "alembic.ini")), "p12a_001_memory")
    try:
        yield engine, admin
    finally:
        _reset(engine)
        _drop_created_roles(admin, created_roles)
        engine.dispose()
        admin.dispose()


def _set_identity(connection, tenant: str, principal: str) -> None:
    connection.execute(text("SELECT set_config('app.tenant_id', :tenant, true)"), {"tenant": tenant})
    connection.execute(text("SELECT set_config('app.principal_id', :principal, true)"), {"principal": principal})


def test_realpg_migration_has_all_forced_rls_tables(memory_database) -> None:
    engine, _ = memory_database
    inspector = inspect(engine)
    assert set(inspector.get_table_names(schema="agent_memory")) == {"consent_events", "candidates", "records", "derivatives", "tombstones", "command_attempts", "outbox_events"}
    with engine.connect() as connection:
        rows = connection.execute(text("SELECT c.relname, c.relrowsecurity, c.relforcerowsecurity FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='agent_memory' AND c.relkind='r' ORDER BY c.relname")).all()
    assert len(rows) == 7 and all(row.relrowsecurity and row.relforcerowsecurity for row in rows)


def test_realpg_rls_binds_tenant_and_principal_and_worker_cannot_write_record(memory_database) -> None:
    engine, admin = memory_database
    record_id = uuid.uuid4()
    with engine.begin() as connection:
        _set_identity(connection, "tenant-a", "user-a")
        connection.execute(text("INSERT INTO agent_memory.records(memory_id,tenant_id,principal_id,purpose,memory_type,enum_value,provenance,state,version,consent_version,retention_until) VALUES (:id,'tenant-a','user-a','itinerary.personalization','travel_pace','balanced',CAST(:provenance AS jsonb),'active',1,1,statement_timestamp()+interval '30 days')"), {"id":record_id,"provenance":'{"source_type":"user_declared","source_ref":"ui:memory-form","source_digest":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}'})
    with admin.begin() as connection:
        connection.execute(text("SET LOCAL ROLE gonow_agent_api")); _set_identity(connection, "tenant-a", "user-a")
        assert connection.execute(text("SELECT count(*) FROM agent_memory.records")).scalar_one() == 1
    with admin.begin() as connection:
        connection.execute(text("SET LOCAL ROLE gonow_agent_api")); _set_identity(connection, "tenant-a", "user-b")
        assert connection.execute(text("SELECT count(*) FROM agent_memory.records")).scalar_one() == 0
    with admin.connect() as connection:
        transaction = connection.begin()
        try:
            connection.execute(text("SET LOCAL ROLE gonow_agent_worker")); _set_identity(connection, "tenant-a", "user-a")
            with pytest.raises(DBAPIError):
                connection.execute(text("UPDATE agent_memory.records SET enum_value='fast' WHERE memory_id=:id"), {"id":record_id})
        finally:
            transaction.rollback()
