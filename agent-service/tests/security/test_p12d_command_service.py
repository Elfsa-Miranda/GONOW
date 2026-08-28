from __future__ import annotations

import json
import site
import sys
import uuid
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

import httpx
from fastapi import FastAPI


SERVICE_ROOT = Path(__file__).resolve().parents[2]
site.addsitedir(str(SERVICE_ROOT / ".venv" / "Lib" / "site-packages"))
sys.path.insert(0, str(SERVICE_ROOT))

from app.api.main import ApiDependencies  # noqa: E402
from app.api.routes.itinerary_commands import create_itinerary_commands_router  # noqa: E402
from app.auth.context import RequestContext  # noqa: E402
from app.commands.itinerary_basic_info import (  # noqa: E402
    COMMAND_TYPE,
    CommandOutcome,
    ItineraryBasicInfoReceipt,
    policy_digest,
    principal_digest,
    schema_digest,
    scoped_idempotency_digest,
    semantic_command_hash,
    target_digest,
)


TARGET = uuid.UUID("10000000-0000-4000-8000-000000000001")
COMMAND = uuid.UUID("20000000-0000-4000-8000-000000000001")
EVENT = uuid.UUID("30000000-0000-4000-8000-000000000001")
OUTBOX = uuid.UUID("40000000-0000-4000-8000-000000000001")
IDEMPOTENCY_KEY = "p12d-basic-info-command-0001"


def _context() -> RequestContext:
    return RequestContext(
        principal_id="principal-server-derived",
        tenant_id="tenant-server-derived",
        permissions=(COMMAND_TYPE,),
        locale="en",
        timezone="UTC",
        trace_id="trace-p12d-route",
    )


def _body() -> dict[str, Any]:
    return {
        "schema_version": "1.0",
        "command_id": str(COMMAND),
        "expected_version": 5,
        "patch": {
            "title": "Server command title",
            "destination": "Shanghai",
            "start_date": "2026-10-01",
            "end_date": "2026-10-03",
            "budget": "1200.00",
            "actual_cost": "50.00",
            "tags": ["city", "museum"],
        },
    }


class FakeCommandService:
    def __init__(self) -> None:
        self.execute_calls = 0
        self.lookup_calls = 0
        self.last_context: RequestContext | None = None
        self.last_command: Any = None
        self.receipt: ItineraryBasicInfoReceipt | None = None

    def execute(self, *, context: RequestContext, command: Any) -> ItineraryBasicInfoReceipt:
        self.execute_calls += 1
        self.last_context = context
        self.last_command = command
        self.receipt = ItineraryBasicInfoReceipt(
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
            event_id=EVENT,
            outbox_id=OUTBOX,
            policy_digest=policy_digest(),
            schema_digest=schema_digest(),
            recorded_at=datetime(2026, 8, 4, 9, 0, tzinfo=timezone.utc),
            replayed=False,
        )
        return self.receipt

    def lookup(self, **_: Any) -> ItineraryBasicInfoReceipt | None:
        self.lookup_calls += 1
        return self.receipt


def _app(service: FakeCommandService, *, enabled: bool) -> FastAPI:
    async def resolve(_: Any) -> RequestContext:
        return _context()

    application = FastAPI()
    application.include_router(
        create_itinerary_commands_router(service, resolve, enabled=enabled)
    )
    return application


async def _post(
    service: FakeCommandService,
    *,
    enabled: bool,
    body: dict[str, Any] | None = None,
) -> httpx.Response:
    transport = httpx.ASGITransport(app=_app(service, enabled=enabled))
    async with httpx.AsyncClient(
        transport=transport, base_url="http://p12d.test"
    ) as client:
        return await client.post(
            f"/v1/itineraries/{TARGET}/commands/basic-info",
            headers={"Idempotency-Key": IDEMPOTENCY_KEY},
            json=_body() if body is None else body,
        )


async def _get(service: FakeCommandService) -> httpx.Response:
    transport = httpx.ASGITransport(app=_app(service, enabled=True))
    async with httpx.AsyncClient(
        transport=transport, base_url="http://p12d.test"
    ) as client:
        return await client.get(
            f"/v1/itineraries/{TARGET}/commands/basic-info",
            headers={"Idempotency-Key": IDEMPOTENCY_KEY},
        )


async def test_default_off_flag_fails_closed_before_service_call() -> None:
    service = FakeCommandService()
    response = await _post(service, enabled=False)
    assert response.status_code == 503
    assert service.execute_calls == 0
    assert ApiDependencies.unavailable().itinerary_basic_info_command_enabled is False


async def test_enabled_route_uses_server_context_and_closed_command_shape() -> None:
    service = FakeCommandService()
    response = await _post(service, enabled=True)
    assert response.status_code == 200, response.text
    assert service.execute_calls == 1
    assert service.last_context == _context()
    assert service.last_command.target_itinerary_id == TARGET
    assert service.last_command.idempotency_key == IDEMPOTENCY_KEY
    assert not {
        "tenant_id",
        "principal_id",
        "user_id",
        "role",
        "approval",
        "force",
    } & set(type(service.last_command).model_fields)


async def test_client_authority_in_body_is_rejected_without_service_call() -> None:
    service = FakeCommandService()
    body = _body()
    body["tenant_id"] = "attacker-tenant"
    response = await _post(service, enabled=True, body=body)
    assert response.status_code == 422
    assert service.execute_calls == 0


async def test_receipt_and_lookup_do_not_expose_identity_or_patch_body() -> None:
    service = FakeCommandService()
    committed = await _post(service, enabled=True)
    lookup = await _get(service)
    assert committed.status_code == lookup.status_code == 200
    rendered = json.dumps(
        {"commit": committed.json(), "lookup": lookup.json()}, sort_keys=True
    )
    for forbidden in (
        "principal-server-derived",
        "tenant-server-derived",
        "Server command title",
        "Shanghai",
        "1200.00",
        "museum",
    ):
        assert forbidden not in rendered
    assert service.lookup_calls == 1


def test_runtime_module_has_no_model_or_tool_write_dependency() -> None:
    repository = (
        SERVICE_ROOT
        / "app"
        / "persistence"
        / "repositories"
        / "itinerary_basic_info_commands.py"
    ).read_text(encoding="utf-8")
    route = (
        SERVICE_ROOT / "app" / "api" / "routes" / "itinerary_commands.py"
    ).read_text(encoding="utf-8")
    rendered = (repository + route).lower()
    for forbidden in (
        "langgraph",
        "model_client",
        "toolregistry",
        "tool_result",
        "prompt_ref",
    ):
        assert forbidden not in rendered
