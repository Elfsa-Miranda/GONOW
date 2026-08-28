from __future__ import annotations

import os
import site
import sys
import uuid
from pathlib import Path

import pytest
from alembic import command
from alembic.config import Config
from sqlalchemy import create_engine, inspect, text
from sqlalchemy.engine import Engine, make_url
from sqlalchemy.exc import DBAPIError, ProgrammingError
from sqlalchemy.schema import CreateSchema, DropSchema


SERVICE_ROOT = Path(__file__).resolve().parents[2]
site.addsitedir(str(SERVICE_ROOT / ".venv" / "Lib" / "site-packages"))
sys.path.insert(0, str(SERVICE_ROOT))

ALEMBIC_INI = SERVICE_ROOT / "alembic.ini"
TARGET_REVISION = "p12d_001_commands"
VERSION_SCHEMA = "p12d_030_rls_test"
COMMAND_SCHEMA = "domain_command"
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
TABLES = (
    "itinerary_basic_info_attempts",
    "itinerary_basic_info_outbox",
    "itinerary_basic_info_receipts",
)
SCHEMAS = (COMMAND_SCHEMA, "agent_knowledge", "agent_behavior", "agent_runtime", VERSION_SCHEMA)
TENANTS = ("tenant-p12d-alpha", "tenant-p12d-beta")


def _assert_isolated() -> None:
    parsed = make_url(DATABASE_URL)
    assert (
        parsed.drivername,
        parsed.host,
        parsed.port,
        parsed.username,
        parsed.database,
        parsed.password,
    ) == (
        "postgresql+pg8000",
        "127.0.0.1",
        55432,
        "gonow_migrator_test",
        "gonow_p03_test",
        None,
    )


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
def p12d_database(monkeypatch: pytest.MonkeyPatch):
    _assert_isolated()
    engine = create_engine(DATABASE_URL, pool_pre_ping=True)
    admin_engine = create_engine(ADMIN_DATABASE_URL, pool_pre_ping=True)
    _reset_schemas(engine)
    _provision_roles(admin_engine)
    command.upgrade(_config(monkeypatch), TARGET_REVISION)
    try:
        yield engine, admin_engine
    finally:
        engine.dispose()
        cleanup = create_engine(DATABASE_URL)
        try:
            _reset_schemas(cleanup)
        finally:
            cleanup.dispose()
        _drop_roles(admin_engine)
        admin_engine.dispose()


def _attempt_values(tenant_id: str, index: int) -> dict[str, object]:
    return {
        "attempt": uuid.UUID(f"10000000-0000-4000-8000-{index:012d}"),
        "tenant": tenant_id,
        "command": uuid.UUID(f"20000000-0000-4000-8000-{index:012d}"),
        "target": uuid.UUID(f"30000000-0000-4000-8000-{index:012d}"),
        "target_digest": str(index) * 64,
        "principal_digest": str(index + 2) * 64,
        "idempotency_digest": str(index + 4) * 64,
        "command_hash": str(index + 6) * 64,
        "policy_digest": "a" * 64,
        "schema_digest": "b" * 64,
        "expected": 5,
    }


ATTEMPT_INSERT = text(
    """
    INSERT INTO domain_command.itinerary_basic_info_attempts (
      attempt_id, tenant_id, command_id, command_type, target_itinerary_id,
      target_digest, principal_digest, idempotency_digest, command_hash,
      policy_digest, schema_digest, expected_version, state
    ) VALUES (
      :attempt, :tenant, :command, 'itinerary.basic_info.update', :target,
      :target_digest, :principal_digest, :idempotency_digest, :command_hash,
      :policy_digest, :schema_digest, :expected, 'received'
    )
    """
)


def _seed_received(engine: Engine) -> None:
    for index, tenant_id in enumerate(TENANTS, start=1):
        values = _attempt_values(tenant_id, index)
        with engine.begin() as connection:
            connection.execute(
                text("SELECT set_config('app.tenant_id', :tenant, true)"), values
            )
            connection.execute(ATTEMPT_INSERT, values)


def _assume(connection, role: str, tenant_id: str | None) -> None:
    assert role in ROLES
    connection.execute(text(f"SET LOCAL ROLE {role}"))
    if tenant_id is not None:
        connection.execute(
            text("SELECT set_config('app.tenant_id', :tenant, true)"),
            {"tenant": tenant_id},
        )


def test_rls_positive_negative_and_unset_context_matrix(p12d_database) -> None:
    engine, admin_engine = p12d_database
    _seed_received(engine)
    cross_tenant_visible = 0
    for role in ("gonow_command_service", "gonow_observer"):
        for tenant_id in TENANTS:
            with admin_engine.begin() as connection:
                _assume(connection, role, tenant_id)
                rows = connection.execute(
                    text(
                        "SELECT tenant_id FROM "
                        "domain_command.itinerary_basic_info_attempts"
                    )
                ).scalars().all()
                cross_tenant_visible += sum(value != tenant_id for value in rows)
                assert rows == [tenant_id]
    with admin_engine.begin() as connection:
        _assume(connection, "gonow_command_service", None)
        count = connection.scalar(
            text(
                "SELECT count(*) FROM "
                "domain_command.itinerary_basic_info_attempts"
            )
        )
        assert count == 0
    assert cross_tenant_visible == 0


def test_cross_tenant_write_and_observer_write_are_denied(p12d_database) -> None:
    _, admin_engine = p12d_database
    values = _attempt_values(TENANTS[1], 9)
    with pytest.raises(DBAPIError):
        with admin_engine.begin() as connection:
            _assume(connection, "gonow_command_service", TENANTS[0])
            connection.execute(ATTEMPT_INSERT, values)
    with pytest.raises(ProgrammingError):
        with admin_engine.begin() as connection:
            _assume(connection, "gonow_observer", TENANTS[0])
            connection.execute(ATTEMPT_INSERT, _attempt_values(TENANTS[0], 8))


def test_policy_and_least_privilege_catalog(p12d_database) -> None:
    engine, _ = p12d_database
    with engine.connect() as connection:
        policy_count = int(
            connection.scalar(
                text(
                    "SELECT count(*) FROM pg_policies WHERE schemaname=:schema "
                    "AND policyname='tenant_isolation'"
                ),
                {"schema": COMMAND_SCHEMA},
            )
            or 0
        )
        forced_count = int(
            connection.scalar(
                text(
                    "SELECT count(*) FROM pg_class c JOIN pg_namespace n "
                    "ON n.oid=c.relnamespace WHERE n.nspname=:schema "
                    "AND c.relname = ANY(:tables) "
                    "AND c.relrowsecurity AND c.relforcerowsecurity"
                ),
                {"schema": COMMAND_SCHEMA, "tables": list(TABLES)},
            )
            or 0
        )
        public_grants = int(
            connection.scalar(
                text(
                    "SELECT count(*) FROM information_schema.role_table_grants "
                    "WHERE table_schema=:schema AND grantee='PUBLIC'"
                ),
                {"schema": COMMAND_SCHEMA},
            )
            or 0
        )
        unexpected_role_grants = int(
            connection.scalar(
                text(
                    "SELECT count(*) FROM information_schema.role_table_grants "
                    "WHERE table_schema=:schema AND grantee IN "
                    "('gonow_agent_api','gonow_agent_worker','gonow_release_operator')"
                ),
                {"schema": COMMAND_SCHEMA},
            )
            or 0
        )
        observer_write_grants = int(
            connection.scalar(
                text(
                    "SELECT count(*) FROM information_schema.role_table_grants "
                    "WHERE table_schema=:schema AND grantee='gonow_observer' "
                    "AND privilege_type <> 'SELECT'"
                ),
                {"schema": COMMAND_SCHEMA},
            )
            or 0
        )
        command_delete_grants = int(
            connection.scalar(
                text(
                    "SELECT count(*) FROM information_schema.role_table_grants "
                    "WHERE table_schema=:schema AND grantee='gonow_command_service' "
                    "AND privilege_type IN ('DELETE','TRUNCATE','REFERENCES','TRIGGER')"
                ),
                {"schema": COMMAND_SCHEMA},
            )
            or 0
        )
        bypass_count = int(
            connection.scalar(
                text(
                    "SELECT count(*) FROM pg_roles WHERE rolname = ANY(:roles) "
                    "AND (rolsuper OR rolbypassrls)"
                ),
                {"roles": list(ROLES)},
            )
            or 0
        )
    assert policy_count == forced_count == len(TABLES)
    assert public_grants == 0
    assert unexpected_role_grants == 0
    assert observer_write_grants == 0
    assert command_delete_grants == 0
    assert bypass_count == 0


def test_receipt_and_attempt_evidence_cannot_be_deleted_or_rewritten(
    p12d_database,
) -> None:
    engine, _ = p12d_database
    values = _attempt_values(TENANTS[0], 1)
    receipt = uuid.UUID("50000000-0000-4000-8000-000000000001")
    with engine.begin() as connection:
        connection.execute(
            text("SELECT set_config('app.tenant_id', :tenant, true)"), values
        )
        connection.execute(ATTEMPT_INSERT, values)
        connection.execute(
            text(
                "UPDATE domain_command.itinerary_basic_info_attempts "
                "SET state='conflict', resolved_at=statement_timestamp() "
                "WHERE attempt_id=:attempt"
            ),
            values,
        )
        connection.execute(
            text(
                """
                INSERT INTO domain_command.itinerary_basic_info_receipts (
                  receipt_id, tenant_id, attempt_id, command_id, command_type,
                  state, target_digest, principal_digest, idempotency_digest,
                  command_hash, policy_digest, schema_digest, approval_reference,
                  expected_version
                ) VALUES (
                  :receipt, :tenant, :attempt, :command,
                  'itinerary.basic_info.update', 'conflict', :target_digest,
                  :principal_digest, :idempotency_digest, :command_hash,
                  :policy_digest, :schema_digest,
                  'policy:itinerary.basic_info.low-risk:v1', :expected
                )
                """
            ),
            {**values, "receipt": receipt},
        )
    with pytest.raises(DBAPIError, match="receipt_immutable"):
        with engine.begin() as connection:
            connection.execute(
                text("SELECT set_config('app.tenant_id', :tenant, true)"), values
            )
            connection.execute(
                text(
                    "UPDATE domain_command.itinerary_basic_info_receipts "
                    "SET recorded_at=statement_timestamp() WHERE receipt_id=:receipt"
                ),
                {**values, "receipt": receipt},
            )
    with pytest.raises(DBAPIError, match="attempt_delete_forbidden"):
        with engine.begin() as connection:
            connection.execute(
                text("SELECT set_config('app.tenant_id', :tenant, true)"), values
            )
            connection.execute(
                text(
                    "DELETE FROM domain_command.itinerary_basic_info_attempts "
                    "WHERE attempt_id=:attempt"
                ),
                values,
            )
    assert inspect(engine).has_table(
        "itinerary_basic_info_receipts", schema=COMMAND_SCHEMA
    )
