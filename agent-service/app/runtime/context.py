"""In-memory runtime dependency injection kept outside checkpoint state."""

from __future__ import annotations

from dataclasses import dataclass
from typing import Any
from uuid import UUID

from app.runtime.state import GoNowAgentState


class RuntimeContextError(ValueError):
    def __init__(self, code: str = "context.invalid_binding") -> None:
        self.code = code
        super().__init__(code)


@dataclass(frozen=True, slots=True, repr=False)
class AgentRuntimeContext:
    """Short-lived process objects; deliberately non-serializable."""

    tenant_id: UUID
    principal_ref: str
    secrets_provider: Any
    model_gateway: Any
    connection_factory: Any

    def __repr__(self) -> str:
        return (
            "AgentRuntimeContext(tenant_id=<bound>, principal_ref=<bound>, "
            "dependencies=<redacted>)"
        )

    def __getstate__(self) -> None:
        raise TypeError("runtime_context.not_serializable")


@dataclass(frozen=True, slots=True)
class BoundAgentExecution:
    state: GoNowAgentState
    context: AgentRuntimeContext

    def __getstate__(self) -> None:
        raise TypeError("runtime_context.not_serializable")


def inject_runtime_context(
    state: GoNowAgentState, context: AgentRuntimeContext
) -> BoundAgentExecution:
    """Bind only when server-derived identity matches the immutable state refs."""

    if state.tenant_id != context.tenant_id or state.principal_ref != context.principal_ref:
        raise RuntimeContextError()
    return BoundAgentExecution(state=state, context=context)
