from __future__ import annotations

import site
import sys
import threading
import uuid
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone
from pathlib import Path

import pytest
from sqlalchemy import func, select, text, update


SERVICE_ROOT = Path(__file__).resolve().parents[2]
site.addsitedir(str(SERVICE_ROOT / ".venv" / "Lib" / "site-packages"))
sys.path.insert(0, str(SERVICE_ROOT))
sys.path.insert(0, str(Path(__file__).resolve().parent))

import test_p12d_domain_command as base  # noqa: E402
from app.auth.context import AuthorizationForbidden, RequestContext  # noqa: E402
from app.commands.itinerary_basic_info import CommandOutcome  # noqa: E402
from app.persistence.repositories.itinerary_basic_info_commands import (  # noqa: E402
    OUTBOX,
    ItineraryBasicInfoCommandService,
    ItineraryBasicInfoOutboxRepository,
)


command_database = base.command_database


@pytest.mark.parametrize(
    "stage",
    [
        "after_authorization_before_attempt",
        "after_business_mutation_before_outbox",
        "after_outbox_before_receipt",
        "after_receipt_before_commit",
    ],
)
def test_precommit_failure_rolls_back_business_attempt_receipt_and_outbox(
    command_database,
    stage: str,
) -> None:
    engine, business, factory = command_database

    def fail(current: str) -> None:
        if current == stage:
            raise RuntimeError(f"synthetic.p12d.{stage}")

    service = ItineraryBasicInfoCommandService(
        factory,
        business_table=business,
        fault_injector=fail,
    )
    with pytest.raises(RuntimeError, match="synthetic.p12d"):
        service.execute(context=base._context(), command=base._command())
    row = base._business_row(engine, business)
    assert row["title"] == "Legacy title"
    assert row["version"] == 5
    assert base._effect_counts(engine) == (0, 0, 0)


def test_commit_after_response_loss_is_recovered_by_receipt_and_retry(
    command_database,
) -> None:
    engine, business, factory = command_database

    def lose_response(stage: str) -> None:
        if stage == "after_commit_before_response":
            raise RuntimeError("synthetic.p12d.response_lost")

    with pytest.raises(RuntimeError, match="response_lost"):
        ItineraryBasicInfoCommandService(
            factory,
            business_table=business,
            fault_injector=lose_response,
        ).execute(context=base._context(), command=base._command())
    recovery = ItineraryBasicInfoCommandService(factory, business_table=business)
    receipt = recovery.lookup(
        context=base._context(),
        target_itinerary_id=base.TARGET,
        idempotency_key="p12d-basic-info-command-0001",
    )
    assert receipt is not None and receipt.state is CommandOutcome.COMMITTED
    replay = recovery.execute(context=base._context(), command=base._command())
    assert replay.replayed is True
    assert replay.command_id == receipt.command_id
    assert replay.outbox_id == receipt.outbox_id
    assert base._business_row(engine, business)["version"] == 6
    assert base._effect_counts(engine) == (1, 1, 1)


def test_concurrent_same_key_same_body_converges_to_one_receipt(
    command_database,
) -> None:
    engine, business, factory = command_database
    barrier = threading.Barrier(2, timeout=10)

    def synchronize(stage: str) -> None:
        if stage == "after_authorization_before_attempt":
            barrier.wait()

    service = ItineraryBasicInfoCommandService(
        factory,
        business_table=business,
        fault_injector=synchronize,
    )
    with ThreadPoolExecutor(max_workers=2) as pool:
        receipts = list(
            pool.map(
                lambda _: service.execute(
                    context=base._context(), command=base._command()
                ),
                range(2),
            )
        )
    assert {receipt.command_id for receipt in receipts} == {
        uuid.UUID("20000000-0000-4000-8000-000000000001")
    }
    assert {receipt.outbox_id for receipt in receipts} == {receipts[0].outbox_id}
    assert sum(receipt.replayed for receipt in receipts) == 1
    assert base._business_row(engine, business)["version"] == 6
    assert base._effect_counts(engine) == (1, 1, 1)


def test_permission_and_cross_tenant_denials_have_zero_formal_write(
    command_database,
) -> None:
    engine, business, factory = command_database
    no_permission = RequestContext(
        principal_id=base.PRINCIPAL,
        tenant_id=base.TENANT,
        permissions=("itinerary.read",),
        locale="en",
        timezone="UTC",
        trace_id="trace-p12d-denied",
    )
    service = ItineraryBasicInfoCommandService(factory, business_table=business)
    with pytest.raises(AuthorizationForbidden):
        service.execute(context=no_permission, command=base._command())
    assert base._effect_counts(engine) == (0, 0, 0)

    other_tenant = base._context(tenant="tenant-p12d-beta")
    denied = service.execute(
        context=other_tenant,
        command=base._command(
            command_id=uuid.UUID("20000000-0000-4000-8000-000000000002"),
            idempotency_key="p12d-basic-info-command-0002",
        ),
    )
    assert denied.state is CommandOutcome.DENIED
    assert denied.event_id is denied.outbox_id is None
    assert base._business_row(engine, business)["version"] == 5
    assert base._effect_counts(engine) == (0, 0, 0)


def test_relay_crash_reclaims_with_new_fence_and_rejects_old_ack(
    command_database,
) -> None:
    engine, business, factory = command_database
    receipt = ItineraryBasicInfoCommandService(
        factory, business_table=business
    ).execute(context=base._context(), command=base._command())
    with factory.begin() as session:
        first = ItineraryBasicInfoOutboxRepository(session).claim_one(
            tenant_id=base.TENANT,
            dispatcher_id="relay-before-crash",
            lease_seconds=30,
        )
    assert first is not None and first.outbox_id == receipt.outbox_id
    with engine.begin() as connection:
        connection.execute(select(func.set_config("app.tenant_id", base.TENANT, True)))
        connection.execute(
            update(OUTBOX)
            .where(OUTBOX.c.outbox_id == first.outbox_id)
            .values(claimed_until=datetime(2026, 1, 1, tzinfo=timezone.utc))
        )
    with factory.begin() as session:
        second = ItineraryBasicInfoOutboxRepository(session).claim_one(
            tenant_id=base.TENANT,
            dispatcher_id="relay-after-crash",
            lease_seconds=30,
        )
    assert second is not None
    assert second.claim_token != first.claim_token
    assert second.attempt_count == first.attempt_count + 1
    with factory.begin() as session:
        old_ack = ItineraryBasicInfoOutboxRepository(session).mark_delivered(
            tenant_id=base.TENANT,
            outbox_id=first.outbox_id,
            claim_token=first.claim_token,
        )
    with factory.begin() as session:
        new_ack = ItineraryBasicInfoOutboxRepository(session).mark_delivered(
            tenant_id=base.TENANT,
            outbox_id=second.outbox_id,
            claim_token=second.claim_token,
        )
    assert old_ack is False
    assert new_ack is True
    with engine.begin() as connection:
        connection.execute(select(func.set_config("app.tenant_id", base.TENANT, True)))
        state = connection.scalar(
            select(OUTBOX.c.state).where(OUTBOX.c.outbox_id == second.outbox_id)
        )
    assert state == "delivered"
