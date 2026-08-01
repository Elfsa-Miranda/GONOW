from __future__ import annotations

import site
import sys
from pathlib import Path

import pytest


SERVICE_ROOT = Path(__file__).resolve().parents[3]
site.addsitedir(str(SERVICE_ROOT / ".venv" / "Lib" / "site-packages"))
sys.path.insert(0, str(SERVICE_ROOT))

from app.tools.gateway import (  # noqa: E402
    StaticToolExecutor,
    ToolAdapterResult,
    ToolExecutionContext,
    ToolProviderError,
)
from app.tools.registry import StaticToolRegistry, ToolArgValidator, ToolContractError  # noqa: E402


class _Handler:
    def __init__(self, result=None) -> None:
        self.calls = 0
        self.result = result or ToolAdapterResult("evidence://ok", "e" * 64, 10, 0, True)

    def invoke(self, arguments, *, timeout_seconds):
        self.calls += 1
        if isinstance(self.result, Exception):
            raise self.result
        return self.result


class _Gate:
    def __init__(self, allowed: bool = True) -> None:
        self.allowed = allowed

    def reserve(self, **kwargs) -> bool:
        return self.allowed


def _executor(handler: _Handler, *, gate: _Gate | None = None):
    registry = StaticToolRegistry()
    handlers = {name: _Handler() for name in registry.names}
    handlers["poi.search"] = handler
    return StaticToolExecutor(
        registry=registry,
        validator=ToolArgValidator(registry),
        handlers=handlers,
        invocation_gate=gate or _Gate(),
    )


def _context() -> ToolExecutionContext:
    return ToolExecutionContext("tenant", "principal://harness", frozenset({"poi.search"}), 1, 10)


def _args() -> dict[str, object]:
    return {"keyword": "museum", "city_code": "SHA", "limit": 3}


def test_17_tool_executor_s_returns_typed_evidence() -> None:
    result = _executor(_Handler()).execute("poi.search", _args(), context=_context())
    assert result.evidence_status == "verified_current" and result.attempts == 1


def test_17_tool_executor_i_timeout_is_stable_and_bounded() -> None:
    handler = _Handler(ToolProviderError("tool.timeout", retryable=True))
    with pytest.raises(ToolContractError, match="tool.timeout"):
        _executor(handler).execute("poi.search", _args(), context=_context())
    assert handler.calls == 1


@pytest.mark.parametrize(
    "result",
    (
        ToolAdapterResult("evidence://redirect", "f" * 64, 10, 1, False),
        ToolAdapterResult("evidence://large", "f" * 64, 99_999, 0, False),
    ),
)
def test_17_tool_executor_i_rejects_redirect_or_size(result: ToolAdapterResult) -> None:
    with pytest.raises(ToolContractError, match="tool.result_rejected"):
        _executor(_Handler(result)).execute("poi.search", _args(), context=_context())


def test_17_tool_executor_d_gate_rejection_has_zero_handler_calls() -> None:
    handler = _Handler()
    with pytest.raises(ToolContractError, match="tool.invocation_conflict"):
        _executor(handler, gate=_Gate(False)).execute("poi.search", _args(), context=_context())
    assert handler.calls == 0
