"""Default-off principal-aware Memory read port for the existing single Agent."""

from __future__ import annotations

from dataclasses import dataclass
from datetime import UTC, datetime

from app.memory.contracts import AuthorizationContext, ConsentGrant, MemoryFact, assert_consent
from app.persistence.repositories.memory import InMemoryMemoryRepository


@dataclass(frozen=True)
class MemoryReadPortConfig:
    enabled: bool = False
    kill_switch: bool = False
    generation: int = 0


@dataclass(frozen=True)
class MemoryReadResult:
    status: str
    facts: tuple[MemoryFact, ...]
    generation: int
    materialized_count: int


class SingleAgentMemoryReadPort:
    """Returns typed data only; it has no model, Tool, or authority execution port."""

    def __init__(self, repository: InMemoryMemoryRepository, config: MemoryReadPortConfig | None = None) -> None:
        self._repository = repository
        self._config = config or MemoryReadPortConfig()

    @property
    def config(self) -> MemoryReadPortConfig:
        return self._config

    def reconfigure(self, *, enabled: bool, kill_switch: bool = False) -> None:
        self._config = MemoryReadPortConfig(enabled=enabled, kill_switch=kill_switch, generation=self._config.generation + 1)

    def read(self, *, consent: ConsentGrant | None, context: AuthorizationContext, now: datetime | None = None) -> MemoryReadResult:
        at = now or datetime.now(UTC)
        if not self._config.enabled or self._config.kill_switch:
            return MemoryReadResult(status="disabled", facts=(), generation=self._config.generation, materialized_count=0)
        assert_consent(consent=consent, context=context, at=at)
        records = self._repository.active_records_for(tenant_id=context.tenant_id, principal_id=context.principal_id, purpose=context.purpose)
        facts = tuple(record.fact for record in records if record.retention_until > at)
        return MemoryReadResult(status="enabled", facts=facts, generation=self._config.generation, materialized_count=len(facts))
