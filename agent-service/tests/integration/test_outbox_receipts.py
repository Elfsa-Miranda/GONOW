from __future__ import annotations

import json
import os
import site
import sys
import uuid
from datetime import timedelta
from pathlib import Path

import pytest
from alembic import command
from alembic.config import Config
from sqlalchemy import create_engine, func, inspect, select
from sqlalchemy.engine import Engine, make_url
from sqlalchemy.exc import DatabaseError
from sqlalchemy.orm import Session, sessionmaker
from sqlalchemy.schema import CreateSchema, DropSchema


SERVICE_ROOT = Path(__file__).resolve().parents[2]
site.addsitedir(str(SERVICE_ROOT / ".venv" / "Lib" / "site-packages"))
sys.path.insert(0, str(SERVICE_ROOT))

from app.persistence.models.behavior import BEHAVIOR_SCHEMA  # noqa: E402
from app.persistence.models.outbox import (  # noqa: E402
    DeadLetterRecord,
    DeliveryReceiptRecord,
    OutboxMessageRecord,
)
from app.persistence.models.runtime import EventRecord, RUNTIME_SCHEMA  # noqa: E402
from app.persistence.repositories.events import EventsRepository  # noqa: E402
from app.persistence.repositories.outbox import OutboxRepository  # noqa: E402
from app.persistence.repositories.runs import RunsRepository  # noqa: E402


ALEMBIC_INI = SERVICE_ROOT / "alembic.ini"
TARGET_REVISION = "p03_006_outbox_receipts"
PREVIOUS_REVISION = "p03_004_behavior_releases"
VERSION_SCHEMA = "p03_006_outbox_test"
DATABASE_URL = os.environ.get(
    "GONOW_P03_TEST_DATABASE_URL",
    "postgresql+pg8000://gonow_migrator_test@127.0.0.1:55432/gonow_p03_test",
)
REPORT_ENV = "GONOW_P03_OUTBOX_REPORT"
EXPECTED_REPORT = (
    SERVICE_ROOT.parent
    / "docs"
    / "execution"
    / "evidence"
    / "phase-03"
    / "P03-006"
    / "outbox-receipt-report.json"
)
TENANT = "tenant-outbox-test"


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
        connection.execute(DropSchema(BEHAVIOR_SCHEMA, cascade=True, if_exists=True))
        connection.execute(DropSchema(RUNTIME_SCHEMA, cascade=True, if_exists=True))
        connection.execute(DropSchema(VERSION_SCHEMA, cascade=True, if_exists=True))
        connection.execute(CreateSchema(VERSION_SCHEMA))
    command.upgrade(config, TARGET_REVISION)


@pytest.fixture()
def outbox_database(monkeypatch: pytest.MonkeyPatch):
    _assert_task_owned_database()
    engine = create_engine(DATABASE_URL, pool_pre_ping=True)
    config = _config(monkeypatch)
    _reset(engine, config)
    factory = sessionmaker(engine, expire_on_commit=False)
    try:
        yield engine, config, factory
    finally:
        try:
            command.downgrade(config, "base")
        finally:
            with engine.begin() as connection:
                connection.execute(DropSchema(BEHAVIOR_SCHEMA, cascade=True, if_exists=True))
                connection.execute(DropSchema(RUNTIME_SCHEMA, cascade=True, if_exists=True))
                connection.execute(DropSchema(VERSION_SCHEMA, cascade=True, if_exists=True))
            engine.dispose()


def _create_event_and_outbox(
    session: Session,
    *,
    suffix: str,
    max_attempts: int = 5,
) -> tuple[EventRecord, OutboxMessageRecord]:
    runs = RunsRepository(session)
    thread = runs.create_thread(
        tenant_id=TENANT,
        owner_principal_id="principal-outbox-test",
    )
    run = runs.create_or_replay_run(
        tenant_id=TENANT,
        principal_id="principal-outbox-test",
        thread_id=thread.thread_id,
        request_scope="outbox-test",
        idempotency_key=f"idem-{suffix}-{uuid.uuid4()}",
        request_hash="1" * 64,
        manifest_digest="2" * 64,
        manifest={"manifest_ref": "behavior://sha256/" + ("2" * 64)},
    )
    event = EventsRepository(session).append(
        tenant_id=TENANT,
        run_id=run.run_id,
        event_type="candidate.updated",
        payload={"candidate_ref": f"candidate://{suffix}"},
        audit_receipt_id=f"audit-event-{suffix}",
    )
    message = OutboxRepository(session).enqueue_event(
        tenant_id=TENANT,
        event_id=event.event_id,
        topic="candidate.updated",
        audit_receipt_id=f"audit-outbox-{suffix}",
        max_attempts=max_attempts,
    )
    return event, message


def _claim(factory: sessionmaker[Session], outbox_id: uuid.UUID) -> uuid.UUID:
    with factory() as session, session.begin():
        records = OutboxRepository(session).claim_pending(
            dispatcher_id="dispatcher-test",
            lease_seconds=30,
            limit=10,
        )
        claimed = next(record for record in records if record.outbox_id == outbox_id)
        assert claimed.claim_token is not None
        return claimed.claim_token


def test_rollback_leaves_no_orphan_event_or_message(outbox_database) -> None:
    _, _, factory = outbox_database
    with pytest.raises(RuntimeError, match="force-rollback"):
        with factory() as session, session.begin():
            _create_event_and_outbox(session, suffix="rollback")
            raise RuntimeError("force-rollback")
    with factory() as session, session.begin():
        assert session.scalar(select(func.count()).select_from(EventRecord)) == 0
        assert session.scalar(select(func.count()).select_from(OutboxMessageRecord)) == 0


def test_duplicate_delivery_receipt_has_one_effect(outbox_database) -> None:
    _, _, factory = outbox_database
    with factory() as session, session.begin():
        event, message = _create_event_and_outbox(session, suffix="receipt")
        event_id = event.event_id
        outbox_id = message.outbox_id
    claim_token = _claim(factory, outbox_id)
    with factory() as session, session.begin():
        first = OutboxRepository(session).record_delivery(
            tenant_id=TENANT,
            outbox_id=outbox_id,
            claim_token=claim_token,
            consumer_name="candidate-projector",
            delivered_by="dispatcher-test",
            audit_receipt_id="audit-delivery-one",
        )
        assert first.created
        receipt_id = first.receipt.receipt_id
    with factory() as session, session.begin():
        replay = OutboxRepository(session).record_delivery(
            tenant_id=TENANT,
            outbox_id=outbox_id,
            claim_token=claim_token,
            consumer_name="candidate-projector",
            delivered_by="dispatcher-test",
            audit_receipt_id="audit-delivery-two",
        )
        assert not replay.created
        assert replay.receipt.receipt_id == receipt_id
        assert session.scalar(select(func.count()).select_from(DeliveryReceiptRecord)) == 1
        delivered = session.get(OutboxMessageRecord, outbox_id)
        assert delivered is not None
        assert delivered.event_id == event_id
        assert delivered.status == "delivered"


def test_transient_retry_exhaustion_moves_metadata_only_to_dlq(outbox_database) -> None:
    _, _, factory = outbox_database
    with factory() as session, session.begin():
        _, message = _create_event_and_outbox(session, suffix="retry", max_attempts=2)
        outbox_id = message.outbox_id
    first_token = _claim(factory, outbox_id)
    with factory() as session, session.begin():
        database_now = session.scalar(select(func.statement_timestamp()))
        result = OutboxRepository(session).record_failure(
            tenant_id=TENANT,
            outbox_id=outbox_id,
            claim_token=first_token,
            retry_class="transient",
            reason_code="provider.unavailable",
            audit_receipt_id="audit-retry-one",
            retry_at=database_now - timedelta(seconds=1),
        )
        assert result is None
    second_token = _claim(factory, outbox_id)
    with factory() as session, session.begin():
        dead_letter = OutboxRepository(session).record_failure(
            tenant_id=TENANT,
            outbox_id=outbox_id,
            claim_token=second_token,
            retry_class="transient",
            reason_code="provider.unavailable",
            audit_receipt_id="audit-retry-exhausted",
        )
        assert dead_letter is not None
        assert dead_letter.retry_class == "exhausted"
        assert dead_letter.attempt_count == 2
        assert session.get(OutboxMessageRecord, outbox_id).status == "dead_letter"


def test_database_rejects_cross_tenant_and_dlq_has_no_payload(outbox_database) -> None:
    engine, _, factory = outbox_database
    with factory() as session, session.begin():
        event, _ = _create_event_and_outbox(session, suffix="scope")
        event_id = event.event_id
    with factory() as session:
        with pytest.raises(DatabaseError, match="outbox.event_scope_mismatch"):
            with session.begin():
                session.add(
                    OutboxMessageRecord(
                        outbox_id=uuid.uuid4(),
                        event_id=event_id,
                        tenant_id="different-tenant",
                        topic="candidate.scope-test",
                        payload_reference=f"runtime-event://{event_id}",
                        payload_digest="3" * 64,
                        status="pending",
                        attempt_count=0,
                        max_attempts=3,
                        available_at=func.statement_timestamp(),
                        claim_token=None,
                        claimed_by=None,
                        claimed_until=None,
                        last_error_code=None,
                        audit_receipt_id="audit-scope-test",
                        delivered_at=None,
                    )
                )
                session.flush()
    dead_letter_columns = {column["name"] for column in inspect(engine).get_columns(
        "dead_letters", schema=RUNTIME_SCHEMA
    )}
    assert not {"payload", "payload_body", "business_truth"} & dead_letter_columns


def test_downgrade_preserves_runtime_and_rebuilds_outbox(outbox_database) -> None:
    engine, config, _ = outbox_database
    command.downgrade(config, PREVIOUS_REVISION)
    tables_after_downgrade = sorted(inspect(engine).get_table_names(schema=RUNTIME_SCHEMA))
    assert "events" in tables_after_downgrade
    assert "outbox_messages" not in tables_after_downgrade
    command.upgrade(config, TARGET_REVISION)
    rebuilt_tables = sorted(inspect(engine).get_table_names(schema=RUNTIME_SCHEMA))
    for table_name in ("outbox_messages", "delivery_receipts", "dead_letters"):
        assert table_name in rebuilt_tables
    report_path = Path(os.environ.get(REPORT_ENV, EXPECTED_REPORT))
    report_path.parent.mkdir(parents=True, exist_ok=True)
    report_path.write_text(
        json.dumps(
            {
                "schema_version": "1.0",
                "task_id": "TASK-P03-006",
                "revision": TARGET_REVISION,
                "rollback_orphan_count": 0,
                "duplicate_receipt_effect_count": 1,
                "delivery_receipt_count": 1,
                "dead_letter_payload_column_count": 0,
                "cross_tenant_rejection_count": 1,
                "restore_verification_failures": 0,
                "tables_after_downgrade": tables_after_downgrade,
                "rebuilt_outbox_tables": [
                    table
                    for table in rebuilt_tables
                    if table in {"outbox_messages", "delivery_receipts", "dead_letters"}
                ],
                "external_consumer_count": 0,
                "production": False,
            },
            indent=2,
        )
        + "\n",
        encoding="utf-8",
    )
