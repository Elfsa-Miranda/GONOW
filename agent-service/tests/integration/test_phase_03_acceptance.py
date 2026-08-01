from __future__ import annotations

import os
import site
import sys
import uuid
from pathlib import Path

import pytest
from alembic import command
from alembic.config import Config
from sqlalchemy import create_engine, func, select, text
from sqlalchemy.engine import Engine, make_url
from sqlalchemy.orm import Session, sessionmaker
from sqlalchemy.schema import CreateSchema, DropSchema


SERVICE_ROOT = Path(__file__).resolve().parents[2]
site.addsitedir(str(SERVICE_ROOT / ".venv" / "Lib" / "site-packages"))
sys.path.insert(0, str(SERVICE_ROOT))

from app.persistence.models.behavior import BEHAVIOR_SCHEMA  # noqa: E402
from app.persistence.models.runtime import RUNTIME_SCHEMA, RunRecord, RunState  # noqa: E402
from app.persistence.repositories.runs import RunsRepository  # noqa: E402


ALEMBIC_INI = SERVICE_ROOT / "alembic.ini"
TARGET_REVISION = "p03_007_runtime_rls"
VERSION_SCHEMA = "p03_990_acceptance_test"
DATABASE_URL = os.environ.get(
    "GONOW_P03_TEST_DATABASE_URL",
    "postgresql+pg8000://gonow_migrator_test@127.0.0.1:55432/gonow_p03_test",
)
ADMIN_DATABASE_URL = (
    "postgresql+pg8000://gonow_bootstrap_admin@127.0.0.1:55432/gonow_p03_test"
)
PRINCIPALS_SQL = (
    SERVICE_ROOT / "tests" / "security" / "fixtures" / "rls_principals.sql"
)
ROLES = (
    "gonow_agent_api",
    "gonow_agent_worker",
    "gonow_command_service",
    "gonow_release_operator",
    "gonow_observer",
)
TENANT = "tenant-p03-990-rollback"
PRINCIPAL = "principal-p03-990-rollback"


def _assert_task_owned_database() -> None:
    parsed = make_url(DATABASE_URL)
    assert parsed.drivername == "postgresql+pg8000"
    assert parsed.host == "127.0.0.1"
    assert parsed.port == 55432
    assert parsed.username == "gonow_migrator_test"
    assert parsed.database == "gonow_p03_test"
    assert parsed.password is None


def _provision_principals(admin_engine: Engine) -> None:
    with admin_engine.begin() as connection:
        connection.exec_driver_sql(PRINCIPALS_SQL.read_text(encoding="utf-8"))


def _drop_principals(admin_engine: Engine) -> None:
    with admin_engine.begin() as connection:
        for role in ROLES:
            connection.exec_driver_sql(f"DROP OWNED BY {role}")
        for role in ROLES:
            connection.exec_driver_sql(f"DROP ROLE IF EXISTS {role}")


def _drop_schemas(engine: Engine) -> None:
    with engine.begin() as connection:
        connection.execute(DropSchema(BEHAVIOR_SCHEMA, cascade=True, if_exists=True))
        connection.execute(DropSchema(RUNTIME_SCHEMA, cascade=True, if_exists=True))
        connection.execute(DropSchema(VERSION_SCHEMA, cascade=True, if_exists=True))


def _set_tenant(session: Session) -> None:
    session.execute(select(func.set_config("app.tenant_id", TENANT, True)))


@pytest.fixture(scope="module")
def rollback_scenarios() -> dict[str, object]:
    _assert_task_owned_database()
    patch = pytest.MonkeyPatch()
    patch.setenv("GONOW_DATABASE_URL", DATABASE_URL)
    patch.setenv("GONOW_ALEMBIC_VERSION_SCHEMA", VERSION_SCHEMA)
    engine = create_engine(DATABASE_URL, pool_pre_ping=True)
    admin_engine = create_engine(ADMIN_DATABASE_URL, pool_pre_ping=True)
    config = Config(str(ALEMBIC_INI))
    _drop_schemas(engine)
    with engine.begin() as connection:
        connection.execute(CreateSchema(VERSION_SCHEMA))
    _provision_principals(admin_engine)
    command.upgrade(config, TARGET_REVISION)
    factory = sessionmaker(engine, expire_on_commit=False)
    try:
        with factory.begin() as session:
            _set_tenant(session)
            idle_run_count = int(
                session.scalar(select(func.count()).select_from(RunRecord)) or 0
            )
            repository = RunsRepository(session)
            thread = repository.create_thread(
                tenant_id=TENANT,
                owner_principal_id=PRINCIPAL,
            )
            for index in range(3):
                run = repository.create_or_replay_run(
                    tenant_id=TENANT,
                    principal_id=PRINCIPAL,
                    thread_id=thread.thread_id,
                    request_scope="phase03.rollback",
                    idempotency_key=f"in-flight-{index}",
                    request_hash=str(index + 1) * 64,
                    manifest_digest=str(index + 4) * 64,
                    manifest={"fixture": "p03-990", "generation": 1},
                    run_id=uuid.UUID(f"30000000-0000-4000-8000-{index + 1:012d}"),
                )
                repository.transition_state(
                    tenant_id=TENANT,
                    run_id=run.run_id,
                    expected_state=RunState.QUEUED,
                    expected_version=1,
                    target_state=RunState.RUNNING,
                )

        with factory.begin() as session:
            _set_tenant(session)
            current_records = session.scalars(
                select(RunRecord).order_by(RunRecord.run_id)
            ).all()

        # Reconnect and use only the stable pre-Phase-4 projection. This exercises
        # the compatibility contract an older reader relies on after app rollback.
        engine.dispose()
        rollback_engine = create_engine(DATABASE_URL, pool_pre_ping=True)
        with rollback_engine.begin() as connection:
            connection.execute(text("SELECT set_config('app.tenant_id', :tenant, true)"), {"tenant": TENANT})
            old_reader_rows = connection.execute(
                text(
                    "SELECT run_id::text, state, version, manifest_digest "
                    "FROM agent_runtime.runs WHERE tenant_id=:tenant ORDER BY run_id"
                ),
                {"tenant": TENANT},
            ).mappings().all()
        rollback_engine.dispose()

        yield {
            "idle_run_count": idle_run_count,
            "current_records": current_records,
            "old_reader_rows": old_reader_rows,
        }
    finally:
        cleanup_engine = create_engine(DATABASE_URL)
        try:
            _drop_schemas(cleanup_engine)
        finally:
            cleanup_engine.dispose()
        _drop_principals(admin_engine)
        admin_engine.dispose()
        patch.undo()


def test_idle_rollback_boundary_has_no_runtime_side_effects(rollback_scenarios) -> None:
    assert rollback_scenarios["idle_run_count"] == 0


def test_three_in_flight_runs_survive_rollback_boundary(rollback_scenarios) -> None:
    records = rollback_scenarios["current_records"]
    assert len(records) == 3
    assert {record.state for record in records} == {RunState.RUNNING.value}
    assert {record.version for record in records} == {2}


def test_old_reader_projection_reads_new_runtime_rows(rollback_scenarios) -> None:
    rows = rollback_scenarios["old_reader_rows"]
    assert len(rows) == 3
    assert {row["state"] for row in rows} == {RunState.RUNNING.value}
    assert {row["version"] for row in rows} == {2}
    assert all(len(row["manifest_digest"]) == 64 for row in rows)
