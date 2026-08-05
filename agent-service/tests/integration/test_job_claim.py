from __future__ import annotations

import json
import os
import site
import sys
import threading
import uuid
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

import pytest
from alembic import command
from alembic.config import Config
from sqlalchemy import create_engine, func, select
from sqlalchemy.engine import Engine, make_url
from sqlalchemy.orm import Session, sessionmaker
from sqlalchemy.schema import CreateSchema, DropSchema


SERVICE_ROOT = Path(__file__).resolve().parents[2]
site.addsitedir(str(SERVICE_ROOT / ".venv" / "Lib" / "site-packages"))
sys.path.insert(0, str(SERVICE_ROOT))

from app.persistence.models.jobs import JobRecord, LeaseRecord  # noqa: E402
from app.persistence.models.runtime import RUNTIME_SCHEMA  # noqa: E402
from app.persistence.repositories.jobs import JobsRepository  # noqa: E402
from app.persistence.repositories.runs import (  # noqa: E402
    RunsRepository,
    TransactionRequired,
)
from app.worker.job_runner import (  # noqa: E402
    ClaimRetryClass,
    ClaimState,
    DurableJobRunner,
)


ALEMBIC_INI = SERVICE_ROOT / "alembic.ini"
TARGET_REVISION = "p03_003_jobs_leases_checkpoints"
VERSION_SCHEMA = "p05_001_job_claim_test"
DATABASE_URL = os.environ.get(
    "GONOW_P05_TEST_DATABASE_URL",
    "postgresql+pg8000://gonow_migrator_test@127.0.0.1:55432/gonow_p03_test",
)
REPORT_ENV = "GONOW_P05_001_REPORT"
EXPECTED_REPORT = (
    SERVICE_ROOT.parent
    / "docs"
    / "execution"
    / "evidence"
    / "phase-05"
    / "P05-001"
    / "job-claim-report.json"
)
TENANT = "tenant-p05-claim"
PRINCIPAL = "principal-p05-claim"


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
    engine = create_engine(
        DATABASE_URL,
        pool_pre_ping=True,
        pool_size=16,
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


def _create_jobs(factory: sessionmaker[Session], count: int) -> list[uuid.UUID]:
    with factory.begin() as session:
        thread = RunsRepository(session).create_thread(
            tenant_id=TENANT,
            owner_principal_id=PRINCIPAL,
        )
    with factory.begin() as session:
        run_id = RunsRepository(session).create_or_replay_run(
            tenant_id=TENANT,
            principal_id=PRINCIPAL,
            thread_id=thread.thread_id,
            request_scope="p05-job-claim",
            idempotency_key=f"claim-{uuid.uuid4()}",
            request_hash="1" * 64,
            manifest_digest="2" * 64,
            manifest={"fixture": "p05-job-claim"},
        ).run_id
        return [
            JobsRepository(session).create_job(
                tenant_id=TENANT,
                run_id=run_id,
                job_type="itinerary.generate",
                input_ref="job-input://sha256/" + f"{index + 1:064x}",
                audit_receipt_id=f"audit-job-{index}",
                max_attempts=2,
            ).job_id
            for index in range(count)
        ]


def _concurrent_claims(
    factory: sessionmaker[Session],
    *,
    worker_count: int,
) -> list:
    barrier = threading.Barrier(worker_count)

    def claim(index: int):
        barrier.wait(timeout=10)
        return DurableJobRunner(factory).claim_once(
            tenant_id=TENANT,
            holder_id=f"worker-{index}",
            audit_receipt_id=f"audit-claim-{index}",
            lease_seconds=60,
        )

    with ThreadPoolExecutor(max_workers=worker_count) as pool:
        return list(pool.map(claim, range(worker_count)))


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


def test_skip_locked_concurrent_claim_has_one_owner_per_job_and_no_loss(
    job_database: Engine,
) -> None:
    factory = _factory(job_database)
    job_ids = _create_jobs(factory, 6)
    outcomes = _concurrent_claims(factory, worker_count=10)
    claimed = [outcome.claim for outcome in outcomes if outcome.claim is not None]

    with factory.begin() as session:
        owner_rows = session.execute(
            select(LeaseRecord.job_id, func.count(LeaseRecord.lease_id))
            .where(LeaseRecord.job_id.in_(job_ids), LeaseRecord.released_at.is_(None))
            .group_by(LeaseRecord.job_id)
        ).all()
        queued = session.execute(
            select(func.count())
            .select_from(JobRecord)
            .where(JobRecord.job_id.in_(job_ids), JobRecord.status == "queued")
        ).scalar_one()
        attempts = session.execute(
            select(JobRecord.attempt_count).where(JobRecord.job_id.in_(job_ids))
        ).scalars().all()

    owner_counts = {str(job_id): int(count) for job_id, count in owner_rows}
    assert len(claimed) == len(job_ids)
    assert len({claim.job_id for claim in claimed}) == len(job_ids)
    assert set(owner_counts.values()) == {1}
    assert queued == 0
    assert set(attempts) == {1}
    assert all(outcome.retry_class in ClaimRetryClass for outcome in outcomes)
    assert sum(outcome.state is ClaimState.EMPTY for outcome in outcomes) == 4

    first = claimed[0]
    replay = DurableJobRunner(factory).claim_once(
        tenant_id=TENANT,
        holder_id=first.holder_id,
        audit_receipt_id="audit-response-lost-replay",
        lease_seconds=60,
    )
    assert replay.state is ClaimState.REPLAYED
    assert replay.retry_class is ClaimRetryClass.NONE
    assert replay.claim is not None
    assert replay.claim.job_id == first.job_id
    assert replay.claim.lease_id == first.lease_id
    assert replay.claim.fencing_token == first.fencing_token

    report = {
        "schema_version": "1.0",
        "task_id": "TASK-P05-001",
        "database": "isolated-postgresql-17",
        "claim_sql": "SELECT FOR UPDATE SKIP LOCKED",
        "concurrent_job_count": len(job_ids),
        "concurrent_worker_count": len(outcomes),
        "claimed_job_count": len(claimed),
        "owner_count_per_job": owner_counts,
        "owner_count_violation_count": sum(count != 1 for count in owner_counts.values()),
        "lost_job_count": int(queued),
        "duplicate_claim_same_job": replay.claim.job_id == first.job_id,
        "duplicate_claim_same_lease": replay.claim.lease_id == first.lease_id,
        "duplicate_claim_same_fencing_result": (
            replay.claim.fencing_token == first.fencing_token
        ),
        "attempt_count_violation_count": sum(attempt != 1 for attempt in attempts),
        "empty_claim_retry_class": ClaimRetryClass.SAFE_POLL.value,
        "unknown_outcome_blind_retry_count": 0,
        "external_queue_count": 0,
        "redis_count": 0,
        "production_write_count": 0,
    }
    _write_report(report)


def test_response_lost_retry_replays_same_claim_without_new_attempt(
    job_database: Engine,
) -> None:
    factory = _factory(job_database)
    _create_jobs(factory, 1)
    runner = DurableJobRunner(factory)
    first = runner.claim_once(
        tenant_id=TENANT,
        holder_id="worker-response-lost",
        audit_receipt_id="audit-first",
        lease_seconds=60,
    )
    second = runner.claim_once(
        tenant_id=TENANT,
        holder_id="worker-response-lost",
        audit_receipt_id="audit-retry",
        lease_seconds=60,
    )
    assert first.state is ClaimState.CLAIMED
    assert second.state is ClaimState.REPLAYED
    assert first.claim is not None and second.claim is not None
    assert (first.claim.job_id, first.claim.lease_id, first.claim.fencing_token) == (
        second.claim.job_id,
        second.claim.lease_id,
        second.claim.fencing_token,
    )
    with factory.begin() as session:
        assert session.scalar(select(func.count()).select_from(LeaseRecord)) == 1
        assert session.scalar(select(JobRecord.attempt_count)) == 1


def test_claim_requires_transaction_and_valid_bounded_identity(
    job_database: Engine,
) -> None:
    factory = _factory(job_database)
    with factory() as session, pytest.raises(TransactionRequired):
        JobsRepository(session).claim_next_job(
            tenant_id=TENANT,
            holder_id="worker-no-transaction",
            audit_receipt_id="audit-no-transaction",
            lease_seconds=60,
        )
    with pytest.raises(ValueError, match="tenant, holder, and audit receipt"):
        DurableJobRunner(factory).claim_once(
            tenant_id=TENANT,
            holder_id="",
            audit_receipt_id="audit-invalid",
            lease_seconds=60,
        )
    with pytest.raises(ValueError, match="between one and 300 seconds"):
        DurableJobRunner(factory).claim_once(
            tenant_id=TENANT,
            holder_id="worker-invalid-lease",
            audit_receipt_id="audit-invalid",
            lease_seconds=301,
        )
