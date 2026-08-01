"""Static Tool Registry and strict canonical argument validation."""

from __future__ import annotations

import hashlib
import json
import re
from dataclasses import dataclass
from types import MappingProxyType
from typing import Any

from pydantic import BaseModel, ValidationError

from app.tools.spec import PoiSearchArgs, RoutePlanArgs, ToolSpec, WeatherCurrentArgs


FORBIDDEN_NAMES = frozenset({"sql", "url", "file", "shell", "exec", "command", "mcp"})
FORBIDDEN_ARGUMENT_KEYS = frozenset(
    {
        "user_id",
        "tenant",
        "tenant_id",
        "url",
        "uri",
        "sql",
        "query",
        "file",
        "path",
        "shell",
        "exec",
        "command",
    }
)
UNSAFE_VALUE = re.compile(
    r"(?i)(?:https?|file)://|^[A-Za-z]:[\\/]|^/|\b(?:select|insert|update|delete|drop|alter)\b.*\b(?:from|into|table|where)\b"
)


class ToolContractError(ValueError):
    def __init__(self, code: str) -> None:
        self.code = code
        super().__init__(code)

    def safe_json(self) -> dict[str, dict[str, str]]:
        return {"error": {"code": self.code}}


APPROVED_TOOL_SPECS = (
    ToolSpec("poi.search", "1.0.0", PoiSearchArgs, 1, 3.0, 16_384),
    ToolSpec("route.plan", "1.0.0", RoutePlanArgs, 1, 5.0, 32_768),
    ToolSpec("weather.current", "1.0.0", WeatherCurrentArgs, 2, 3.0, 8_192),
)


class StaticToolRegistry:
    def __init__(self, *, available: bool = True) -> None:
        self._available = available
        self._specs = MappingProxyType({spec.name: spec for spec in APPROVED_TOOL_SPECS})

    @property
    def names(self) -> tuple[str, ...]:
        return tuple(sorted(self._specs))

    def resolve(self, name: str) -> ToolSpec:
        lowered = name.casefold()
        if (
            not self._available
            or name not in self._specs
            or any(token in lowered for token in FORBIDDEN_NAMES)
        ):
            raise ToolContractError("tool.unknown")
        return self._specs[name]


@dataclass(frozen=True, slots=True)
class ValidatedToolCall:
    spec: ToolSpec
    arguments: BaseModel
    canonical_json: str
    argument_sha256: str


class ToolArgValidator:
    def __init__(self, registry: StaticToolRegistry, *, available: bool = True) -> None:
        self._registry = registry
        self._available = available

    def validate(self, name: str, raw_arguments: Any) -> ValidatedToolCall:
        if not self._available or not isinstance(raw_arguments, dict):
            raise ToolContractError("tool.invalid_args")
        self._reject_unsafe(raw_arguments)
        spec = self._registry.resolve(name)
        try:
            arguments = spec.argument_model.model_validate(raw_arguments)
        except (TypeError, ValidationError, ValueError) as error:
            raise ToolContractError("tool.invalid_args") from error
        canonical_json = json.dumps(
            arguments.model_dump(mode="json"),
            sort_keys=True,
            separators=(",", ":"),
            ensure_ascii=False,
        )
        return ValidatedToolCall(
            spec=spec,
            arguments=arguments,
            canonical_json=canonical_json,
            argument_sha256=hashlib.sha256(canonical_json.encode("utf-8")).hexdigest(),
        )

    @classmethod
    def _reject_unsafe(cls, value: Any) -> None:
        if isinstance(value, dict):
            for raw_key, child in value.items():
                key = str(raw_key).casefold()
                if key in FORBIDDEN_ARGUMENT_KEYS:
                    raise ToolContractError("tool.invalid_args")
                cls._reject_unsafe(child)
        elif isinstance(value, (list, tuple)):
            for child in value:
                cls._reject_unsafe(child)
        elif isinstance(value, str) and UNSAFE_VALUE.search(value):
            raise ToolContractError("tool.invalid_args")
