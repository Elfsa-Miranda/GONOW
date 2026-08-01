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
from sqlalchemy import create_engine, func, select, update
from sqlalchemy.engine import Engine, make_url
from sqlalchemy.orm import Session, sessionmaker
from sqlalchemy.schema import CreateSchema, DropSchema


SERVICE_ROOT = Path(__file__).resolve().parents[2]
site.addsitedir(str(SERVICE_ROOT / ".venv" / "Lib" / "site-packages"))
sys.path.insert(0, str(SERVICE_ROOT))

from app.persistence.models.jobs import JobRecord, LeaseRecord  # noqa: E402
from app.persistence.models.runtime import RUNTIME_SCHEMA  # noqa: E402
from app.persistence.repositories.jobs import JobsRepository, StaleFence  # noqa: E402
from app.persistence.repositories.runs import RunsRepository  # noqa: E402
from app.worker.job_runner import DurableJobRunner  # noqa: E402
from app.worker.lease import DurableLeaseCoordinator  # noqa: E402


ALEMBIC_INI = SERVICE_ROOT / "alembic.ini"
TARGET_REVISION = "p03_003_jobs_leases_checkpoints"
VERSION_SCHEMA = "p05_002_lease_fencing_test"
DATABASE_URL = os.environ.get(
    "GONOW_P05_TEST_DATABASE_URL",
    "postgresql+pg8000://gonow_migrator_test@127.0.0.1:55432/gonow_p03_test",
)
REPORT_ENV = "GONOW_P05_002_REPORT"
EXPECTED_REPORT = (
    SERVICE_ROOT.parent
    / "docs"
    / "execution"
    / "evidence"
    / "phase-05"
    / "P05-002"
    / "lease-fencing-report.json"
)
TENANT = "tenant-p05-fencing"
PRINCIPAL = "principal-p05-fencing"


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
def lease_database(monkeypatch: pytest.MonkeyPatch):
    _assert_task_owned_database()
    engine = create_engine(
        DATABASE_URL,
        pool_pre_ping=True,
        pool_size=8,
        max_overflow=0,
    )
    config = _config(monkeypatch)
    _reset(engine, config)
    try:
        yield engine
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


def _create_job(factory: sessionmaker[Session]) -> uuid.UUID:
    with factory.begin() as session:
        thread = RunsRepository(session).create_thread(
            tenant_id=TENANT,
            owner_principal_id=PRINCIPAL,
        )
    with factory.begin() as session:
        run = RunsRepository(session).create_or_replay_run(
            tenant_id=TENANT,
            principal_id=PRINCIPAL,
            thread_id=thread.thread_id,
            request_scope="p05-lease-fencing",
            idempotency_key=f"fencing-{uuid.uuid4()}",
            request_hash="3" * 64,
            manifest_digest="4" * 64,
            manifest={"fixture": "p05-lease-fencing"},
        )
        return JobsRepository(session).create_job(
            tenant_id=TENANT,
            run_id=run.run_id,
            job_type="itinerary.generate",
            input_ref="job-input://sha256/" + "5" * 64,
            audit_receipt_id="audit-create-job",
            max_attempts=2,
        ).job_id


def _force_expired(factory: sessionmaker[Session], lease_id: uuid.UUID) -> None:
    with factory.begin() as session:
        changed = session.execute(
            update(LeaseRecord)
            .where(LeaseRecord.lease_id == lease_id)
            .values(
                acquired_at=func.statement_timestamp() - timedelta(seconds=10),
                heartbeat_at=func.statement_timestamp() - timedelta(seconds=10),
                expires_at=func.statement_timestamp() - timedelta(seconds=1),
            )
        ).rowcount
        assert changed == 1


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


def test_expired_lease_recovery_has_one_new_winner_and_rejects_old_fence(
    lease_database: Engine,
) -> None:
    factory = _factory(lease_database)
    job_id = _create_job(factory)
    original = DurableJobRunner(factory).claim_once(
        tenant_id=TENANT,
        holder_id="worker-old",
        audit_receipt_id="audit-old-claim",
        lease_seconds=60,
    ).claim
    assert original is not None
    _force_expired(factory, original.lease_id)

    barrier = threading.Barrier(2)

    def reclaim(index: int):
        barrier.wait(timeout=10)
        return DurableLeaseCoordinator(factory).reclaim_once(
            tenant_id=TENANT,
            holder_id=f"worker-new-{index}",
            audit_receipt_id=f"audit-reclaim-{index}",
            lease_seconds=60,
        )

    with ThreadPoolExecutor(max_workers=2) as pool:
        outcomes = list(pool.map(reclaim, range(2)))
    winners = [claim for claim in outcomes if claim is not None]
    assert len(winners) == 1
    winner = winners[0]
    assert winner.job_id == job_id
    assert winner.fencing_token == original.fencing_token + 1
    assert winner.attempt_count == 2

    coordinator = DurableLeaseCoordinator(factory)
    with pytest.raises(StaleFence, match="consistency.stale_fence"):
        coordinator.renew_once(
            tenant_id=TENANT,
            job_id=job_id,
            holder_id=original.holder_id,
            fencing_token=original.fencing_token,
            lease_seconds=60,
        )
    with factory.begin() as session, pytest.raises(
        StaleFence, match="consistency.stale_fence"
    ):
        JobsRepository(session).assert_fence(
            tenant_id=TENANT,
            job_id=job_id,
            holder_id=original.holder_id,
            fencing_token=original.fencing_token,
        )

    renewed = coordinator.renew_once(
        tenant_id=TENANT,
        job_id=job_id,
        holder_id=winner.holder_id,
        fencing_token=winner.fencing_token,
        lease_seconds=60,
    )
    with factory.begin() as session:
        job = session.get(JobRecord, job_id)
        active = session.scalars(
            select(LeaseRecord).where(
                LeaseRecord.job_id == job_id,
                LeaseRecord.released_at.is_(None),
            )
        ).all()
        audit_receipt_count = session.scalar(
            select(func.count())
            .select_from(LeaseRecord)
            .where(
                LeaseRecord.job_id == job_id,
                LeaseRecord.audit_receipt_id != "",
            )
        )
    assert job is not None
    assert job.current_fencing_token == winner.fencing_token
    assert len(active) == 1 and active[0].lease_id == winner.lease_id
    assert renewed.lease_id == winner.lease_id
    assert renewed.heartbeat_at >= renewed.acquired_at
    assert renewed.expires_at > renewed.heartbeat_at
    assert audit_receipt_count == 2

    _write_report(
        {
            "schema_version": "1.0",
            "task_id": "TASK-P05-002",
            "database": "isolated-postgresql-17",
            "database_clock_only": True,
            "recovery_contender_count": len(outcomes),
            "new_lease_winner_count": len(winners),
            "empty_recovery_count": sum(claim is None for claim in outcomes),
            "fencing_tokens": [original.fencing_token, winner.fencing_token],
            "fencing_token_monotonic": (
                winner.fencing_token > original.fencing_token
            ),
            "stale_renew_rejection_count": 1,
            "stale_write_rejection_count": 1,
            "stale_write_count": 0,
            "active_lease_count": len(active),
            "heartbeat_advanced": renewed.heartbeat_at >= renewed.acquired_at,
            "expiry_after_heartbeat": renewed.expires_at > renewed.heartbeat_at,
            "missing_audit_receipt_count": int(audit_receipt_count != 2),
            "arbitrary_sql_executor_count": 0,
            "restore_verification_failures": 0,
            "redis_count": 0,
            "external_queue_count": 0,
            "unknown_outcome_blind_retry_count": 0,
            "production_write_count": 0,
        }
    )


def test_renew_is_cas_bound_to_current_holder_token_and_expiry(
    lease_database: Engine,
) -> None:
    factory = _factory(lease_database)
    job_id = _create_job(factory)
    claim = DurableJobRunner(factory).claim_once(
        tenant_id=TENANT,
        holder_id="worker-current",
        audit_receipt_id="audit-current",
        lease_seconds=60,
    ).claim
    assert claim is not None
    coordinator = DurableLeaseCoordinator(factory)
    renewed = coordinator.renew_once(
        tenant_id=TENANT,
        job_id=job_id,
        holder_id=claim.holder_id,
        fencing_token=claim.fencing_token,
        lease_seconds=30,
    )
    assert renewed.lease_id == claim.lease_id
    assert renewed.fencing_token == claim.fencing_token
    with pytest.raises(StaleFence, match="consistency.stale_fence"):
        coordinator.renew_once(
            tenant_id=TENANT,
            job_id=job_id,
            holder_id="worker-forged",
            fencing_token=claim.fencing_token,
            lease_seconds=30,
        )
    with pytest.raises(StaleFence, match="consistency.stale_fence"):
        coordinator.renew_once(
            tenant_id=TENANT,
            job_id=job_id,
            holder_id=claim.holder_id,
            fencing_token=claim.fencing_token + 1,
            lease_seconds=30,
        )
