"""Typed contract for the one selected itinerary Basic Info Domain Command.

The request deliberately excludes tenant, principal, role, approval outcome,
raw rows, arbitrary plan data and force-overwrite controls. Identity and the
low-risk policy classification are server-owned.
"""

from __future__ import annotations

import hashlib
import uuid
from datetime import date, datetime
from decimal import Decimal
from enum import StrEnum
from typing import Annotated, Literal

from pydantic import BaseModel, ConfigDict, Field, StringConstraints, model_validator

from app.auth.context import AuthorizationPolicy, RequestContext
from app.runtime.behavior_manifest import canonicalize_jcs


SafeTitle = Annotated[
    str, StringConstraints(strip_whitespace=True, min_length=1, max_length=160)
]
SafeDestination = Annotated[
    str, StringConstraints(strip_whitespace=True, min_length=1, max_length=160)
]
SafeTag = Annotated[
    str,
    StringConstraints(
        strip_whitespace=True,
        min_length=1,
        max_length=48,
        pattern=r"^[^\x00-\x1f\x7f]+$",
    ),
]
IdempotencyKey = Annotated[
    str,
    StringConstraints(
        strip_whitespace=True,
        min_length=16,
        max_length=128,
        pattern=r"^[A-Za-z0-9][A-Za-z0-9_.:/-]+$",
    ),
]
Sha256Digest = Annotated[str, StringConstraints(pattern=r"^[0-9a-f]{64}$")]

COMMAND_TYPE = "itinerary.basic_info.update"
COMMAND_SCHEMA_VERSION = "1.0"
LOW_RISK_POLICY_REFERENCE = "policy:itinerary.basic_info.low-risk:v1"
ALLOWED_PATCH_FIELDS = frozenset(
    {"title", "destination", "start_date", "end_date", "budget", "actual_cost", "tags"}
)


class StrictCommandModel(BaseModel):
    model_config = ConfigDict(extra="forbid", frozen=True, strict=True)


class ItineraryBasicInfoPatch(StrictCommandModel):
    title: SafeTitle
    destination: SafeDestination
    start_date: date
    end_date: date
    budget: Decimal = Field(ge=0, max_digits=12, decimal_places=2)
    actual_cost: Decimal = Field(ge=0, max_digits=12, decimal_places=2)
    tags: tuple[SafeTag, ...] = Field(min_length=0, max_length=16)

    @model_validator(mode="after")
    def validate_patch(self) -> "ItineraryBasicInfoPatch":
        if self.end_date < self.start_date:
            raise ValueError("domain_command.date_range_invalid")
        normalized = [tag.casefold() for tag in self.tags]
        if len(normalized) != len(set(normalized)):
            raise ValueError("domain_command.tag_duplicate")
        return self

    def legacy_compatible_snapshot(self) -> dict[str, object]:
        """Return only the fields owned by the selected legacy write entry."""

        return {
            "title": self.title,
            "destination_city": self.destination,
            "start_date": self.start_date.isoformat(),
            "end_date": self.end_date.isoformat(),
            "budget": format(self.budget, "f"),
            "actual_cost": format(self.actual_cost, "f"),
            "tags": list(self.tags),
        }


class UpdateItineraryBasicInfoCommand(StrictCommandModel):
    schema_version: Literal["1.0"]
    command_id: uuid.UUID
    idempotency_key: IdempotencyKey
    target_itinerary_id: uuid.UUID
    expected_version: int = Field(ge=0)
    patch: ItineraryBasicInfoPatch


class CommandOutcome(StrEnum):
    COMMITTED = "committed"
    CONFLICT = "conflict"
    DENIED = "denied"
    REJECTED = "rejected"


class DomainCommandErrorCode(StrEnum):
    INVALID = "domain_command.invalid"
    FORBIDDEN = "domain_command.forbidden"
    STALE_VERSION = "domain_command.stale_version"
    IDEMPOTENCY_CONFLICT = "domain_command.idempotency_conflict"
    OUTCOME_UNKNOWN = "domain_command.outcome_unknown"
    RETRY_LATER = "domain_command.retry_later"


class ItineraryBasicInfoReceipt(StrictCommandModel):
    schema_version: Literal["1.0"]
    command_type: Literal["itinerary.basic_info.update"]
    command_id: uuid.UUID
    state: CommandOutcome
    target_digest: Sha256Digest
    principal_digest: Sha256Digest
    idempotency_digest: Sha256Digest
    command_hash: Sha256Digest
    approval_reference: Literal["policy:itinerary.basic_info.low-risk:v1"]
    expected_version: int = Field(ge=0)
    actual_version: int | None = Field(default=None, ge=1)
    event_id: uuid.UUID | None = None
    outbox_id: uuid.UUID | None = None
    policy_digest: Sha256Digest
    schema_digest: Sha256Digest
    recorded_at: datetime
    replayed: bool

    @model_validator(mode="after")
    def validate_outcome_shape(self) -> "ItineraryBasicInfoReceipt":
        committed = self.state is CommandOutcome.COMMITTED
        if committed:
            if self.actual_version != self.expected_version + 1:
                raise ValueError("domain_command.receipt_version_invalid")
            if self.event_id is None or self.outbox_id is None:
                raise ValueError("domain_command.receipt_event_missing")
        elif any(value is not None for value in (self.actual_version, self.event_id, self.outbox_id)):
            raise ValueError("domain_command.noncommitted_effect_reference")
        return self


def _sha256(value: object) -> str:
    return hashlib.sha256(canonicalize_jcs(value)).hexdigest()


def semantic_command_hash(command: UpdateItineraryBasicInfoCommand) -> str:
    """Hash semantic content; transport command ID and retry key are excluded."""

    return _sha256(
        {
            "command_type": COMMAND_TYPE,
            "schema_version": command.schema_version,
            "target_itinerary_id": str(command.target_itinerary_id),
            "expected_version": command.expected_version,
            "patch": command.patch.model_dump(mode="json"),
        }
    )


def scoped_idempotency_digest(
    context: RequestContext, command: UpdateItineraryBasicInfoCommand
) -> str:
    return _sha256(
        {
            "tenant_id": context.tenant_id,
            "principal_id": context.principal_id,
            "command_type": COMMAND_TYPE,
            "target_itinerary_id": str(command.target_itinerary_id),
            "idempotency_key": command.idempotency_key,
        }
    )


def target_digest(context: RequestContext, command: UpdateItineraryBasicInfoCommand) -> str:
    return _sha256(
        {"tenant_id": context.tenant_id, "target_itinerary_id": str(command.target_itinerary_id)}
    )


def principal_digest(context: RequestContext) -> str:
    return _sha256({"tenant_id": context.tenant_id, "principal_id": context.principal_id})


def policy_digest() -> str:
    return _sha256(
        {
            "policy_reference": LOW_RISK_POLICY_REFERENCE,
            "approval_required": False,
            "allowed_fields": sorted(ALLOWED_PATCH_FIELDS),
        }
    )


def schema_digest() -> str:
    return _sha256(UpdateItineraryBasicInfoCommand.model_json_schema())


def authorize_basic_info_update(
    context: RequestContext,
    *,
    resource_tenant_id: str,
    policy: AuthorizationPolicy | None = None,
) -> None:
    """Authorize only with server-derived context and the frozen field authority."""

    (policy or AuthorizationPolicy()).authorize(
        context,
        action=COMMAND_TYPE,
        resource_tenant_id=resource_tenant_id,
        requested_fields=set(ALLOWED_PATCH_FIELDS),
        allowed_fields=set(ALLOWED_PATCH_FIELDS),
        approval_valid=True,
    )
