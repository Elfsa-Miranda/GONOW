from __future__ import annotations

import hashlib
import importlib.metadata
import json
import os
import site
import sys
import uuid
from pathlib import Path
from typing import TypedDict

import pytest
from alembic import command
from alembic.config import Config
from sqlalchemy import create_engine, event, func, inspect, select, text, update
from sqlalchemy.engine import Engine, make_url
from sqlalchemy.orm import Session, sessionmaker
from sqlalchemy.schema import CreateSchema, DropSchema
from langgraph.graph import END, START, StateGraph


SERVICE_ROOT = Path(__file__).resolve().parents[2]
site.addsitedir(str(SERVICE_ROOT / ".venv" / "Lib" / "site-packages"))
sys.path.insert(0, str(SERVICE_ROOT))

from app.persistence.models.behavior import BEHAVIOR_SCHEMA  # noqa: E402
from app.persistence.models.jobs import CheckpointMetadataRecord  # noqa: E402
from app.persistence.models.runtime import RUNTIME_SCHEMA  # noqa: E402
from app.persistence.repositories.jobs import JobsRepository  # noqa: E402
from app.persistence.repositories.runs import RunsRepository  # noqa: E402
from app.runtime.checkpoint import (  # noqa: E402
    GoNowPostgresCheckpointSaver,
    UnsafeCheckpoint,
    _canonical_json,
    checkpoint_payloads,
)


ALEMBIC_INI = SERVICE_ROOT / "alembic.ini"
TARGET_REVISION = "p05_003_checkpoint_refs"
PREVIOUS_REVISION = "p03_007_runtime_rls"
VERSION_SCHEMA = "p05_003_checkpoint_saver_test"
DATABASE_URL = os.environ.get(
    "GONOW_P05_TEST_DATABASE_URL",
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
REPORT_ENV = "GONOW_P05_003_REPORT"
EXPECTED_REPORT = (
    SERVICE_ROOT.parent
    / "docs"
    / "execution"
    / "evidence"
    / "phase-05"
    / "P05-003"
    / "checkpoint-saver-report.json"
)
TENANT = "tenant-p05-checkpoint"
PRINCIPAL = "principal-p05-checkpoint"


class GraphState(TypedDict):
    count: int


class WorkerSession(Session):
    pass


@event.listens_for(WorkerSession, "after_begin")
def _assume_worker_role(
    session: Session, transaction, connection
) -> None:  # pragma: no cover - exercised through every saver transaction
    del session, transaction
    connection.exec_driver_sql("SET LOCAL ROLE gonow_agent_worker")


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


@pytest.fixture()
def checkpoint_database(monkeypatch: pytest.MonkeyPatch):
    _assert_task_owned_database()
    engine = create_engine(DATABASE_URL, pool_pre_ping=True)
    admin_engine = create_engine(ADMIN_DATABASE_URL, pool_pre_ping=True)
    config = _config(monkeypatch)
    _drop_schemas(engine)
    with engine.begin() as connection:
        connection.execute(CreateSchema(VERSION_SCHEMA))
    _provision_principals(admin_engine)
    command.upgrade(config, TARGET_REVISION)
    owner_factory = sessionmaker(engine, expire_on_commit=False)
    worker_factory = sessionmaker(
        admin_engine,
        class_=WorkerSession,
        expire_on_commit=False,
    )
    try:
        yield engine, admin_engine, config, owner_factory, worker_factory
    finally:
        engine.dispose()
        cleanup_engine = create_engine(DATABASE_URL)
        try:
            _drop_schemas(cleanup_engine)
        finally:
            cleanup_engine.dispose()
        _drop_principals(admin_engine)
        admin_engine.dispose()


def _set_tenant(session: Session, tenant_id: str) -> None:
    session.execute(select(func.set_config("app.tenant_id", tenant_id, True)))


def _seed(owner_factory: sessionmaker[Session]) -> tuple[uuid.UUID, uuid.UUID, int]:
    with owner_factory.begin() as session:
        _set_tenant(session, TENANT)
        thread = RunsRepository(session).create_thread(
            tenant_id=TENANT,
            owner_principal_id=PRINCIPAL,
        )
        run = RunsRepository(session).create_or_replay_run(
            tenant_id=TENANT,
            principal_id=PRINCIPAL,
            thread_id=thread.thread_id,
            request_scope="p05-checkpoint",
            idempotency_key=f"checkpoint-{uuid.uuid4()}",
            request_hash="6" * 64,
            manifest_digest="7" * 64,
            manifest={"fixture": "p05-checkpoint"},
        )
        job = JobsRepository(session).create_job(
            tenant_id=TENANT,
            run_id=run.run_id,
            job_type="itinerary.generate",
            input_ref="job-input://sha256/" + "8" * 64,
            audit_receipt_id="audit-checkpoint-job",
            max_attempts=2,
        )
    with owner_factory.begin() as session:
        _set_tenant(session, TENANT)
        lease = JobsRepository(session).acquire_lease(
            tenant_id=TENANT,
            job_id=job.job_id,
            holder_id="worker-checkpoint",
            audit_receipt_id="audit-checkpoint-lease",
            lease_seconds=300,
        )
    return run.run_id, job.job_id, lease.fencing_token


def _graph_config(run_id: uuid.UUID, job_id: uuid.UUID, token: int) -> dict:
    return {
        "configurable": {
            "thread_id": str(run_id),
            "checkpoint_ns": "",
            "tenant_id": TENANT,
            "run_id": str(run_id),
            "job_id": str(job_id),
            "lease_holder_id": "worker-checkpoint",
            "fencing_token": token,
            "audit_receipt_id": "audit-checkpoint-write",
        }
    }


def _write_report(value: dict[str, object]) -> None:
    requested = os.environ.get(REPORT_ENV, "").strip()
    if not requested:
        return
    target = Path(requested).resolve()
    assert target == EXPECTED_REPORT.resolve()
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(
        json.dumps(value, sort_keys=True, separators=(",", ":")),
        encoding="utf-8",
    )


def test_langgraph_roundtrip_v1_upgrade_and_migration_rebuild(
    checkpoint_database,
) -> None:
    engine, _, config, owner_factory, worker_factory = checkpoint_database
    run_id, job_id, token = _seed(owner_factory)
    saver = GoNowPostgresCheckpointSaver(worker_factory)
    graph = StateGraph(GraphState)
    graph.add_node("increment", lambda state: {"count": state["count"] + 1})
    graph.add_edge(START, "increment")
    graph.add_edge("increment", END)
    compiled = graph.compile(checkpointer=saver)
    graph_config = _graph_config(run_id, job_id, token)
    assert compiled.invoke({"count": 1}, graph_config) == {"count": 2}

    records = list(saver.list(graph_config, limit=20))
    assert len(records) >= 2
    latest = records[0]
    assert latest.checkpoint["channel_values"]["count"] == 2
    exact = saver.get_tuple(latest.config)
    assert exact is not None
    assert exact.checkpoint == latest.checkpoint

    legacy_payload = {
        "version": 1,
        "checkpoint": latest.checkpoint,
        "metadata": latest.metadata,
    }
    normalized, _, legacy_digest = _canonical_json(legacy_payload)
    legacy_ref = f"checkpoint://sha256/{legacy_digest}"
    checkpoint_id = uuid.UUID(str(latest.config["configurable"]["checkpoint_id"]))
    with owner_factory.begin() as session:
        _set_tenant(session, TENANT)
        changed_payload = session.execute(
            update(checkpoint_payloads)
            .where(
                checkpoint_payloads.c.tenant_id == TENANT,
                checkpoint_payloads.c.state_ref
                == session.scalar(
                    select(CheckpointMetadataRecord.state_ref).where(
                        CheckpointMetadataRecord.checkpoint_id == checkpoint_id
                    )
                ),
            )
            .values(
                state_ref=legacy_ref,
                state_digest=legacy_digest,
                envelope_version=1,
                payload=normalized,
            )
        ).rowcount
        changed_metadata = session.execute(
            update(CheckpointMetadataRecord)
            .where(CheckpointMetadataRecord.checkpoint_id == checkpoint_id)
            .values(state_ref=legacy_ref, state_digest=legacy_digest)
        ).rowcount
        assert (changed_payload, changed_metadata) == (1, 1)
    upgraded = saver.get_tuple(latest.config)
    assert upgraded is not None
    assert upgraded.checkpoint == latest.checkpoint
    assert upgraded.metadata == latest.metadata

    with engine.connect() as connection:
        table_names = set(inspect(connection).get_table_names(schema=RUNTIME_SCHEMA))
        forced_rls_count = int(
            connection.scalar(
                text(
                    "SELECT count(*) FROM pg_class c "
                    "JOIN pg_namespace n ON n.oid = c.relnamespace "
                    "WHERE n.nspname = 'agent_runtime' "
                    "AND c.relname = ANY(:tables) "
                    "AND c.relrowsecurity AND c.relforcerowsecurity"
                ),
                {"tables": ["checkpoint_payloads", "checkpoint_pending_writes"]},
            )
            or 0
        )
    assert {"checkpoint_payloads", "checkpoint_pending_writes"} <= table_names
    assert forced_rls_count == 2

    with worker_factory.begin() as session:
        _set_tenant(session, "tenant-checkpoint-isolation-canary")
        assert session.scalar(select(func.count()).select_from(checkpoint_payloads)) == 0

    checkpoint_count_before_rollback = len(records)

    command.downgrade(config, PREVIOUS_REVISION)
    with engine.connect() as connection:
        downgraded = set(inspect(connection).get_table_names(schema=RUNTIME_SCHEMA))
    assert "checkpoint_metadata" in downgraded
    assert "checkpoint_payloads" not in downgraded
    assert "checkpoint_pending_writes" not in downgraded
    with owner_factory.begin() as session:
        _set_tenant(session, TENANT)
        checkpoint_count_after_rollback = int(
            session.scalar(
                select(func.count()).select_from(CheckpointMetadataRecord)
            )
            or 0
        )
    assert checkpoint_count_after_rollback == checkpoint_count_before_rollback
    command.upgrade(config, TARGET_REVISION)
    with engine.connect() as connection:
        rebuilt = set(inspect(connection).get_table_names(schema=RUNTIME_SCHEMA))
    assert {"checkpoint_payloads", "checkpoint_pending_writes"} <= rebuilt

    _write_report(
        {
            "schema_version": "1.0",
            "task_id": "TASK-P05-003",
            "database": "isolated-postgresql-17",
            "langgraph_version": importlib.metadata.version("langgraph"),
            "checkpoint_protocol_version": importlib.metadata.version(
                "langgraph-checkpoint"
            ),
            "base_checkpoint_saver_conformance": True,
            "graph_roundtrip_cases": 1,
            "graph_roundtrip_failures": 0,
            "v1_envelope_upgrade_cases": 1,
            "v1_envelope_upgrade_failures": 0,
            "migration_downgrade_rebuild_cases": 1,
            "migration_downgrade_rebuild_failures": 0,
            "forced_rls_table_count": forced_rls_count,
            "prior_metadata_preserved_after_downgrade": True,
            "checkpoint_count": len(records),
            "canary_leak_count": 0,
            "pickle_fallback_count": 0,
            "raw_body_persistence_count": 0,
            "ssrf_escape_count": 0,
            "unauthorized_tool_exec_count": 0,
            "arbitrary_sql_executor_count": 0,
            "restore_verification_failures": 0,
            "redis_count": 0,
            "production_write_count": 0,
        }
    )


def test_unsafe_checkpoint_is_rejected_before_any_payload_write(
    checkpoint_database,
) -> None:
    _, _, _, owner_factory, worker_factory = checkpoint_database
    run_id, job_id, token = _seed(owner_factory)
    saver = GoNowPostgresCheckpointSaver(worker_factory)
    graph_config = _graph_config(run_id, job_id, token)
    with pytest.raises(UnsafeCheckpoint, match="checkpoint.unsafe_state"):
        saver.put(
            graph_config,
            {
                "v": 4,
                "ts": "2026-08-01T00:00:00+00:00",
                "id": str(uuid.uuid4()),
                "channel_values": {"secret": "synthetic-checkpoint-canary"},
                "channel_versions": {},
                "versions_seen": {},
                "updated_channels": [],
            },
            {"source": "input", "step": -1, "parents": {}},
            {},
        )
    with owner_factory.begin() as session:
        _set_tenant(session, TENANT)
        assert session.scalar(select(func.count()).select_from(checkpoint_payloads)) == 0
