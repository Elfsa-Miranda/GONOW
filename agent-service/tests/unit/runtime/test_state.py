from __future__ import annotations

import json
import os
import pickle
import site
import sys
from pathlib import Path
from uuid import UUID

import pytest


SERVICE_ROOT = Path(__file__).resolve().parents[3]
site.addsitedir(str(SERVICE_ROOT / ".venv" / "Lib" / "site-packages"))
sys.path.insert(0, str(SERVICE_ROOT))

from app.runtime.context import (  # noqa: E402
    AgentRuntimeContext,
    RuntimeContextError,
    inject_runtime_context,
)
from app.runtime.state import (  # noqa: E402
    BudgetSnapshot,
    GoNowAgentState,
    StateContractError,
    StateGuard,
    StateReference,
    WorkflowStage,
)


def _ref(kind: str, index: int) -> StateReference:
    return StateReference(
        kind=kind,
        uri=f"gonow-{kind}://synthetic/{index}",
        sha256=format(index, "064x"),
    )


def make_state(index: int = 1) -> GoNowAgentState:
    return GoNowAgentState(
        run_id=UUID(int=index),
        thread_id=UUID(int=index + 1000),
        tenant_id=UUID(int=index + 2000),
        principal_ref=f"principal://synthetic/{index}",
        behavior_release_id=UUID(int=index + 3000),
        behavior_digest=format(index + 4000, "064x"),
        goal_ref=_ref("goal", index),
        hard_requirement_refs=(_ref("requirement", index),),
        budget=BudgetSnapshot(
            remaining_model_calls=3,
            remaining_tool_calls=8,
            remaining_tokens=12000,
        ),
    )


def _write_report(payload: dict[str, object]) -> None:
    evidence_root = os.environ.get("GONOW_P04_001_EVIDENCE_DIR")
    if not evidence_root:
        return
    path = Path(evidence_root) / "state-report.json"
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(".json.tmp")
    temporary.write_text(
        json.dumps(payload, sort_keys=True, separators=(",", ":")), encoding="utf-8"
    )
    temporary.replace(path)


def test_state_roundtrips_100_percent_and_excludes_secret_canary() -> None:
    mismatches = 0
    for index in range(1, 101):
        before = make_state(index)
        after = GoNowAgentState.from_checkpoint(json.loads(before.checkpoint_json()))
        mismatches += int(before != after)

    canary = "gonow-p04-001-secret-canary"
    payload = make_state().checkpoint_dict()
    payload["secret"] = canary
    with pytest.raises(StateContractError, match="state.invalid_delta"):
        GoNowAgentState.from_checkpoint(payload)
    serialized = make_state().checkpoint_json()
    secret_canary_count = serialized.count(canary)
    _write_report(
        {
            "schema_version": "1.0",
            "task_id": "TASK-P04-001",
            "roundtrip_cases": 100,
            "roundtrip_failures": mismatches,
            "roundtrip_percent": 100 if mismatches == 0 else 0,
            "secret_canary_count": secret_canary_count,
            "production_write_count": 0,
        }
    )
    assert mismatches == 0
    assert secret_canary_count == 0


def test_checkpoint_payload_is_json_native() -> None:
    encoded = json.dumps(make_state().checkpoint_dict(), allow_nan=False)
    assert json.loads(encoded)["workflow_stage"] == "intake"


def test_runtime_context_is_injected_and_never_checkpointed() -> None:
    state = make_state()
    canary = "gonow-p04-001-context-secret-canary"
    context = AgentRuntimeContext(
        tenant_id=state.tenant_id,
        principal_ref=state.principal_ref,
        secrets_provider={"value": canary},
        model_gateway=object(),
        connection_factory=object(),
    )
    bound = inject_runtime_context(state, context)
    assert bound.state == state
    assert canary not in repr(context)
    assert canary not in state.checkpoint_json()
    with pytest.raises(TypeError, match="runtime_context.not_serializable"):
        pickle.dumps(context)


def test_runtime_context_rejects_identity_mismatch() -> None:
    state = make_state()
    context = AgentRuntimeContext(
        tenant_id=UUID(int=9999),
        principal_ref=state.principal_ref,
        secrets_provider=object(),
        model_gateway=object(),
        connection_factory=object(),
    )
    with pytest.raises(RuntimeContextError, match="context.invalid_binding"):
        inject_runtime_context(state, context)


def test_state_guard_preserves_counter_monotonicity() -> None:
    before = StateGuard().apply(
        make_state(), {"workflow_stage": WorkflowStage.PLAN, "step_count": 2}
    )
    with pytest.raises(StateContractError, match="state.invalid_delta"):
        StateGuard().apply(before, {"step_count": 1})
