from __future__ import annotations

import site
import sys
import uuid
from pathlib import Path

import pytest
from sqlalchemy import UniqueConstraint


SERVICE_ROOT = Path(__file__).resolve().parents[3]
site.addsitedir(str(SERVICE_ROOT / ".venv" / "Lib" / "site-packages"))
sys.path.insert(0, str(SERVICE_ROOT))

from app.persistence.models.runtime import IdempotencyRecord, RunState  # noqa: E402
from app.persistence.repositories.runs import (  # noqa: E402
    RunCreateResult,
    RunsRepository,
    TransactionRequired,
)


class _SessionWithoutTransaction:
    def in_transaction(self) -> bool:
        return False


class _TransactionWithoutDatabaseAccess:
    def in_transaction(self) -> bool:
        return True

    def execute(self, _statement):
        raise AssertionError("invalid input must fail before database access")


def _create_arguments() -> dict[str, object]:
    return {
        "tenant_id": "tenant-harness-05",
        "principal_id": "principal-harness-05",
        "thread_id": uuid.uuid4(),
        "request_scope": "harness.idempotency",
        "idempotency_key": "key-harness-05",
        "request_hash": "1" * 64,
        "manifest_digest": "2" * 64,
        "manifest": {"fixture": "harness-05"},
    }


def test_05_idempotency_guard_s_result_marks_original_and_replay() -> None:
    run_id = uuid.uuid4()
    original = RunCreateResult(run_id=run_id, state=RunState.QUEUED, replayed=False)
    replay = RunCreateResult(run_id=run_id, state=RunState.QUEUED, replayed=True)
    assert original.run_id == replay.run_id
    assert (original.replayed, replay.replayed) == (False, True)


def test_05_idempotency_guard_i_database_scope_has_one_unique_constraint() -> None:
    constraints = {
        constraint.name: tuple(column.name for column in constraint.columns)
        for constraint in IdempotencyRecord.__table__.constraints
        if isinstance(constraint, UniqueConstraint)
    }
    assert constraints["uq_idempotency_request_key"] == (
        "tenant_id",
        "principal_id",
        "request_scope",
        "idempotency_key",
    )


def test_05_idempotency_guard_d_rejects_non_sha_request_before_database() -> None:
    arguments = _create_arguments()
    arguments["request_hash"] = "not-a-sha256"
    repository = RunsRepository(_TransactionWithoutDatabaseAccess())  # type: ignore[arg-type]
    with pytest.raises(ValueError, match="request_hash must be lowercase SHA-256"):
        repository.create_or_replay_run(**arguments)  # type: ignore[arg-type]


def test_05_idempotency_guard_d_requires_caller_owned_transaction() -> None:
    repository = RunsRepository(_SessionWithoutTransaction())  # type: ignore[arg-type]
    with pytest.raises(TransactionRequired, match="runtime.transaction_required"):
        repository.create_or_replay_run(**_create_arguments())  # type: ignore[arg-type]
