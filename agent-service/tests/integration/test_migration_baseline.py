from __future__ import annotations

import json
import os
from pathlib import Path

import pytest
from alembic import command
from alembic.config import Config
from sqlalchemy import MetaData, Table, create_engine, func, inspect, select
from sqlalchemy.engine import make_url
from sqlalchemy.schema import CreateSchema, DropSchema


SERVICE_ROOT = Path(__file__).resolve().parents[2]
ALEMBIC_INI = SERVICE_ROOT / "alembic.ini"
BASELINE_REVISION = "p03_001_runtime_baseline"
TEST_SCHEMA = "p03_001_baseline_test"
DATABASE_URL = os.environ.get(
    "GONOW_P03_TEST_DATABASE_URL",
    "postgresql+pg8000://gonow_migrator_test@127.0.0.1:55432/gonow_p03_test",
)
INVENTORY_REPORT_ENV = "GONOW_P03_INVENTORY_REPORT"
EXPECTED_INVENTORY_REPORT = (
    SERVICE_ROOT.parent
    / "docs"
    / "execution"
    / "evidence"
    / "phase-03"
    / "P03-001"
    / "migration-inventory.json"
)


def _assert_task_owned_database() -> None:
    parsed = make_url(DATABASE_URL)
    assert parsed.drivername == "postgresql+pg8000"
    assert parsed.host == "127.0.0.1"
    assert parsed.port == 55432
    assert parsed.username == "gonow_migrator_test"
    assert parsed.database == "gonow_p03_test"
    assert parsed.password is None


def _alembic_config(monkeypatch: pytest.MonkeyPatch) -> Config:
    monkeypatch.setenv("GONOW_DATABASE_URL", DATABASE_URL)
    monkeypatch.setenv("GONOW_ALEMBIC_VERSION_SCHEMA", TEST_SCHEMA)
    return Config(str(ALEMBIC_INI))


def _write_inventory_report(report: dict[str, object]) -> None:
    requested = os.environ.get(INVENTORY_REPORT_ENV, "").strip()
    if not requested:
        return
    target = Path(requested).resolve()
    assert target == EXPECTED_INVENTORY_REPORT.resolve()
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(
        json.dumps(report, sort_keys=True, separators=(",", ":")),
        encoding="utf-8",
    )


def test_migration_environment_fails_closed_without_database_url(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.delenv("GONOW_DATABASE_URL", raising=False)
    monkeypatch.delenv("GONOW_ALEMBIC_VERSION_SCHEMA", raising=False)
    with pytest.raises(RuntimeError, match="GONOW_DATABASE_URL is required"):
        command.current(Config(str(ALEMBIC_INI)))


def test_migration_environment_rejects_unsafe_version_schema(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    _assert_task_owned_database()
    monkeypatch.setenv("GONOW_DATABASE_URL", DATABASE_URL)
    monkeypatch.setenv("GONOW_ALEMBIC_VERSION_SCHEMA", "unsafe;drop schema public")
    with pytest.raises(RuntimeError, match="must be a lowercase PostgreSQL identifier"):
        command.current(Config(str(ALEMBIC_INI)))


def test_migrator_role_and_database_connect_are_least_privilege() -> None:
    _assert_task_owned_database()
    engine = create_engine(DATABASE_URL, pool_pre_ping=True)
    try:
        with engine.connect() as connection:
            roles = Table(
                "pg_roles",
                MetaData(),
                schema="pg_catalog",
                autoload_with=connection,
            )
            role = connection.execute(
                select(
                    roles.c.rolsuper,
                    roles.c.rolcreaterole,
                    roles.c.rolcreatedb,
                    roles.c.rolinherit,
                    roles.c.rolreplication,
                    roles.c.rolcanlogin,
                ).where(roles.c.rolname == "gonow_migrator_test")
            ).one()
            probe_can_connect, migrator_can_connect = connection.execute(
                select(
                    func.has_database_privilege(
                        "gonow_probe_tenant_a", "gonow_p03_test", "CONNECT"
                    ),
                    func.has_database_privilege(
                        "gonow_migrator_test", "gonow_p03_test", "CONNECT"
                    ),
                )
            ).one()
        assert tuple(role) == (False, False, False, False, False, True)
        assert probe_can_connect is False
        assert migrator_can_connect is True
    finally:
        engine.dispose()


def test_empty_baseline_upgrade_is_locked_and_inventory_reviewed(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    _assert_task_owned_database()
    engine = create_engine(DATABASE_URL, pool_pre_ping=True)
    config = _alembic_config(monkeypatch)
    report: dict[str, object] = {
        "schema_version": "1.0",
        "task_id": "TASK-P03-001",
        "postgres_version": "17.10",
        "database": "gonow_p03_test",
        "role": "gonow_migrator_test",
        "test_schema": TEST_SCHEMA,
        "pre_upgrade_tables": [],
        "post_upgrade_tables": [],
        "idempotent_upgrade_tables": [],
        "revision": None,
        "downgrade_version_rows": None,
        "cleanup_schema_present": None,
        "production": False,
    }

    with engine.begin() as connection:
        connection.execute(DropSchema(TEST_SCHEMA, cascade=True, if_exists=True))
        connection.execute(CreateSchema(TEST_SCHEMA))
        pre_inventory = inspect(connection).get_table_names(schema=TEST_SCHEMA)
        report["pre_upgrade_tables"] = pre_inventory
        assert pre_inventory == []

    try:
        command.upgrade(config, BASELINE_REVISION)
        with engine.connect() as connection:
            first_inventory = inspect(connection).get_table_names(schema=TEST_SCHEMA)
            version_table = Table(
                "alembic_version",
                MetaData(),
                schema=TEST_SCHEMA,
                autoload_with=connection,
            )
            revision = connection.execute(select(version_table.c.version_num)).scalar_one()
        report["post_upgrade_tables"] = first_inventory
        report["revision"] = revision
        assert first_inventory == ["alembic_version"]
        assert revision == BASELINE_REVISION

        command.upgrade(config, BASELINE_REVISION)
        with engine.connect() as connection:
            second_inventory = inspect(connection).get_table_names(schema=TEST_SCHEMA)
        report["idempotent_upgrade_tables"] = second_inventory
        assert second_inventory == first_inventory

        command.downgrade(config, "base")
        with engine.connect() as connection:
            version_table = Table(
                "alembic_version",
                MetaData(),
                schema=TEST_SCHEMA,
                autoload_with=connection,
            )
            remaining_rows = connection.execute(
                select(func.count()).select_from(version_table)
            ).scalar_one()
        report["downgrade_version_rows"] = remaining_rows
        assert remaining_rows == 0
    finally:
        with engine.begin() as connection:
            connection.execute(DropSchema(TEST_SCHEMA, cascade=True, if_exists=True))
            report["cleanup_schema_present"] = inspect(connection).has_schema(TEST_SCHEMA)
        engine.dispose()
    _write_inventory_report(report)
