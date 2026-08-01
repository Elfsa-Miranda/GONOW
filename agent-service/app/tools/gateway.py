"""Fail-closed execution boundary for injected read-only tool adapters."""

from __future__ import annotations

import re
from collections.abc import Mapping
from dataclasses import dataclass
from typing import Protocol

from pydantic import BaseModel

from app.tools.registry import StaticToolRegistry, ToolArgValidator, ToolContractError


SHA256 = re.compile(r"^[0-9a-f]{64}$")


class ToolProviderError(RuntimeError):
    def __init__(self, code: str, *, retryable: bool) -> None:
        self.code = code
        self.retryable = retryable
        super().__init__(code)


@dataclass(frozen=True, slots=True)
class ToolExecutionContext:
    tenant_id: str
    principal_ref: str
    allowed_tools: frozenset[str]
    now_monotonic: float
    deadline_monotonic: float


@dataclass(frozen=True, slots=True)
class ToolAdapterResult:
    evidence_ref: str
    evidence_sha256: str
    body_size: int
    redirect_count: int
    provider_verified: bool


@dataclass(frozen=True, slots=True)
class ToolResult:
    tool_name: str
    tool_version: str
    evidence_ref: str
    evidence_sha256: str
    evidence_status: str
    attempts: int


class ToolHandler(Protocol):
    def invoke(self, arguments: BaseModel, *, timeout_seconds: float) -> ToolAdapterResult: ...


class InvocationGate(Protocol):
    def reserve(
        self,
        *,
        tool_name: str,
        argument_sha256: str,
        context: ToolExecutionContext,
    ) -> bool: ...


class StaticToolExecutor:
    def __init__(
        self,
        *,
        registry: StaticToolRegistry,
        validator: ToolArgValidator,
        handlers: Mapping[str, ToolHandler],
        invocation_gate: InvocationGate,
    ) -> None:
        if set(handlers) != set(registry.names):
            raise ToolContractError("tool.unknown")
        self._registry = registry
        self._validator = validator
        self._handlers = dict(handlers)
        self._invocation_gate = invocation_gate

    def execute(
        self,
        name: str,
        raw_arguments: object,
        *,
        context: ToolExecutionContext,
    ) -> ToolResult:
        spec = self._registry.resolve(name)
        if (
            name not in context.allowed_tools
            or context.now_monotonic > context.deadline_monotonic
            or not context.tenant_id
            or not context.principal_ref.startswith("principal://")
        ):
            raise ToolContractError("tool.unknown")
        call = self._validator.validate(name, raw_arguments)
        if not self._invocation_gate.reserve(
            tool_name=name,
            argument_sha256=call.argument_sha256,
            context=context,
        ):
            raise ToolContractError("tool.invocation_conflict")
        handler = self._handlers[name]
        attempts = 0
        while attempts < spec.max_attempts:
            attempts += 1
            try:
                adapter_result = handler.invoke(
                    call.arguments,
                    timeout_seconds=spec.timeout_seconds,
                )
            except ToolProviderError as error:
                if error.retryable and attempts < spec.max_attempts:
                    continue
                raise ToolContractError(error.code) from error
            if (
                adapter_result.redirect_count != 0
                or adapter_result.body_size < 0
                or adapter_result.body_size > spec.max_result_bytes
                or not adapter_result.evidence_ref.startswith("evidence://")
                or SHA256.fullmatch(adapter_result.evidence_sha256) is None
            ):
                raise ToolContractError("tool.result_rejected")
            return ToolResult(
                tool_name=spec.name,
                tool_version=spec.version,
                evidence_ref=adapter_result.evidence_ref,
                evidence_sha256=adapter_result.evidence_sha256,
                evidence_status=(
                    "verified_current" if adapter_result.provider_verified else "unverified"
                ),
                attempts=attempts,
            )
        raise ToolContractError("tool.timeout")
