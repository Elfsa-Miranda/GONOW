from __future__ import annotations

import site
import sys
import uuid
from pathlib import Path

import pytest
from sqlalchemy.dialects import postgresql


SERVICE_ROOT = Path(__file__).resolve().parents[3]
site.addsitedir(str(SERVICE_ROOT / ".venv" / "Lib" / "site-packages"))
sys.path.insert(0, str(SERVICE_ROOT))

from app.persistence.models.runtime import RunState, TERMINAL_RUN_STATES  # noqa: E402
from app.persistence.repositories.runs import (  # noqa: E402
    ALLOWED_TRANSITIONS,
    RunStateConflict,
    RunsRepository,
)


class _ScalarResult:
    def __init__(self, value: object | None) -> None:
        self._value = value

    def scalar_one_or_none(self) -> object | None:
        return self._value


class _CapturingSession:
    def __init__(self, result: object | None) -> None:
        self.result = result
        self.statement = None

    def in_transaction(self) -> bool:
        return True

    def execute(self, statement):
        self.statement = statement
        return _ScalarResult(self.result)


def _transition(repository: RunsRepository, target: RunState):
    return repository.transition_state(
        tenant_id="tenant-harness-34",
        run_id=uuid.UUID("11111111-1111-4111-8111-111111111111"),
        expected_state=RunState.RUNNING,
        expected_version=7,
        target_state=target,
    )


def test_34_consistency_fence_s_terminal_states_have_no_outbound_edges() -> None:
    assert TERMINAL_RUN_STATES == {
        RunState.SUCCEEDED,
        RunState.BLOCKED,
        RunState.FAILED,
        RunState.CANCELLED,
    }
    assert all(ALLOWED_TRANSITIONS[state] == frozenset() for state in TERMINAL_RUN_STATES)


def test_34_consistency_fence_i_state_update_binds_state_version_and_tenant() -> None:
    sentinel = object()
    session = _CapturingSession(sentinel)
    result = _transition(RunsRepository(session), RunState.SUCCEEDED)  # type: ignore[arg-type]
    assert result is sentinel
    assert session.statement is not None
    sql = str(
        session.statement.compile(
            dialect=postgresql.dialect(),
            compile_kwargs={"literal_binds": True},
        )
    )
    assert "agent_runtime.runs.tenant_id = 'tenant-harness-34'" in sql
    assert "agent_runtime.runs.state = 'running'" in sql
    assert "agent_runtime.runs.version = 7" in sql
    assert "version=(agent_runtime.runs.version + 1)" in sql


def test_34_consistency_fence_d_illegal_terminal_transition_never_executes() -> None:
    session = _CapturingSession(object())
    repository = RunsRepository(session)  # type: ignore[arg-type]
    with pytest.raises(RunStateConflict, match="run.state_conflict"):
        repository.transition_state(
            tenant_id="tenant-harness-34",
            run_id=uuid.uuid4(),
            expected_state=RunState.SUCCEEDED,
            expected_version=8,
            target_state=RunState.RUNNING,
        )
    assert session.statement is None


def test_34_consistency_fence_d_stale_version_has_no_legal_winner() -> None:
    session = _CapturingSession(None)
    with pytest.raises(RunStateConflict, match="run.state_conflict"):
        _transition(RunsRepository(session), RunState.FAILED)  # type: ignore[arg-type]
    assert session.statement is not None
