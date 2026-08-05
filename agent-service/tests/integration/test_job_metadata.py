from __future__ import annotations

import json
import os
import site
import sys
import threading
import uuid
from concurrent.futures import ThreadPoolExecutor
from datetime import timedelta
from pathlib import Path

import pytest
from alembic import command
from alembic.config import Config
from sqlalchemy import create_engine, func, inspect, select, update
from sqlalchemy.engine import Engine, make_url
from sqlalchemy.exc import DatabaseError
from sqlalchemy.orm import Session, sessionmaker
from sqlalchemy.schema import CreateSchema, DropSchema


SERVICE_ROOT = Path(__file__).resolve().parents[2]
site.addsitedir(str(SERVICE_ROOT / ".venv" / "Lib" / "site-packages"))
sys.path.insert(0, str(SERVICE_ROOT))

from app.persistence.models.jobs import (  # noqa: E402
    CheckpointMetadataRecord,
    JobRecord,
    LeaseRecord,
)
from app.persistence.models.runtime import RUNTIME_SCHEMA  # noqa: E402
from app.persistence.repositories.checkpoints import CheckpointsRepository  # noqa: E402
from app.persistence.repositories.jobs import (  # noqa: E402
    JobsRepository,
    LeaseHeld,
    StaleFence,
)
from app.persistence.repositories.runs import RunsRepository  # noqa: E402


ALEMBIC_INI = SERVICE_ROOT / "alembic.ini"
PREVIOUS_REVISION = "p03_002_run_event_idempotency"
TARGET_REVISION = "p03_003_jobs_leases_checkpoints"
VERSION_SCHEMA = "p03_003_job_metadata_test"
DATABASE_URL = os.environ.get(
    "GONOW_P03_TEST_DATABASE_URL",
    "postgresql+pg8000://gonow_migrator_test@127.0.0.1:55432/gonow_p03_test",
)
REPORT_ENV = "GONOW_P03_JOB_REPORT"
EXPECTED_REPORT = (
    SERVICE_ROOT.parent
    / "docs"
    / "execution"
    / "evidence"
    / "phase-03"
    / "P03-003"
    / "job-metadata-report.json"
)
TENANT = "tenant-job-a"
PRINCIPAL = "principal-job-a"
SECRET_CANARY = "gonow-checkpoint-secret-canary"
OLD_TABLES = ["events", "idempotency_records", "runs", "threads"]
NEW_TABLES = [
    "checkpoint_metadata",
    "events",
    "idempotency_records",
    "jobs",
    "leases",
    "runs",
    "threads",
]


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
        connection.execute(DropSchema(RUNTIME_SCHEMA, cascade=True, if_exists=True))
        connection.execute(DropSchema(VERSION_SCHEMA, cascade=True, if_exists=True))
        connection.execute(CreateSchema(VERSION_SCHEMA))
    command.upgrade(config, TARGET_REVISION)


@pytest.fixture()
def job_database(monkeypatch: pytest.MonkeyPatch):
    _assert_task_owned_database()
    engine = create_engine(DATABASE_URL, pool_pre_ping=True)
    config = _config(monkeypatch)
    _reset(engine, config)
    try:
        yield engine, config
    finally:
        try:
            command.downgrade(config, "base")
        finally:
            with engine.begin() as connection:
                connection.execute(DropSchema(RUNTIME_SCHEMA, cascade=True, if_exists=True))
                connection.execute(DropSchema(VERSION_SCHEMA, cascade=True, if_exists=True))
            engine.dispose()


def _factory(engine: Engine) -> sessionmaker[Session]:
    return sessionmaker(engine, expire_on_commit=False)


def _run(factory: sessionmaker[Session], *, key: str) -> uuid.UUID:
    with factory.begin() as session:
        thread = RunsRepository(session).create_thread(
            tenant_id=TENANT,
            owner_principal_id=PRINCIPAL,
        )
    with factory.begin() as session:
        return RunsRepository(session).create_or_replay_run(
            tenant_id=TENANT,
            principal_id=PRINCIPAL,
            thread_id=thread.thread_id,
            request_scope="job-metadata",
            idempotency_key=key,
            request_hash="3" * 64,
            manifest_digest="4" * 64,
            manifest={"fixture": "job-metadata"},
        ).run_id


def _job(factory: sessionmaker[Session], run_id: uuid.UUID) -> uuid.UUID:
    with factory.begin() as session:
        return JobsRepository(session).create_job(
            tenant_id=TENANT,
            run_id=run_id,
            job_type="itinerary.generate",
            input_ref="job-input://sha256/" + "5" * 64,
            audit_receipt_id="audit-job-created",
            max_attempts=2,
        ).job_id


def _expire(factory: sessionmaker[Session], lease_id: uuid.UUID) -> None:
    with factory.begin() as session:
        session.execute(
            update(LeaseRecord)
            .where(LeaseRecord.lease_id == lease_id)
            .values(
                acquired_at=func.statement_timestamp() - timedelta(seconds=10),
                heartbeat_at=func.statement_timestamp() - timedelta(seconds=5),
                expires_at=func.statement_timestamp() - timedelta(seconds=1),
            )
        )


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


def test_job_metadata_rebuild_stale_fence_and_secret_canary(job_database) -> None:
    engine, config = job_database
    factory = _factory(engine)
    with engine.connect() as connection:
        tables = sorted(inspect(connection).get_table_names(schema=RUNTIME_SCHEMA))
    assert tables == NEW_TABLES

    run_id = _run(factory, key="job-rebuild")
    job_id = _job(factory, run_id)
    with factory.begin() as session:
        old_lease = JobsRepository(session).acquire_lease(
            tenant_id=TENANT,
            job_id=job_id,
            holder_id="worker-old",
            audit_receipt_id="audit-lease-old",
            lease_seconds=60,
        )
    _expire(factory, old_lease.lease_id)
    with factory.begin() as session:
        new_lease = JobsRepository(session).acquire_lease(
            tenant_id=TENANT,
            job_id=job_id,
            holder_id="worker-new",
            audit_receipt_id="audit-lease-new",
            lease_seconds=60,
        )
    assert (old_lease.fencing_token, new_lease.fencing_token) == (1, 2)
    with pytest.raises(StaleFence, match="consistency.stale_fence"):
        with factory.begin() as session:
            JobsRepository(session).assert_fence(
                tenant_id=TENANT,
                job_id=job_id,
                holder_id="worker-old",
                fencing_token=old_lease.fencing_token,
            )
    with factory.begin() as session:
        JobsRepository(session).assert_fence(
            tenant_id=TENANT,
            job_id=job_id,
            holder_id="worker-new",
            fencing_token=new_lease.fencing_token,
        )
        checkpoint = CheckpointsRepository(session).save(
            tenant_id=TENANT,
            run_id=run_id,
            job_id=job_id,
            holder_id="worker-new",
            fencing_token=new_lease.fencing_token,
            state_ref="checkpoint://sha256/" + "6" * 64,
            state_digest="6" * 64,
            state_schema_digest="7" * 64,
            pending_writes_ref=None,
            audit_receipt_id="audit-checkpoint-valid",
        )
    assert checkpoint.checkpoint_seq == 1
    with pytest.raises(ValueError, match="approved content references"):
        with factory.begin() as session:
            CheckpointsRepository(session).save(
                tenant_id=TENANT,
                run_id=run_id,
                job_id=job_id,
                holder_id="worker-new",
                fencing_token=new_lease.fencing_token,
                state_ref=SECRET_CANARY,
                state_digest="8" * 64,
                state_schema_digest="9" * 64,
                pending_writes_ref=None,
                audit_receipt_id="audit-checkpoint-canary",
            )
    with factory.begin() as session:
        persisted_refs = session.execute(
            select(
                CheckpointMetadataRecord.state_ref,
                CheckpointMetadataRecord.pending_writes_ref,
            )
        ).all()
    secret_canary_count = sum(SECRET_CANARY in str(value) for row in persisted_refs for value in row)
    assert secret_canary_count == 0

    with pytest.raises(DatabaseError, match="consistency.stale_fence"):
        with factory.begin() as session:
            session.add(
                CheckpointMetadataRecord(
                    checkpoint_id=uuid.uuid4(),
                    parent_checkpoint_id=None,
                    job_id=job_id,
                    run_id=run_id,
                    tenant_id=TENANT,
                    checkpoint_seq=2,
                    fencing_token=old_lease.fencing_token,
                    state_ref="checkpoint://sha256/" + "a" * 64,
                    state_digest="a" * 64,
                    state_schema_digest="b" * 64,
                    pending_writes_ref=None,
                    audit_receipt_id="audit-checkpoint-stale",
                )
            )

    command.downgrade(config, PREVIOUS_REVISION)
    with engine.connect() as connection:
        old_worker_tables = sorted(inspect(connection).get_table_names(schema=RUNTIME_SCHEMA))
    assert old_worker_tables == OLD_TABLES
    command.upgrade(config, TARGET_REVISION)
    with engine.connect() as connection:
        rebuilt_tables = sorted(inspect(connection).get_table_names(schema=RUNTIME_SCHEMA))
    assert rebuilt_tables == NEW_TABLES
    _write_report(
        {
            "schema_version": "1.0",
            "task_id": "TASK-P03-003",
            "revision": TARGET_REVISION,
            "empty_rebuild": True,
            "tables": tables,
            "old_worker_tables_after_downgrade": old_worker_tables,
            "rebuilt_tables": rebuilt_tables,
            "fencing_tokens": [old_lease.fencing_token, new_lease.fencing_token],
            "stale_fence_denied": True,
            "database_stale_checkpoint_denied": True,
            "secret_canary_count": secret_canary_count,
            "production": False,
        }
    )


def test_concurrent_lease_acquisition_has_one_winner(job_database) -> None:
    engine, _ = job_database
    factory = _factory(engine)
    run_id = _run(factory, key="lease-race")
    job_id = _job(factory, run_id)
    barrier = threading.Barrier(2)

    def acquire(index: int) -> tuple[str, int | str]:
        barrier.wait()
        try:
            with factory.begin() as session:
                lease = JobsRepository(session).acquire_lease(
                    tenant_id=TENANT,
                    job_id=job_id,
                    holder_id=f"worker-race-{index}",
                    audit_receipt_id=f"audit-race-{index}",
                    lease_seconds=60,
                )
            return "won", lease.fencing_token
        except LeaseHeld as error:
            return "held", str(error)

    with ThreadPoolExecutor(max_workers=2) as executor:
        results = list(executor.map(acquire, range(2)))
    assert sorted(value[0] for value in results) == ["held", "won"]
    assert [value[1] for value in results if value[0] == "won"] == [1]
    with factory.begin() as session:
        active = session.scalars(
            select(LeaseRecord).where(LeaseRecord.released_at.is_(None))
        ).all()
    assert len(active) == 1


def test_checkpoint_sequences_and_parent_are_same_run(job_database) -> None:
    engine, _ = job_database
    factory = _factory(engine)
    run_id = _run(factory, key="checkpoint-seq")
    job_id = _job(factory, run_id)
    with factory.begin() as session:
        lease = JobsRepository(session).acquire_lease(
            tenant_id=TENANT,
            job_id=job_id,
            holder_id="worker-checkpoint",
            audit_receipt_id="audit-checkpoint-lease",
            lease_seconds=60,
        )
    with factory.begin() as session:
        repository = CheckpointsRepository(session)
        first = repository.save(
            tenant_id=TENANT,
            run_id=run_id,
            job_id=job_id,
            holder_id="worker-checkpoint",
            fencing_token=lease.fencing_token,
            state_ref="checkpoint://sha256/" + "c" * 64,
            state_digest="c" * 64,
            state_schema_digest="d" * 64,
            pending_writes_ref="pending://sha256/" + "e" * 64,
            audit_receipt_id="audit-checkpoint-1",
        )
        second = repository.save(
            tenant_id=TENANT,
            run_id=run_id,
            job_id=job_id,
            holder_id="worker-checkpoint",
            fencing_token=lease.fencing_token,
            state_ref="checkpoint://sha256/" + "f" * 64,
            state_digest="f" * 64,
            state_schema_digest="d" * 64,
            pending_writes_ref=None,
            audit_receipt_id="audit-checkpoint-2",
            parent_checkpoint_id=first.checkpoint_id,
        )
        latest = repository.latest(tenant_id=TENANT, run_id=run_id)
    assert (first.checkpoint_seq, second.checkpoint_seq) == (1, 2)
    assert latest is not None
    assert latest.checkpoint_id == second.checkpoint_id
    assert latest.parent_checkpoint_id == first.checkpoint_id


def test_job_payload_is_reference_only_and_audited(job_database) -> None:
    engine, _ = job_database
    factory = _factory(engine)
    run_id = _run(factory, key="job-ref")
    with pytest.raises(ValueError, match="content-addressed"):
        with factory.begin() as session:
            JobsRepository(session).create_job(
                tenant_id=TENANT,
                run_id=run_id,
                job_type="itinerary.generate",
                input_ref=SECRET_CANARY,
                audit_receipt_id="audit-invalid-job",
            )
    with factory.begin() as session:
        assert session.scalar(select(func.count()).select_from(JobRecord)) == 0
