from __future__ import annotations

import site
import sys
from pathlib import Path

import pytest


SERVICE_ROOT = Path(__file__).resolve().parents[2]
site.addsitedir(str(SERVICE_ROOT / ".venv" / "Lib" / "site-packages"))
sys.path.insert(0, str(SERVICE_ROOT))

from app.tools.gateway import (  # noqa: E402
    StaticToolExecutor,
    ToolAdapterResult,
    ToolExecutionContext,
)
from app.tools.registry import StaticToolRegistry, ToolArgValidator, ToolContractError  # noqa: E402


class _Handler:
    def __init__(self, result: ToolAdapterResult | None = None) -> None:
        self.calls = 0
        self.result = result or ToolAdapterResult("evidence://ok", "b" * 64, 10, 0, True)

    def invoke(self, arguments, *, timeout_seconds):
        self.calls += 1
        return self.result


class _Gate:
    def reserve(self, **kwargs) -> bool:
        return True


def _executor(result: ToolAdapterResult | None = None):
    registry = StaticToolRegistry()
    handlers = {name: _Handler(result) for name in registry.names}
    executor = StaticToolExecutor(
        registry=registry,
        validator=ToolArgValidator(registry),
        handlers=handlers,
        invocation_gate=_Gate(),
    )
    context = ToolExecutionContext(
        "tenant", "principal://security", frozenset(registry.names), 1, 10
    )
    return executor, handlers, context


@pytest.mark.parametrize(
    "payload",
    (
        {"keyword": "x", "city_code": "SHA", "url": "https://internal"},
        {"keyword": "select x from secrets", "city_code": "SHA"},
        {"keyword": "file:///etc/passwd", "city_code": "SHA"},
        {"keyword": "x", "city_code": "SHA", "user_id": "victim"},
        {"keyword": "x", "city_code": "SHA", "tenant_id": "other"},
    ),
)
def test_tool_permissions_reject_url_sql_file_or_identity_args(payload) -> None:
    executor, handlers, context = _executor()
    with pytest.raises(ToolContractError, match="tool.invalid_args"):
        executor.execute("poi.search", payload, context=context)
    assert handlers["poi.search"].calls == 0


def test_tool_permissions_reject_redirect() -> None:
    executor, handlers, context = _executor(
        ToolAdapterResult("evidence://redirect", "c" * 64, 10, 1, False)
    )
    with pytest.raises(ToolContractError, match="tool.result_rejected"):
        executor.execute(
            "weather.current", {"city_code": "SHA", "units": "metric"}, context=context
        )
    assert handlers["weather.current"].calls == 1


def test_tool_permissions_reject_oversized_body() -> None:
    executor, _, context = _executor(ToolAdapterResult("evidence://large", "d" * 64, 99_999, 0, True))
    with pytest.raises(ToolContractError, match="tool.result_rejected"):
        executor.execute(
            "weather.current", {"city_code": "SHA", "units": "metric"}, context=context
        )


def test_tool_permissions_reject_unapproved_tool_before_handler_lookup() -> None:
    executor, handlers, context = _executor()
    with pytest.raises(ToolContractError, match="tool.unknown"):
        executor.execute("shell.run", {}, context=context)
    assert sum(handler.calls for handler in handlers.values()) == 0
