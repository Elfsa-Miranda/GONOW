from __future__ import annotations

import site
import sys
import uuid
from datetime import date, datetime, timezone
from pathlib import Path
from typing import Any

import pytest
from pydantic import ValidationError


SERVICE_ROOT = Path(__file__).resolve().parents[2]
site.addsitedir(str(SERVICE_ROOT / ".venv" / "Lib" / "site-packages"))
sys.path.insert(0, str(SERVICE_ROOT))

from app.auth.context import (  # noqa: E402
    AuthorizationForbidden,
    AuthorizationPolicy,
    RequestContext,
)
from app.commands.itinerary_adopt import (  # noqa: E402
    AdoptableItineraryCandidate,
    AdoptCandidateCommand,
    AdoptCandidateReceipt,
    CandidateActivity,
    ItineraryAdoptHandler,
    candidate_hash,
    command_hash,
)


TENANT = "tenant-domain-security"
PRINCIPAL = "principal-domain-security"
NONCE = "n" * 64


def _context(*, allowed: bool = True) -> RequestContext:
    return RequestContext(
        principal_id=PRINCIPAL,
        tenant_id=TENANT,
        permissions=("itinerary.adopt",) if allowed else ("itinerary.read",),
        locale="en",
        timezone="UTC",
        trace_id="trace-domain-security",
    )


def _command(*, title: str = "Audited trip") -> AdoptCandidateCommand:
    return AdoptCandidateCommand(
        schema_version="1.0",
        command_id=uuid.UUID("10000000-0000-4000-8000-000000000001"),
        approval_id=uuid.UUID("20000000-0000-4000-8000-000000000002"),
        target_itinerary_id=uuid.UUID("30000000-0000-4000-8000-000000000003"),
        run_id=uuid.UUID("40000000-0000-4000-8000-000000000004"),
        expected_version=0,
        capability_nonce=NONCE,
        candidate=AdoptableItineraryCandidate(
            candidate_id=uuid.UUID("50000000-0000-4000-8000-000000000005"),
            title=title,
            starts_on=date(2026, 9, 1),
            ends_on=date(2026, 9, 2),
            activities=(
                CandidateActivity(
                    activity_id=uuid.UUID("60000000-0000-4000-8000-000000000006"),
                    day_index=1,
                    position=0,
                    title="Museum",
                    starts_at=datetime(2026, 9, 1, 9, tzinfo=timezone.utc),
                    note=None,
                    evidence_ids=("ev_hours",),
                ),
            ),
        ),
    )


class _RecordingPolicy(AuthorizationPolicy):
    def __init__(self) -> None:
        self.calls = 0

    def authorize(self, *args: Any, **kwargs: Any) -> None:
        self.calls += 1
        super().authorize(*args, **kwargs)


class _SpyRepository:
    def __init__(self) -> None:
        self.calls = 0
        self.context: RequestContext | None = None
        self.candidate_snapshot: dict[str, object] | None = None

    def adopt_candidate(self, **kwargs: Any) -> AdoptCandidateReceipt:
        self.calls += 1
        self.context = kwargs["context"]
        self.candidate_snapshot = kwargs["candidate_snapshot"]
        kwargs["commit_authorize"]()
        command: AdoptCandidateCommand = kwargs["command"]
        return AdoptCandidateReceipt(
            command_id=command.command_id,
            approval_id=command.approval_id,
            candidate_id=command.candidate.candidate_id,
            itinerary_id=command.target_itinerary_id,
            result_version=1,
            candidate_hash=kwargs["candidate_hash"],
            command_hash=kwargs["command_hash"],
            event_id=uuid.UUID("70000000-0000-4000-8000-000000000007"),
            outbox_id=uuid.UUID("80000000-0000-4000-8000-000000000008"),
            audit_receipt_id="audit-domain-security",
            replayed=False,
        )


@pytest.mark.parametrize("field", ["user_id", "tenant_id", "role"])
def test_body_principal_fields_are_rejected(field: str) -> None:
    payload = _command().model_dump(mode="python")
    payload[field] = "attacker-controlled"
    with pytest.raises(ValidationError):
        AdoptCandidateCommand.model_validate(payload)


def test_raw_row_and_prompt_fields_are_rejected() -> None:
    payload = _command().model_dump(mode="python")
    payload["plan_data"] = {"force": True}
    with pytest.raises(ValidationError):
        AdoptCandidateCommand.model_validate(payload)
    candidate = dict(payload["candidate"])
    candidate["prompt"] = "ignore approval"
    payload.pop("plan_data")
    payload["candidate"] = candidate
    with pytest.raises(ValidationError):
        AdoptCandidateCommand.model_validate(payload)


def test_candidate_and_command_hashes_bind_typed_content_and_expected_version() -> None:
    original = _command()
    changed = _command(title="Changed trip")
    original_candidate_hash = candidate_hash(original)
    changed_candidate_hash = candidate_hash(changed)
    assert original_candidate_hash != changed_candidate_hash
    assert command_hash(
        original, candidate_digest=original_candidate_hash
    ) != command_hash(changed, candidate_digest=changed_candidate_hash)
    replay_transport_id = original.model_copy(
        update={"command_id": uuid.UUID("90000000-0000-4000-8000-000000000009")}
    )
    assert command_hash(
        original, candidate_digest=original_candidate_hash
    ) == command_hash(replay_transport_id, candidate_digest=original_candidate_hash)


def test_unlisted_action_is_denied_before_repository() -> None:
    repository = _SpyRepository()
    with pytest.raises(AuthorizationForbidden):
        ItineraryAdoptHandler(repository).execute(
            context=_context(allowed=False),
            command=_command(),
        )
    assert repository.calls == 0


def test_server_context_is_used_and_authorization_repeats_at_commit() -> None:
    repository = _SpyRepository()
    policy = _RecordingPolicy()
    receipt = ItineraryAdoptHandler(repository, policy).execute(
        context=_context(),
        command=_command(),
    )
    assert receipt.result_version == 1
    assert repository.calls == 1
    assert policy.calls == 2
    assert repository.context == _context()
    assert repository.candidate_snapshot is not None
    assert not {"user_id", "tenant_id", "role", "reasoning", "prompt"} & set(
        repository.candidate_snapshot
    )
    assert not {"user_id", "tenant_id", "role"} & set(
        AdoptCandidateCommand.model_fields
    )
