from __future__ import annotations

import hashlib
import json
import os
import site
import subprocess
import sys
import tempfile
import uuid
from pathlib import Path

import pytest
from alembic import command
from alembic.config import Config
from sqlalchemy import create_engine, func, inspect, select, text
from sqlalchemy.engine import Engine, make_url
from sqlalchemy.orm import Session, sessionmaker
from sqlalchemy.schema import CreateSchema, DropSchema


SERVICE_ROOT = Path(__file__).resolve().parents[2]
site.addsitedir(str(SERVICE_ROOT / ".venv" / "Lib" / "site-packages"))
sys.path.insert(0, str(SERVICE_ROOT))

from app.persistence.models.behavior import BEHAVIOR_SCHEMA  # noqa: E402
from app.persistence.models.runtime import (  # noqa: E402
    EventRecord,
    IdempotencyRecord,
    RUNTIME_SCHEMA,
    RunRecord,
    ThreadRecord,
)
from app.persistence.repositories.events import EventsRepository  # noqa: E402
from app.persistence.repositories.runs import RunsRepository  # noqa: E402


ALEMBIC_INI = SERVICE_ROOT / "alembic.ini"
PRE_RLS_REVISION = "p03_006_outbox_receipts"
TARGET_REVISION = "p03_007_runtime_rls"
VERSION_SCHEMA = "p03_009_restore_test"
DATABASE_URL = os.environ.get(
    "GONOW_P03_TEST_DATABASE_URL",
    "postgresql+pg8000://gonow_migrator_test@127.0.0.1:55432/gonow_p03_test",
)
ADMIN_DATABASE_URL = (
    "postgresql+pg8000://gonow_bootstrap_admin@127.0.0.1:55432/gonow_p03_test"
)
POSTGRES_BIN = Path(
    os.environ.get("GONOW_P03_009_POSTGRES_BIN", r"C:\Program Files\PostgreSQL\17\bin")
)
REPORT_ENV = "GONOW_P03_009_REPORT"
EXPECTED_REPORT = (
    SERVICE_ROOT.parent
    / "docs"
    / "execution"
    / "evidence"
    / "phase-03"
    / "P03-009"
    / "backup-restore-report.json"
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
TENANTS = ("tenant-restore-alpha", "tenant-restore-beta")
ADVISORY_LOCK_KEY = 7390009
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


def _assert_isolated_environment() -> None:
    parsed = make_url(DATABASE_URL)
    assert parsed.drivername == "postgresql+pg8000"
    assert parsed.host == "127.0.0.1"
    assert parsed.port == 55432
    assert parsed.username == "gonow_migrator_test"
    assert parsed.database == "gonow_p03_test"
    assert parsed.password is None
    for tool_name in ("pg_dump.exe", "pg_restore.exe", "psql.exe"):
        assert (POSTGRES_BIN / tool_name).is_file()


def _postgres_uri() -> str:
    return "postgresql://gonow_migrator_test@127.0.0.1:55432/gonow_p03_test"


def _config(patch: pytest.MonkeyPatch) -> Config:
    patch.setenv("GONOW_DATABASE_URL", DATABASE_URL)
    patch.setenv("GONOW_ALEMBIC_VERSION_SCHEMA", VERSION_SCHEMA)
    return Config(str(ALEMBIC_INI))


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


def _prepare_empty(engine: Engine) -> None:
    _drop_schemas(engine)
    with engine.begin() as connection:
        connection.execute(CreateSchema(VERSION_SCHEMA))


def _set_tenant(session: Session, tenant_id: str) -> None:
    session.execute(select(func.set_config("app.tenant_id", tenant_id, True)))


def _seed_existing_data(factory: sessionmaker[Session]) -> None:
    for index, tenant_id in enumerate(TENANTS, start=1):
        with factory.begin() as session:
            _set_tenant(session, tenant_id)
            repository = RunsRepository(session)
            thread = repository.create_thread(
                tenant_id=tenant_id,
                owner_principal_id=f"principal-{tenant_id}",
                thread_id=uuid.UUID(f"00000000-0000-4000-8000-{index:012d}"),
            )
            run = repository.create_or_replay_run(
                tenant_id=tenant_id,
                principal_id=f"principal-{tenant_id}",
                thread_id=thread.thread_id,
                request_scope="restore.rehearsal",
                idempotency_key=f"restore-key-{tenant_id}",
                request_hash=str(index) * 64,
                manifest_digest=str(index + 2) * 64,
                manifest={"fixture": "p03-009", "tenant_marker": tenant_id},
                run_id=uuid.UUID(f"10000000-0000-4000-8000-{index:012d}"),
            )
            EventsRepository(session).append(
                tenant_id=tenant_id,
                run_id=run.run_id,
                event_type="restore.seeded",
                payload={"tenant_marker": tenant_id},
                audit_receipt_id=f"audit-restore-{index}",
                event_id=uuid.UUID(f"20000000-0000-4000-8000-{index:012d}"),
            )


def _logical_rows(factory: sessionmaker[Session], *, rls_enabled: bool) -> list[dict[str, object]]:
    rows: list[dict[str, object]] = []
    tenant_scope = TENANTS if rls_enabled else ("",)
    for tenant_id in tenant_scope:
        with factory.begin() as session:
            if rls_enabled:
                _set_tenant(session, tenant_id)
            threads = session.scalars(select(ThreadRecord).order_by(ThreadRecord.thread_id)).all()
            runs = session.scalars(select(RunRecord).order_by(RunRecord.run_id)).all()
            events = session.scalars(select(EventRecord).order_by(EventRecord.event_id)).all()
            idempotency = session.scalars(
                select(IdempotencyRecord).order_by(IdempotencyRecord.idempotency_id)
            ).all()
        rows.extend(
            {
                "kind": "thread",
                "tenant_id": record.tenant_id,
                "thread_id": str(record.thread_id),
                "owner": record.owner_principal_id,
            }
            for record in threads
        )
        rows.extend(
            {
                "kind": "run",
                "tenant_id": record.tenant_id,
                "run_id": str(record.run_id),
                "thread_id": str(record.thread_id),
                "state": record.state,
                "version": record.version,
                "next_event_seq": record.next_event_seq,
                "manifest_digest": record.manifest_digest,
            }
            for record in runs
        )
        rows.extend(
            {
                "kind": "event",
                "tenant_id": record.tenant_id,
                "event_id": str(record.event_id),
                "run_id": str(record.run_id),
                "seq": record.seq,
                "event_type": record.event_type,
                "audit_receipt_id": record.audit_receipt_id,
            }
            for record in events
        )
        rows.extend(
            {
                "kind": "idempotency",
                "tenant_id": record.tenant_id,
                "principal_id": record.principal_id,
                "request_scope": record.request_scope,
                "idempotency_key": record.idempotency_key,
                "request_hash": record.request_hash,
                "run_id": str(record.run_id),
            }
            for record in idempotency
        )
    return sorted(rows, key=lambda item: json.dumps(item, sort_keys=True))


def _logical_hash(factory: sessionmaker[Session], *, rls_enabled: bool) -> tuple[str, int]:
    rows = _logical_rows(factory, rls_enabled=rls_enabled)
    payload = json.dumps(rows, sort_keys=True, separators=(",", ":")).encode("utf-8")
    return hashlib.sha256(payload).hexdigest(), len(rows)


def _dump_snapshot(target: Path) -> tuple[str, int, str]:
    command_line = [
        str(POSTGRES_BIN / "pg_dump.exe"),
        "--dbname",
        _postgres_uri(),
        "--format=custom",
        "--no-owner",
        "--no-privileges",
        "--schema",
        RUNTIME_SCHEMA,
        "--schema",
        BEHAVIOR_SCHEMA,
        "--schema",
        VERSION_SCHEMA,
        "--file",
        str(target),
    ]
    completed = subprocess.run(command_line, check=False, capture_output=True, text=True)
    assert completed.returncode == 0, completed.stderr
    content = target.read_bytes()
    version = subprocess.run(
        [str(POSTGRES_BIN / "pg_dump.exe"), "--version"],
        check=True,
        capture_output=True,
        text=True,
    ).stdout.strip()
    return hashlib.sha256(content).hexdigest(), len(content), version


def _restore_snapshot(source: Path) -> str:
    completed = subprocess.run(
        [
            str(POSTGRES_BIN / "pg_restore.exe"),
            "--dbname",
            _postgres_uri(),
            "--no-owner",
            "--no-privileges",
            "--exit-on-error",
            str(source),
        ],
        check=False,
        capture_output=True,
        text=True,
    )
    assert completed.returncode == 0, completed.stderr
    return subprocess.run(
        [str(POSTGRES_BIN / "pg_restore.exe"), "--version"],
        check=True,
        capture_output=True,
        text=True,
    ).stdout.strip()


def _assert_migration_lock(engine: Engine) -> tuple[bool, bool, bool]:
    first = engine.connect()
    second = engine.connect()
    try:
        first_acquired = bool(
            first.scalar(text("SELECT pg_try_advisory_lock(:lock_key)"), {"lock_key": ADVISORY_LOCK_KEY})
        )
        second_blocked = not bool(
            second.scalar(text("SELECT pg_try_advisory_lock(:lock_key)"), {"lock_key": ADVISORY_LOCK_KEY})
        )
        first.scalar(text("SELECT pg_advisory_unlock(:lock_key)"), {"lock_key": ADVISORY_LOCK_KEY})
        second_acquired_after_release = bool(
            second.scalar(text("SELECT pg_try_advisory_lock(:lock_key)"), {"lock_key": ADVISORY_LOCK_KEY})
        )
        second.scalar(text("SELECT pg_advisory_unlock(:lock_key)"), {"lock_key": ADVISORY_LOCK_KEY})
        return first_acquired, second_blocked, second_acquired_after_release
    finally:
        first.close()
        second.close()


def _rls_grant_checks(engine: Engine, admin_engine: Engine) -> dict[str, int]:
    with engine.connect() as connection:
        policy_count = int(
            connection.scalar(
                text("SELECT count(*) FROM pg_policies WHERE schemaname='agent_runtime'")
            )
            or 0
        )
        forced_count = int(
            connection.scalar(
                text(
                    "SELECT count(*) FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace "
                    "WHERE n.nspname='agent_runtime' AND c.relname = ANY(:tables) "
                    "AND c.relrowsecurity AND c.relforcerowsecurity"
                ),
                {"tables": list(RLS_TABLES)},
            )
            or 0
        )
        public_grant_count = int(
            connection.scalar(
                text(
                    "SELECT count(*) FROM information_schema.role_table_grants "
                    "WHERE table_schema IN ('agent_runtime','agent_behavior') "
                    "AND grantee='PUBLIC'"
                )
            )
            or 0
        )
    observer_counts: list[int] = []
    admin_factory = sessionmaker(admin_engine)
    for tenant_id in TENANTS:
        with admin_factory.begin() as session:
            session.execute(text("SET LOCAL ROLE gonow_observer"))
            _set_tenant(session, tenant_id)
            observer_counts.append(
                int(session.scalar(select(func.count()).select_from(ThreadRecord)) or 0)
            )
    return {
        "policy_count": policy_count,
        "forced_rls_table_count": forced_count,
        "public_grant_count": public_grant_count,
        "observer_tenant_count_min": min(observer_counts),
        "observer_tenant_count_max": max(observer_counts),
        "tenant_leak_count": sum(count != 1 for count in observer_counts),
    }


def _write_report(value: dict[str, object]) -> None:
    requested = os.environ.get(REPORT_ENV, "").strip()
    if not requested:
        return
    target = Path(requested).resolve()
    assert target == EXPECTED_REPORT.resolve()
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(
        json.dumps(value, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )


def test_snapshot_upgrade_forward_fix_restore_and_rls_revalidation() -> None:
    _assert_isolated_environment()
    patch = pytest.MonkeyPatch()
    engine = create_engine(DATABASE_URL, pool_pre_ping=True)
    admin_engine = create_engine(ADMIN_DATABASE_URL, pool_pre_ping=True)
    config = _config(patch)
    empty_upgrade_failures = 0
    existing_upgrade_failures = 0
    restore_verification_failures = 0
    forward_fix_rejection_count = 0
    try:
        _prepare_empty(engine)
        _provision_principals(admin_engine)
        command.upgrade(config, TARGET_REVISION)
        with engine.connect() as connection:
            empty_tables = set(inspect(connection).get_table_names(schema=RUNTIME_SCHEMA))
        if set(RLS_TABLES) - empty_tables:
            empty_upgrade_failures += 1

        _prepare_empty(engine)
        command.upgrade(config, PRE_RLS_REVISION)
        factory = sessionmaker(engine, expire_on_commit=False)
        _seed_existing_data(factory)
        before_hash, logical_row_count = _logical_hash(factory, rls_enabled=False)
        with tempfile.TemporaryDirectory(prefix="gonow-p03-009-") as temporary_directory:
            snapshot_path = Path(temporary_directory) / "runtime-pre-rls.dump"
            snapshot_sha256, snapshot_size_bytes, pg_dump_version = _dump_snapshot(
                snapshot_path
            )
            command.upgrade(config, TARGET_REVISION)
            after_upgrade_hash, upgraded_row_count = _logical_hash(
                factory, rls_enabled=True
            )
            if before_hash != after_upgrade_hash or logical_row_count != upgraded_row_count:
                existing_upgrade_failures += 1

            lock_first, lock_second_blocked, lock_after_release = _assert_migration_lock(
                engine
            )
            try:
                command.downgrade(config, PRE_RLS_REVISION)
            except RuntimeError as error:
                assert "forward-fix only" in str(error)
                forward_fix_rejection_count += 1
            else:
                existing_upgrade_failures += 1

            engine.dispose()
            cleanup_engine = create_engine(DATABASE_URL)
            try:
                _drop_schemas(cleanup_engine)
            finally:
                cleanup_engine.dispose()
            pg_restore_version = _restore_snapshot(snapshot_path)
            command.upgrade(config, TARGET_REVISION)
            engine = create_engine(DATABASE_URL, pool_pre_ping=True)
            factory = sessionmaker(engine, expire_on_commit=False)
            restored_hash, restored_row_count = _logical_hash(factory, rls_enabled=True)
            restore_hash_mismatch = int(
                restored_hash != before_hash or restored_row_count != logical_row_count
            )
            restore_verification_failures += restore_hash_mismatch
            rls_checks = _rls_grant_checks(engine, admin_engine)
            ct_007_passed = (
                rls_checks["policy_count"] == len(RLS_TABLES)
                and rls_checks["forced_rls_table_count"] == len(RLS_TABLES)
                and rls_checks["public_grant_count"] == 0
                and rls_checks["tenant_leak_count"] == 0
                and rls_checks["observer_tenant_count_min"] == 1
                and rls_checks["observer_tenant_count_max"] == 1
            )
            if not ct_007_passed:
                restore_verification_failures += 1

        assert empty_upgrade_failures == 0
        assert existing_upgrade_failures == 0
        assert restore_verification_failures == 0
        assert restore_hash_mismatch == 0
        assert forward_fix_rejection_count == 1
        assert (lock_first, lock_second_blocked, lock_after_release) == (True, True, True)
        assert ct_007_passed
        _write_report(
            {
                "schema_version": "1.0",
                "task_id": "TASK-P03-009",
                "empty_upgrade_failures": empty_upgrade_failures,
                "existing_upgrade_failures": existing_upgrade_failures,
                "restore_hash_mismatch": restore_hash_mismatch,
                "restore_verification_failures": restore_verification_failures,
                "forward_fix_rejection_count": forward_fix_rejection_count,
                "logical_row_count": logical_row_count,
                "upgraded_row_count": upgraded_row_count,
                "restored_row_count": restored_row_count,
                "snapshot_sha256": snapshot_sha256,
                "snapshot_size_bytes": snapshot_size_bytes,
                "logical_hash_before": before_hash,
                "logical_hash_after_upgrade": after_upgrade_hash,
                "logical_hash_after_restore": restored_hash,
                "migration_lock_first_acquired": lock_first,
                "migration_lock_second_blocked": lock_second_blocked,
                "migration_lock_after_release_acquired": lock_after_release,
                "ct_007": "passed" if ct_007_passed else "failed",
                **rls_checks,
                "pg_dump_version": pg_dump_version,
                "pg_restore_version": pg_restore_version,
                "rpo_status": "unknown_not_claimed",
                "rto_status": "unknown_not_claimed",
                "production": False,
            }
        )
    finally:
        engine.dispose()
        cleanup_engine = create_engine(DATABASE_URL)
        try:
            _drop_schemas(cleanup_engine)
        finally:
            cleanup_engine.dispose()
        _drop_principals(admin_engine)
        admin_engine.dispose()
        patch.undo()
