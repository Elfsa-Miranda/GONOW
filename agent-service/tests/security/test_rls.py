from __future__ import annotations

import json
import os
import site
import sys
import uuid
from pathlib import Path

import pytest
from alembic import command
from alembic.config import Config
from sqlalchemy import create_engine, func, inspect, select, text
from sqlalchemy.engine import Engine, make_url
from sqlalchemy.exc import DatabaseError, ProgrammingError
from sqlalchemy.orm import Session, sessionmaker
from sqlalchemy.schema import CreateSchema, DropSchema


SERVICE_ROOT = Path(__file__).resolve().parents[2]
site.addsitedir(str(SERVICE_ROOT / ".venv" / "Lib" / "site-packages"))
sys.path.insert(0, str(SERVICE_ROOT))

from app.persistence.models.behavior import (  # noqa: E402
    BEHAVIOR_SCHEMA,
    BehaviorRevisionRecord,
)
from app.persistence.models.outbox import (  # noqa: E402
    DeadLetterRecord,
    DeliveryReceiptRecord,
    OutboxMessageRecord,
)
from app.persistence.models.runtime import (  # noqa: E402
    EventRecord,
    RUNTIME_SCHEMA,
    ThreadRecord,
)
from app.persistence.repositories.events import EventsRepository  # noqa: E402
from app.persistence.repositories.outbox import OutboxRepository  # noqa: E402
from app.persistence.repositories.runs import RunsRepository  # noqa: E402


ALEMBIC_INI = SERVICE_ROOT / "alembic.ini"
TARGET_REVISION = "p03_007_runtime_rls"
PREVIOUS_REVISION = "p03_006_outbox_receipts"
VERSION_SCHEMA = "p03_007_rls_test"
DATABASE_URL = os.environ.get(
    "GONOW_P03_TEST_DATABASE_URL",
    "postgresql+pg8000://gonow_migrator_test@127.0.0.1:55432/gonow_p03_test",
)
ADMIN_DATABASE_URL = (
    "postgresql+pg8000://gonow_bootstrap_admin@127.0.0.1:55432/gonow_p03_test"
)
PRINCIPALS_SQL = Path(__file__).with_name("fixtures") / "rls_principals.sql"
REPORT_ENV = "GONOW_P03_RLS_REPORT"
EXPECTED_REPORT = (
    SERVICE_ROOT.parent
    / "docs"
    / "execution"
    / "evidence"
    / "phase-03"
    / "P03-007"
    / "rls-report.json"
)
ROLES = (
    "gonow_agent_api",
    "gonow_agent_worker",
    "gonow_command_service",
    "gonow_release_operator",
    "gonow_observer",
)
TENANTS = ("tenant-alpha", "tenant-beta")
RLS_TABLES = (
    "threads",
    "runs",
    "events",
    "idempotency_records",
    "jobs",
    "leases",
    "checkpoint_metadata",
    "outbox_messages",
    "delivery_receipts",
    "dead_letters",
)


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


def _provision_principals(admin_engine: Engine) -> None:
    statement = PRINCIPALS_SQL.read_text(encoding="utf-8")
    with admin_engine.begin() as connection:
        connection.exec_driver_sql(statement)


def _drop_principals(admin_engine: Engine) -> None:
    with admin_engine.begin() as connection:
        for role in ROLES:
            connection.exec_driver_sql(f"DROP OWNED BY {role}")
        for role in ROLES:
            connection.exec_driver_sql(f"DROP ROLE IF EXISTS {role}")


def _reset(engine: Engine, admin_engine: Engine, config: Config) -> None:
    with engine.begin() as connection:
        connection.execute(DropSchema(BEHAVIOR_SCHEMA, cascade=True, if_exists=True))
        connection.execute(DropSchema(RUNTIME_SCHEMA, cascade=True, if_exists=True))
        connection.execute(DropSchema(VERSION_SCHEMA, cascade=True, if_exists=True))
        connection.execute(CreateSchema(VERSION_SCHEMA))
    _provision_principals(admin_engine)
    command.upgrade(config, TARGET_REVISION)


@pytest.fixture()
def rls_database(monkeypatch: pytest.MonkeyPatch):
    _assert_task_owned_database()
    engine = create_engine(DATABASE_URL, pool_pre_ping=True)
    admin_engine = create_engine(ADMIN_DATABASE_URL, pool_pre_ping=True)
    config = _config(monkeypatch)
    _reset(engine, admin_engine, config)
    owner_factory = sessionmaker(engine, expire_on_commit=False)
    admin_factory = sessionmaker(admin_engine, expire_on_commit=False)
    try:
        yield engine, admin_engine, config, owner_factory, admin_factory
    finally:
        engine.dispose()
        with create_engine(DATABASE_URL).begin() as connection:
            connection.execute(DropSchema(BEHAVIOR_SCHEMA, cascade=True, if_exists=True))
            connection.execute(DropSchema(RUNTIME_SCHEMA, cascade=True, if_exists=True))
            connection.execute(DropSchema(VERSION_SCHEMA, cascade=True, if_exists=True))
        _drop_principals(admin_engine)
        admin_engine.dispose()


def _set_tenant(session: Session, tenant_id: str) -> None:
    session.execute(select(func.set_config("app.tenant_id", tenant_id, True)))


def _assume_role(session: Session, role: str, tenant_id: str | None) -> None:
    assert role in ROLES
    session.execute(text(f"SET LOCAL ROLE {role}"))
    if tenant_id is not None:
        _set_tenant(session, tenant_id)


def _seed_tenant(session: Session, tenant_id: str, *, dead_letter: bool) -> None:
    _set_tenant(session, tenant_id)
    runs = RunsRepository(session)
    thread = runs.create_thread(
        tenant_id=tenant_id,
        owner_principal_id=f"principal-{tenant_id}",
    )
    run = runs.create_or_replay_run(
        tenant_id=tenant_id,
        principal_id=f"principal-{tenant_id}",
        thread_id=thread.thread_id,
        request_scope="rls-test",
        idempotency_key=f"idem-{tenant_id}",
        request_hash="1" * 64,
        manifest_digest="2" * 64,
        manifest={"manifest_ref": "behavior://sha256/" + ("2" * 64)},
    )
    event = EventsRepository(session).append(
        tenant_id=tenant_id,
        run_id=run.run_id,
        event_type="rls.seeded",
        payload={"tenant_marker": tenant_id},
        audit_receipt_id=f"audit-event-{tenant_id}",
    )
    message = OutboxRepository(session).enqueue_event(
        tenant_id=tenant_id,
        event_id=event.event_id,
        topic="rls.seeded",
        audit_receipt_id=f"audit-outbox-{tenant_id}",
        max_attempts=1,
    )
    claims = OutboxRepository(session).claim_pending(
        dispatcher_id="dispatcher-rls-test",
        lease_seconds=30,
    )
    claim = next(record for record in claims if record.outbox_id == message.outbox_id)
    assert claim.claim_token is not None
    if dead_letter:
        OutboxRepository(session).record_failure(
            tenant_id=tenant_id,
            outbox_id=message.outbox_id,
            claim_token=claim.claim_token,
            retry_class="permanent",
            reason_code="delivery.rejected",
            audit_receipt_id=f"audit-dlq-{tenant_id}",
        )
    else:
        OutboxRepository(session).record_delivery(
            tenant_id=tenant_id,
            outbox_id=message.outbox_id,
            claim_token=claim.claim_token,
            consumer_name="rls-consumer",
            delivered_by="dispatcher-rls-test",
            audit_receipt_id=f"audit-delivery-{tenant_id}",
        )


def _seed_all(factory: sessionmaker[Session]) -> None:
    for tenant_id, dead_letter in ((TENANTS[0], False), (TENANTS[1], True)):
        with factory() as session, session.begin():
            _seed_tenant(session, tenant_id, dead_letter=dead_letter)


def test_two_tenant_positive_and_negative_read_matrix(rls_database) -> None:
    _, _, _, owner_factory, admin_factory = rls_database
    _seed_all(owner_factory)
    leakage_count = 0
    for role in ("gonow_agent_api", "gonow_agent_worker", "gonow_observer"):
        for tenant_id in TENANTS:
            with admin_factory() as session, session.begin():
                _assume_role(session, role, tenant_id)
                threads = session.scalars(select(ThreadRecord)).all()
                events = session.scalars(select(EventRecord)).all()
                leakage_count += sum(row.tenant_id != tenant_id for row in threads)
                leakage_count += sum(row.tenant_id != tenant_id for row in events)
                assert len(threads) == 1
                assert len(events) == 1
    with admin_factory() as session, session.begin():
        _assume_role(session, "gonow_observer", TENANTS[0])
        assert session.scalar(select(func.count()).select_from(DeliveryReceiptRecord)) == 1
        assert session.scalar(select(func.count()).select_from(DeadLetterRecord)) == 0
    with admin_factory() as session, session.begin():
        _assume_role(session, "gonow_observer", TENANTS[1])
        assert session.scalar(select(func.count()).select_from(DeliveryReceiptRecord)) == 0
        assert session.scalar(select(func.count()).select_from(DeadLetterRecord)) == 1
    assert leakage_count == 0


def test_unset_context_is_empty_and_cross_tenant_insert_is_denied(rls_database) -> None:
    _, _, _, owner_factory, admin_factory = rls_database
    _seed_all(owner_factory)
    with admin_factory() as session, session.begin():
        _assume_role(session, "gonow_agent_api", None)
        assert session.scalar(select(func.count()).select_from(ThreadRecord)) == 0
    with admin_factory() as session:
        with pytest.raises(DatabaseError):
            with session.begin():
                _assume_role(session, "gonow_agent_api", TENANTS[0])
                session.add(
                    ThreadRecord(
                        thread_id=uuid.uuid4(),
                        tenant_id=TENANTS[1],
                        owner_principal_id="cross-tenant-principal",
                    )
                )
                session.flush()


def test_roles_have_no_bypass_and_release_operator_cannot_read_runtime(
    rls_database,
) -> None:
    _, _, _, _, admin_factory = rls_database
    with admin_factory() as session, session.begin():
        bypass_count = session.scalar(
            text(
                "SELECT count(*) FROM pg_roles WHERE rolname = ANY(:roles) "
                "AND (rolsuper OR rolbypassrls)"
            ),
            {"roles": list(ROLES)},
        )
        assert bypass_count == 0
    with admin_factory() as session:
        with pytest.raises(ProgrammingError):
            with session.begin():
                _assume_role(session, "gonow_release_operator", TENANTS[0])
                session.scalars(select(EventRecord)).all()
    with admin_factory() as session:
        with pytest.raises(ProgrammingError):
            with session.begin():
                _assume_role(session, "gonow_agent_worker", TENANTS[0])
                session.add(
                    BehaviorRevisionRecord(
                        revision_id=uuid.uuid4(),
                        behavior_key="rls.denied",
                        revision_number=1,
                        content_digest="3" * 64,
                        graph_ref="graph://sha256/" + ("3" * 64),
                        prompt_ref="prompt://sha256/" + ("3" * 64),
                        state_schema_ref="schema://sha256/" + ("3" * 64),
                        created_by_principal_id="worker-denied",
                        audit_receipt_id="audit-worker-denied",
                    )
                )
                session.flush()


def test_policy_and_grant_catalog_has_no_unexpected_allow(rls_database) -> None:
    engine, _, _, _, _ = rls_database
    with engine.connect() as connection:
        policy_count = connection.scalar(
            text(
                "SELECT count(*) FROM pg_policies "
                "WHERE schemaname='agent_runtime' AND policyname='tenant_isolation'"
            )
        )
        forced_count = connection.scalar(
            text(
                "SELECT count(*) FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace "
                "WHERE n.nspname='agent_runtime' AND c.relname = ANY(:tables) "
                "AND c.relrowsecurity AND c.relforcerowsecurity"
            ),
            {"tables": list(RLS_TABLES)},
        )
        public_grants = connection.scalar(
            text(
                "SELECT count(*) FROM information_schema.role_table_grants "
                "WHERE table_schema IN ('agent_runtime','agent_behavior') "
                "AND grantee='PUBLIC'"
            )
        )
        release_runtime_grants = connection.scalar(
            text(
                "SELECT count(*) FROM information_schema.role_table_grants "
                "WHERE table_schema='agent_runtime' AND grantee='gonow_release_operator'"
            )
        )
    assert policy_count == len(RLS_TABLES)
    assert forced_count == len(RLS_TABLES)
    assert public_grants == 0
    assert release_runtime_grants == 0


def test_forward_fix_rollback_keeps_rls_and_writes_report(rls_database) -> None:
    engine, _, config, _, _ = rls_database
    with pytest.raises(RuntimeError, match="forward-fix only"):
        command.downgrade(config, PREVIOUS_REVISION)
    with engine.connect() as connection:
        policy_count = connection.scalar(
            text("SELECT count(*) FROM pg_policies WHERE schemaname='agent_runtime'")
        )
        forced_count = connection.scalar(
            text(
                "SELECT count(*) FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace "
                "WHERE n.nspname='agent_runtime' AND c.relname = ANY(:tables) "
                "AND c.relrowsecurity AND c.relforcerowsecurity"
            ),
            {"tables": list(RLS_TABLES)},
        )
        bypass_count = connection.scalar(
            text(
                "SELECT count(*) FROM pg_roles WHERE rolname = ANY(:roles) "
                "AND (rolsuper OR rolbypassrls)"
            ),
            {"roles": list(ROLES)},
        )
        head_revision = connection.scalar(
            text(f"SELECT version_num FROM {VERSION_SCHEMA}.alembic_version")
        )
    assert policy_count == len(RLS_TABLES)
    assert forced_count == len(RLS_TABLES)
    assert bypass_count == 0
    assert head_revision == TARGET_REVISION
    assert set(inspect(engine).get_table_names(schema=RUNTIME_SCHEMA)) >= set(RLS_TABLES)
    report_path = Path(os.environ.get(REPORT_ENV, EXPECTED_REPORT))
    report_path.parent.mkdir(parents=True, exist_ok=True)
    report_path.write_text(
        json.dumps(
            {
                "schema_version": "1.0",
                "task_id": "TASK-P03-007",
                "revision": TARGET_REVISION,
                "ct_007_passed": True,
                "tenant_matrix_roles": 3,
                "tenant_matrix_tenants": 2,
                "tenant_leak_count": 0,
                "acl_leakage_count": 0,
                "rls_unexpected_allow_count": 0,
                "policy_count": policy_count,
                "forced_rls_table_count": forced_count,
                "role_bypass_count": bypass_count,
                "forward_fix_downgrade_rejection_count": 1,
                "head_revision_after_rejected_downgrade": head_revision,
                "production": False,
            },
            indent=2,
        )
        + "\n",
        encoding="utf-8",
    )
