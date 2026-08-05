from __future__ import annotations

import json
import site
import sys
import uuid
from datetime import date, datetime, timezone
from decimal import Decimal
from pathlib import Path

import pytest
from pydantic import ValidationError


SERVICE_ROOT = Path(__file__).resolve().parents[2]
site.addsitedir(str(SERVICE_ROOT / ".venv" / "Lib" / "site-packages"))
sys.path.insert(0, str(SERVICE_ROOT))

from app.auth.context import AuthorizationForbidden, RequestContext  # noqa: E402
from app.commands.itinerary_basic_info import (  # noqa: E402
    COMMAND_TYPE,
    CommandOutcome,
    ItineraryBasicInfoPatch,
    ItineraryBasicInfoReceipt,
    UpdateItineraryBasicInfoCommand,
    authorize_basic_info_update,
    policy_digest,
    principal_digest,
    schema_digest,
    scoped_idempotency_digest,
    semantic_command_hash,
    target_digest,
)


TARGET = uuid.UUID("10000000-0000-4000-8000-000000000001")
COMMAND = uuid.UUID("20000000-0000-4000-8000-000000000002")


def _context(*, tenant: str = "tenant-a", principal: str = "principal-a", allowed: bool = True) -> RequestContext:
    return RequestContext(
        principal_id=principal,
        tenant_id=tenant,
        permissions=(COMMAND_TYPE,) if allowed else ("itinerary.read",),
        locale="en",
        timezone="UTC",
        trace_id="trace-p12d-contract",
    )


def _patch(*, title: str = "Shanghai weekend") -> ItineraryBasicInfoPatch:
    return ItineraryBasicInfoPatch(
        title=title,
        destination="Shanghai",
        start_date=date(2026, 10, 1),
        end_date=date(2026, 10, 3),
        budget=Decimal("1200.00"),
        actual_cost=Decimal("0.00"),
        tags=("city", "museum"),
    )


def _command(
    *,
    title: str = "Shanghai weekend",
    command_id: uuid.UUID = COMMAND,
    idempotency_key: str = "p12d-basic-info-0001",
    expected_version: int = 5,
) -> UpdateItineraryBasicInfoCommand:
    return UpdateItineraryBasicInfoCommand(
        schema_version="1.0",
        command_id=command_id,
        idempotency_key=idempotency_key,
        target_itinerary_id=TARGET,
        expected_version=expected_version,
        patch=_patch(title=title),
    )


@pytest.mark.parametrize(
    "field",
    ["tenant_id", "principal_id", "user_id", "role", "approval", "approval_id", "force"],
)
def test_client_authority_fields_are_rejected(field: str) -> None:
    payload = _command().model_dump(mode="python")
    payload[field] = "attacker-controlled"
    with pytest.raises(ValidationError):
        UpdateItineraryBasicInfoCommand.model_validate(payload)


@pytest.mark.parametrize("field", ["plan_data", "raw_row", "prompt", "reasoning", "tool_result"])
def test_unbounded_or_model_fields_are_rejected(field: str) -> None:
    payload = _command().model_dump(mode="python")
    payload["patch"] = dict(payload["patch"])
    payload["patch"][field] = {"overwrite": True}
    with pytest.raises(ValidationError):
        UpdateItineraryBasicInfoCommand.model_validate(payload)


def test_patch_is_bounded_typed_and_legacy_compatible() -> None:
    snapshot = _patch().legacy_compatible_snapshot()
    assert set(snapshot) == {
        "title",
        "destination_city",
        "start_date",
        "end_date",
        "budget",
        "actual_cost",
        "tags",
    }
    assert snapshot["budget"] == "1200.00"
    with pytest.raises(ValidationError, match="date_range_invalid"):
        ItineraryBasicInfoPatch(
            **{**_patch().model_dump(mode="python"), "end_date": date(2026, 9, 30)}
        )
    with pytest.raises(ValidationError, match="tag_duplicate"):
        ItineraryBasicInfoPatch(
            **{**_patch().model_dump(mode="python"), "tags": ("Museum", "museum")}
        )


def test_semantic_hash_ignores_transport_identity_but_binds_body_and_version() -> None:
    original = _command()
    transport_retry = _command(
        command_id=uuid.UUID("30000000-0000-4000-8000-000000000003"),
        idempotency_key="p12d-basic-info-retry",
    )
    assert semantic_command_hash(original) == semantic_command_hash(transport_retry)
    assert semantic_command_hash(original) != semantic_command_hash(_command(title="Changed"))
    assert semantic_command_hash(original) != semantic_command_hash(_command(expected_version=6))


def test_idempotency_scope_is_server_derived() -> None:
    command = _command()
    digest = scoped_idempotency_digest(_context(), command)
    assert digest != scoped_idempotency_digest(_context(tenant="tenant-b"), command)
    assert digest != scoped_idempotency_digest(_context(principal="principal-b"), command)
    assert digest != scoped_idempotency_digest(
        _context(), _command(idempotency_key="p12d-basic-info-other")
    )


def test_authorization_uses_server_context_and_fails_closed() -> None:
    authorize_basic_info_update(_context(), resource_tenant_id="tenant-a")
    with pytest.raises(AuthorizationForbidden):
        authorize_basic_info_update(_context(allowed=False), resource_tenant_id="tenant-a")
    with pytest.raises(AuthorizationForbidden):
        authorize_basic_info_update(_context(), resource_tenant_id="tenant-b")


def test_receipt_is_metadata_only_and_outcome_shape_is_strict() -> None:
    command = _command()
    context = _context()
    receipt = ItineraryBasicInfoReceipt(
        schema_version="1.0",
        command_type=COMMAND_TYPE,
        command_id=command.command_id,
        state=CommandOutcome.COMMITTED,
        target_digest=target_digest(context, command),
        principal_digest=principal_digest(context),
        idempotency_digest=scoped_idempotency_digest(context, command),
        command_hash=semantic_command_hash(command),
        approval_reference="policy:itinerary.basic_info.low-risk:v1",
        expected_version=5,
        actual_version=6,
        event_id=uuid.UUID("40000000-0000-4000-8000-000000000004"),
        outbox_id=uuid.UUID("50000000-0000-4000-8000-000000000005"),
        policy_digest=policy_digest(),
        schema_digest=schema_digest(),
        recorded_at=datetime(2026, 8, 4, 8, 0, tzinfo=timezone.utc),
        replayed=False,
    )
    encoded = json.dumps(receipt.model_dump(mode="json"), sort_keys=True)
    for forbidden in ("tenant-a", "principal-a", "Shanghai", "1200.00", "museum"):
        assert forbidden not in encoded
    assert not {"tenant_id", "principal_id", "user_id", "patch", "body"} & set(
        ItineraryBasicInfoReceipt.model_fields
    )
    with pytest.raises(ValidationError, match="noncommitted_effect_reference"):
        ItineraryBasicInfoReceipt.model_validate(
            {**receipt.model_dump(mode="python"), "state": CommandOutcome.CONFLICT}
        )
