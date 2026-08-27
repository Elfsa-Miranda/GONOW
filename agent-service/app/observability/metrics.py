"""Low-cardinality operational metrics for the Release B runtime."""

from __future__ import annotations

from collections import defaultdict
from collections.abc import Mapping
from typing import Literal

from pydantic import BaseModel, ConfigDict, Field, model_validator


MetricKind = Literal["counter", "gauge", "histogram"]
MetricDomain = Literal["run", "tool", "context", "validation", "cost", "recovery"]

FORBIDDEN_LABEL_KEYS = frozenset(
    {"behavior_digest", "email", "prompt", "request_id", "run_id", "tenant_id", "thread_id", "user_id"}
)

LABEL_VALUE_DOMAINS: dict[str, frozenset[str]] = {
    "outcome": frozenset({"success", "denied", "failed", "degraded"}),
    "tool_class": frozenset({"weather", "map", "search", "solver", "domain_command"}),
    "validation_result": frozenset({"valid", "warning", "invalid", "unverified"}),
    "recovery_reason": frozenset({"lease_expired", "worker_restart", "dependency_timeout", "cancel"}),
    "context_outcome": frozenset(
        {"compiled", "compacted", "needs_clarification", "blocked"}
    ),
    "context_reason": frozenset({
        "none",
        "context.input_invalid",
        "context.policy_mismatch",
        "context.required_slice_missing",
        "context.stage_unsupported",
        "context.tokenizer_unavailable",
        "context.extractive_compaction",
        "context.clarification_required",
    }),
    "context_policy": frozenset({"itinerary-compose-v2", "itinerary-six-stage-v2"}),
    "stage": frozenset({"intake", "plan", "evidence", "compose", "validate", "complete"}),
}


class MetricDefinition(BaseModel):
    model_config = ConfigDict(extra="forbid", frozen=True)

    name: str = Field(pattern=r"^gonow_[a-z0-9_]+$")
    domain: MetricDomain
    kind: MetricKind
    unit: str = Field(pattern=r"^(1|count|ms|token|usd)$")
    owner: str = Field(min_length=2, max_length=64)
    description: str = Field(min_length=8, max_length=240)
    label_keys: tuple[str, ...] = ()
    buckets: tuple[float, ...] = ()
    critical: bool = False

    @model_validator(mode="after")
    def validate_cardinality_contract(self) -> "MetricDefinition":
        if len(set(self.label_keys)) != len(self.label_keys):
            raise ValueError("duplicate label key")
        if set(self.label_keys) - set(LABEL_VALUE_DOMAINS) or set(self.label_keys) & FORBIDDEN_LABEL_KEYS:
            raise ValueError("unbounded label key")
        if self.kind == "histogram" and (not self.buckets or tuple(sorted(set(self.buckets))) != self.buckets):
            raise ValueError("histogram buckets must be non-empty, unique, and sorted")
        if self.kind != "histogram" and self.buckets:
            raise ValueError("only histograms define buckets")
        return self


REQUIRED_METRICS = (
    MetricDefinition(name="gonow_run_completed_total", domain="run", kind="counter", unit="count", owner="SRE", description="Completed runs by bounded outcome.", label_keys=("outcome",), critical=True),
    MetricDefinition(name="gonow_run_duration_ms", domain="run", kind="histogram", unit="ms", owner="SRE", description="End-to-end run duration.", label_keys=("outcome",), buckets=(100.0, 500.0, 2_000.0, 10_000.0, 60_000.0), critical=True),
    MetricDefinition(name="gonow_stage_transitions_total", domain="run", kind="counter", unit="count", owner="Agent Platform", description="Entered in-process itinerary stages by fixed stage identity.", label_keys=("stage",), critical=True),
    MetricDefinition(name="gonow_tool_calls_total", domain="tool", kind="counter", unit="count", owner="Agent Platform", description="Tool calls by bounded class and outcome.", label_keys=("tool_class", "outcome"), critical=True),
    MetricDefinition(name="gonow_tool_duration_ms", domain="tool", kind="histogram", unit="ms", owner="Agent Platform", description="Tool-call latency by bounded class.", label_keys=("tool_class",), buckets=(25.0, 100.0, 500.0, 2_000.0, 10_000.0)),
    MetricDefinition(name="gonow_context_tokens", domain="context", kind="gauge", unit="token", owner="Agent Platform", description="Current bounded context-token usage."),
    MetricDefinition(name="gonow_context_utilization", domain="context", kind="histogram", unit="1", owner="Agent Platform", description="Context-window utilization ratio.", buckets=(0.25, 0.5, 0.75, 0.9, 1.0)),
    MetricDefinition(name="gonow_context_decisions_total", domain="context", kind="counter", unit="count", owner="Agent Platform", description="Context planning decisions by bounded policy and reason.", label_keys=("context_outcome", "context_reason", "context_policy"), critical=True),
    MetricDefinition(name="gonow_validation_total", domain="validation", kind="counter", unit="count", owner="Quality", description="Validation results by fixed semantic class.", label_keys=("validation_result",), critical=True),
    MetricDefinition(name="gonow_validation_duration_ms", domain="validation", kind="histogram", unit="ms", owner="Quality", description="Canonical validation duration.", buckets=(10.0, 50.0, 200.0, 1_000.0, 5_000.0)),
    MetricDefinition(name="gonow_model_cost_usd_total", domain="cost", kind="counter", unit="usd", owner="Finance", description="Provider-reconciled model cost in USD.", critical=True),
    MetricDefinition(name="gonow_adopted_task_cost_usd", domain="cost", kind="histogram", unit="usd", owner="Finance", description="Cost per successfully adopted task.", buckets=(0.01, 0.05, 0.25, 1.0, 5.0), critical=True),
    MetricDefinition(name="gonow_recovery_attempts_total", domain="recovery", kind="counter", unit="count", owner="SRE", description="Recovery attempts by bounded reason and outcome.", label_keys=("recovery_reason", "outcome"), critical=True),
    MetricDefinition(name="gonow_recovery_duration_ms", domain="recovery", kind="histogram", unit="ms", owner="SRE", description="Recovery duration by bounded reason.", label_keys=("recovery_reason",), buckets=(100.0, 500.0, 2_000.0, 10_000.0, 60_000.0), critical=True),
)

METRIC_REGISTRY = {definition.name: definition for definition in REQUIRED_METRICS}


class MetricContractError(RuntimeError):
    code = "metrics.contract_invalid"

    def __init__(self) -> None:
        super().__init__(self.code)


class MetricPoint(BaseModel):
    model_config = ConfigDict(extra="forbid", frozen=True)

    name: str
    value: float
    labels: dict[str, str]


class OperationalMetrics:
    """Validate definitions and labels before retaining an in-process metric point."""

    def __init__(self, registry: Mapping[str, MetricDefinition] | None = None, *, enabled: bool = True) -> None:
        self._registry = dict(registry or METRIC_REGISTRY)
        if len(self._registry) != len(set(self._registry)) or any(name != item.name for name, item in self._registry.items()):
            raise MetricContractError()
        self._enabled = enabled
        self._points: dict[str, list[MetricPoint]] = defaultdict(list)

    def disable_noncritical(self) -> None:
        self._enabled = False

    def record(self, name: str, value: int | float, labels: Mapping[str, str] | None = None) -> bool:
        definition = self._registry.get(name)
        if definition is None or isinstance(value, bool) or not isinstance(value, (int, float)) or value < 0:
            raise MetricContractError()
        normalized = dict(labels or {})
        if set(normalized) != set(definition.label_keys):
            raise MetricContractError()
        for key, label_value in normalized.items():
            if label_value not in LABEL_VALUE_DOMAINS[key]:
                raise MetricContractError()
        if not self._enabled and not definition.critical:
            return False
        self._points[name].append(MetricPoint(name=name, value=float(value), labels=normalized))
        return True

    def snapshot(self) -> dict[str, tuple[MetricPoint, ...]]:
        return {name: tuple(points) for name, points in sorted(self._points.items())}
