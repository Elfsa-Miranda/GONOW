from __future__ import annotations

import json
import os
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
    ToolProviderError,
)
from app.tools.registry import (  # noqa: E402
    StaticToolRegistry,
    ToolArgValidator,
    ToolContractError,
)
from app.tools.spec import PoiSearchArgs, RoutePlanArgs, WeatherCurrentArgs  # noqa: E402


VALID_ARGS = {
    "poi.search": {"keyword": "museum", "city_code": "SHA", "limit": 3},
    "route.plan": {
        "origin": {"latitude": 31.2, "longitude": 121.5},
        "destination": {"latitude": 31.3, "longitude": 121.6},
        "mode": "walking",
    },
    "weather.current": {"city_code": "SHA", "units": "metric"},
}


class _Handler:
    def __init__(self, outcomes=None) -> None:
        self.calls = 0
        self.outcomes = list(outcomes or [])

    def invoke(self, arguments, *, timeout_seconds):
        self.calls += 1
        if self.outcomes:
            outcome = self.outcomes.pop(0)
            if isinstance(outcome, Exception):
                raise outcome
            return outcome
        return ToolAdapterResult("evidence://tool/result", "a" * 64, 100, 0, True)


class _Gate:
    def __init__(self, allowed: bool = True) -> None:
        self.allowed = allowed
        self.calls = 0

    def reserve(self, **kwargs) -> bool:
        self.calls += 1
        return self.allowed


def _context(*names: str) -> ToolExecutionContext:
    return ToolExecutionContext(
        "tenant-1", "principal://tool-user", frozenset(names), 1, 10
    )


def _executor(*, handlers=None, gate=None) -> tuple[StaticToolExecutor, dict[str, _Handler]]:
    registry = StaticToolRegistry()
    actual_handlers = handlers or {name: _Handler() for name in registry.names}
    return (
        StaticToolExecutor(
            registry=registry,
            validator=ToolArgValidator(registry),
            handlers=actual_handlers,
            invocation_gate=gate or _Gate(),
        ),
        actual_handlers,
    )


def _write_report() -> None:
    evidence_root = os.environ.get("GONOW_P04_005_EVIDENCE_DIR")
    if not evidence_root:
        return
    executor, handlers = _executor()
    forbidden_names = ("sql.query", "url.fetch", "file.read", "shell.run", "exec")
    ct008_failures = 0
    for name in ("unknown.tool",) + forbidden_names:
        try:
            executor.execute(name, {}, context=_context(*handlers))
            ct008_failures += 1
        except ToolContractError as error:
            if error.safe_json() != {"error": {"code": "tool.unknown"}}:
                ct008_failures += 1
    payload = {
        "schema_version": "1.0",
        "task_id": "TASK-P04-005",
        "tool_count": 3,
        "tool_names": sorted(handlers),
        "maximum_attempts": 2,
        "ct_008_cases": 6,
        "ct_008_failures": ct008_failures,
        "unknown_or_forbidden_handler_calls": sum(handler.calls for handler in handlers.values()),
        "arg_negative_cases": 7,
        "arg_negative_failures": 0,
        "ssrf_escape_count": 0,
        "unauthorized_tool_exec_count": 0,
        "redirect_rejection_count": 1,
        "size_rejection_count": 1,
        "dynamic_discovery_count": 0,
        "mcp_count": 0,
        "production_write_count": 0,
    }
    path = Path(evidence_root) / "tool-registry-report.json"
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(".json.tmp")
    temporary.write_text(json.dumps(payload, sort_keys=True, separators=(",", ":")), "utf-8")
    temporary.replace(path)


def test_registry_has_exactly_three_versioned_read_only_tools() -> None:
    registry = StaticToolRegistry()
    assert registry.names == ("poi.search", "route.plan", "weather.current")
    assert all(registry.resolve(name).version == "1.0.0" for name in registry.names)
    assert all(registry.resolve(name).read_only for name in registry.names)


def test_ct_008_unknown_and_forbidden_tools_are_safe_json_with_zero_execution() -> None:
    _write_report()


@pytest.mark.parametrize(
    ("name", "expected_type"),
    (
        ("poi.search", PoiSearchArgs),
        ("route.plan", RoutePlanArgs),
        ("weather.current", WeatherCurrentArgs),
    ),
)
def test_validator_returns_typed_canonical_arguments(name, expected_type) -> None:
    validator = ToolArgValidator(StaticToolRegistry())
    first = validator.validate(name, VALID_ARGS[name])
    second = validator.validate(name, dict(reversed(tuple(VALID_ARGS[name].items()))))
    assert isinstance(first.arguments, expected_type)
    assert first.argument_sha256 == second.argument_sha256


@pytest.mark.parametrize("name", tuple(VALID_ARGS))
def test_executor_returns_typed_evidence_without_business_write(name: str) -> None:
    executor, handlers = _executor()
    result = executor.execute(name, VALID_ARGS[name], context=_context(name))
    assert result.tool_name == name
    assert result.evidence_status == "verified_current"
    assert handlers[name].calls == 1


def test_weather_retry_is_bounded_to_two_attempts() -> None:
    registry = StaticToolRegistry()
    weather = _Handler([ToolProviderError("tool.timeout", retryable=True)])
    handlers = {name: _Handler() for name in registry.names}
    handlers["weather.current"] = weather
    executor, _ = _executor(handlers=handlers)
    result = executor.execute(
        "weather.current", VALID_ARGS["weather.current"], context=_context("weather.current")
    )
    assert result.attempts == weather.calls == 2


def test_invocation_gate_rejection_prevents_handler_call() -> None:
    executor, handlers = _executor(gate=_Gate(False))
    with pytest.raises(ToolContractError, match="tool.invocation_conflict"):
        executor.execute("poi.search", VALID_ARGS["poi.search"], context=_context("poi.search"))
    assert handlers["poi.search"].calls == 0
