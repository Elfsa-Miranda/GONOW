from __future__ import annotations

import hashlib
import inspect as python_inspect
import json
import os
import site
import subprocess
import sys
import tempfile
import uuid
from datetime import datetime, timezone
from pathlib import Path

import pytest
from alembic import command
from alembic.config import Config
from sqlalchemy import create_engine, inspect, text
from sqlalchemy.engine import Engine, make_url
from sqlalchemy.schema import CreateSchema, DropSchema


SERVICE_ROOT = Path(__file__).resolve().parents[2]
site.addsitedir(str(SERVICE_ROOT / ".venv" / "Lib" / "site-packages"))
sys.path.insert(0, str(SERVICE_ROOT))

from migrations.versions import p12d_001_itinerary_basic_info_commands as migration  # noqa: E402


ALEMBIC_INI = SERVICE_ROOT / "alembic.ini"
TARGET_REVISION = "p12d_001_commands"
VERSION_SCHEMA = "p12d_030_restore_test"
COMMAND_SCHEMA = "domain_command"
DATABASE_URL = os.environ.get(
    "GONOW_P12D_TEST_DATABASE_URL",
    "postgresql+pg8000://gonow_migrator_test@127.0.0.1:55432/gonow_p03_test",
)
ADMIN_DATABASE_URL = (
    "postgresql+pg8000://gonow_bootstrap_admin@127.0.0.1:55432/gonow_p03_test"
)
POSTGRES_BIN = Path(
    os.environ.get("GONOW_P12D_POSTGRES_BIN", r"C:\Program Files\PostgreSQL\17\bin")
)
ROLES = (
    "gonow_agent_api",
    "gonow_agent_worker",
    "gonow_command_service",
    "gonow_release_operator",
    "gonow_observer",
)
SCHEMAS = (COMMAND_SCHEMA, "agent_knowledge", "agent_behavior", "agent_runtime", VERSION_SCHEMA)
TENANTS = ("tenant-p12d-alpha", "tenant-p12d-beta")
FIXTURE_SEED = 12040010


def _assert_isolated() -> None:
    parsed = make_url(DATABASE_URL)
    assert parsed.drivername == "postgresql+pg8000"
    assert parsed.host == "127.0.0.1"
    assert parsed.port == 55432
    assert parsed.username == "gonow_migrator_test"
    assert parsed.database == "gonow_p03_test"
    assert parsed.password is None
    for executable in ("pg_dump.exe", "pg_restore.exe", "postgres.exe"):
        assert (POSTGRES_BIN / executable).is_file()


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


def _uuid(prefix: int, index: int) -> uuid.UUID:
    return uuid.UUID(f"{prefix:08d}-0000-4000-8000-{index:012d}")


def _seed(engine: Engine) -> list[dict[str, object]]:
    fixture: list[dict[str, object]] = []
    for index, tenant_id in enumerate(TENANTS, start=1):
        attempt_id = _uuid(10, index)
        command_id = _uuid(20, index)
        event_id = _uuid(30, index)
        outbox_id = _uuid(40, index)
        receipt_id = _uuid(50, index)
        digest_digit = str(index)
        now = datetime(2026, 8, 4, 9, index, tzinfo=timezone.utc)
        values = {
            "tenant": tenant_id,
            "attempt": attempt_id,
            "command": command_id,
            "target": _uuid(60, index),
            "event": event_id,
            "outbox": outbox_id,
            "receipt": receipt_id,
            "target_digest": digest_digit * 64,
            "principal_digest": str(index + 2) * 64,
            "idempotency_digest": str(index + 4) * 64,
            "command_hash": str(index + 6) * 64,
            "policy_digest": "a" * 64,
            "schema_digest": "b" * 64,
            "payload_digest": "c" * 64,
            "payload_ref": "domain-command-event://sha256/" + ("c" * 64),
            "expected": 5,
            "actual": 6,
            "now": now,
        }
        with engine.begin() as connection:
            connection.execute(text("SELECT set_config('app.tenant_id', :tenant, true)"), values)
            connection.execute(
                text(
                    """
                    INSERT INTO domain_command.itinerary_basic_info_attempts (
                      attempt_id, tenant_id, command_id, command_type,
                      target_itinerary_id, target_digest, principal_digest,
                      idempotency_digest, command_hash, policy_digest, schema_digest,
                      expected_version, state, created_at
                    ) VALUES (
                      :attempt, :tenant, :command, 'itinerary.basic_info.update',
                      :target, :target_digest, :principal_digest,
                      :idempotency_digest, :command_hash, :policy_digest, :schema_digest,
                      :expected, 'received', :now
                    )
                    """
                ),
                values,
            )
            connection.execute(
                text(
                    """
                    INSERT INTO domain_command.itinerary_basic_info_outbox (
                      outbox_id, tenant_id, attempt_id, event_id, event_type,
                      target_digest, payload_ref, payload_digest, state,
                      attempt_count, max_attempts, available_at, created_at
                    ) VALUES (
                      :outbox, :tenant, :attempt, :event,
                      'itinerary.basic_info.updated', :target_digest, :payload_ref,
                      :payload_digest, 'pending', 0, 5, :now, :now
                    )
                    """
                ),
                values,
            )
            connection.execute(
                text(
                    """
                    UPDATE domain_command.itinerary_basic_info_attempts
                    SET state='committed', actual_version=:actual, event_id=:event,
                        outbox_id=:outbox, resolved_at=:now
                    WHERE attempt_id=:attempt
                    """
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
                      expected_version, actual_version, event_id, outbox_id, recorded_at
                    ) VALUES (
                      :receipt, :tenant, :attempt, :command,
                      'itinerary.basic_info.update', 'committed', :target_digest,
                      :principal_digest, :idempotency_digest, :command_hash,
                      :policy_digest, :schema_digest,
                      'policy:itinerary.basic_info.low-risk:v1', :expected, :actual,
                      :event, :outbox, :now
                    )
                    """
                ),
                values,
            )
        fixture.append(
            {
                "tenant_id": tenant_id,
                "attempt_id": str(attempt_id),
                "command_id": str(command_id),
                "event_id": str(event_id),
                "outbox_id": str(outbox_id),
                "receipt_id": str(receipt_id),
                "expected_version": 5,
                "actual_version": 6,
            }
        )
    return fixture


def _logical_rows(engine: Engine) -> list[dict[str, object]]:
    rows: list[dict[str, object]] = []
    queries = {
        "attempt": (
            "SELECT tenant_id, attempt_id::text, command_id::text, state, "
            "expected_version, actual_version, event_id::text, outbox_id::text "
            "FROM domain_command.itinerary_basic_info_attempts"
        ),
        "outbox": (
            "SELECT tenant_id, attempt_id::text, event_id::text, outbox_id::text, "
            "state, attempt_count, max_attempts, payload_digest "
            "FROM domain_command.itinerary_basic_info_outbox"
        ),
        "receipt": (
            "SELECT tenant_id, attempt_id::text, command_id::text, receipt_id::text, "
            "state, expected_version, actual_version, event_id::text, outbox_id::text "
            "FROM domain_command.itinerary_basic_info_receipts"
        ),
    }
    for tenant_id in TENANTS:
        with engine.begin() as connection:
            connection.execute(
                text("SELECT set_config('app.tenant_id', :tenant, true)"),
                {"tenant": tenant_id},
            )
            for kind, query in queries.items():
                for row in connection.execute(text(query)).mappings():
                    rows.append({"kind": kind, **dict(row)})
    return sorted(rows, key=lambda value: json.dumps(value, sort_keys=True))


def _logical_hash(engine: Engine) -> tuple[str, int]:
    rows = _logical_rows(engine)
    encoded = json.dumps(rows, sort_keys=True, separators=(",", ":")).encode()
    return hashlib.sha256(encoded).hexdigest(), len(rows)


def _postgres_uri(username: str) -> str:
    return f"postgresql://{username}@127.0.0.1:55432/gonow_p03_test"


def _restore_ownership() -> None:
    admin_engine = create_engine(ADMIN_DATABASE_URL)
    try:
        with admin_engine.begin() as connection:
            for table_name in migration.TENANT_TABLES:
                connection.execute(
                    text(
                        f"ALTER TABLE {COMMAND_SCHEMA}.{table_name} "
                        "OWNER TO gonow_migrator_test"
                    )
                )
            for function_signature in (
                "guard_basic_info_attempt()",
                "reject_basic_info_receipt_change()",
            ):
                connection.execute(
                    text(
                        f"ALTER FUNCTION {COMMAND_SCHEMA}.{function_signature} "
                        "OWNER TO gonow_migrator_test"
                    )
                )
            connection.execute(
                text(
                    f"ALTER SCHEMA {COMMAND_SCHEMA} OWNER TO gonow_migrator_test"
                )
            )
    finally:
        admin_engine.dispose()


def _dump_restore(engine: Engine) -> tuple[str, str, int, str, str]:
    with tempfile.TemporaryDirectory(prefix="gonow-p12d-030-") as directory:
        dump_path = Path(directory) / "domain-command.dump"
        dump = subprocess.run(
            [
                str(POSTGRES_BIN / "pg_dump.exe"),
                "--dbname",
                _postgres_uri("gonow_bootstrap_admin"),
                "--format=custom",
                "--no-owner",
                "--schema",
                COMMAND_SCHEMA,
                "--file",
                str(dump_path),
            ],
            check=False,
            capture_output=True,
            text=True,
        )
        assert dump.returncode == 0, dump.stderr
        content = dump_path.read_bytes()
        snapshot_sha = hashlib.sha256(content).hexdigest()
        snapshot_size = len(content)
        with engine.begin() as connection:
            connection.execute(DropSchema(COMMAND_SCHEMA, cascade=True))
        restore = subprocess.run(
            [
                str(POSTGRES_BIN / "pg_restore.exe"),
                "--dbname",
                _postgres_uri("gonow_bootstrap_admin"),
                "--no-owner",
                "--exit-on-error",
                str(dump_path),
            ],
            check=False,
            capture_output=True,
            text=True,
        )
        assert restore.returncode == 0, restore.stderr
        _restore_ownership()
    dump_version = subprocess.run(
        [str(POSTGRES_BIN / "pg_dump.exe"), "--version"],
        check=True,
        capture_output=True,
        text=True,
    ).stdout.strip()
    with engine.connect() as connection:
        server_version = str(connection.scalar(text("SELECT version()")))
    return snapshot_sha, dump_version, snapshot_size, restore.stdout.strip(), server_version


def test_expand_only_upgrade_and_restore_preserve_command_evidence(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    _assert_isolated()
    engine = create_engine(DATABASE_URL, pool_pre_ping=True)
    admin_engine = create_engine(ADMIN_DATABASE_URL, pool_pre_ping=True)
    config = _config(monkeypatch)
    try:
        _reset_schemas(engine)
        _provision_roles(admin_engine)
        command.upgrade(config, TARGET_REVISION)
        assert set(inspect(engine).get_table_names(schema=COMMAND_SCHEMA)) == {
            "itinerary_basic_info_attempts",
            "itinerary_basic_info_outbox",
            "itinerary_basic_info_receipts",
        }
        upgrade_source = python_inspect.getsource(migration.upgrade).lower()
        assert "drop_table" not in upgrade_source
        assert "drop schema" not in upgrade_source
        assert "user_itineraries" not in upgrade_source
        fixture = _seed(engine)
        before_hash, before_count = _logical_hash(engine)
        snapshot_sha, dump_version, snapshot_size, _, server_version = _dump_restore(engine)
        after_hash, after_count = _logical_hash(engine)
        assert before_count == after_count == 6
        assert before_hash == after_hash
        assert snapshot_size > 0
        assert snapshot_sha != "0" * 64
        assert dump_version.startswith("pg_dump (PostgreSQL) 17.")
        assert "PostgreSQL 17" in server_version
        fixture_hash = hashlib.sha256(
            json.dumps(fixture, sort_keys=True, separators=(",", ":")).encode()
        ).hexdigest()
        assert len(fixture_hash) == 64
        with pytest.raises(RuntimeError, match="forward-fix only"):
            command.downgrade(config, "p11_008_knowledge_tombstones")
        assert inspect(engine).has_schema(COMMAND_SCHEMA)
    finally:
        engine.dispose()
        cleanup = create_engine(DATABASE_URL)
        try:
            _reset_schemas(cleanup)
        finally:
            cleanup.dispose()
        _drop_roles(admin_engine)
        admin_engine.dispose()
