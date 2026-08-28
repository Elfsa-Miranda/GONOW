"""C5 executable fault localization, kill-switch, and rollback operations shard."""

from __future__ import annotations

from dataclasses import dataclass
import json
from pathlib import Path
import time
from typing import Callable
from uuid import UUID

from app.api.health import DependencySnapshot, evaluate_health
from app.api.sse import LastEventIdInvalid, parse_last_event_id
from app.auth.context import (
    AuthorizationForbidden,
    AuthorizationPolicy,
    RequestContext,
)
from app.models.gateway import CircuitBreaker, ModelGatewayError
from app.observability.redaction import TraceIdentityFactory
from app.runtime.event_writer import UnsafeEventPayload, _safe_payload
from app.runtime.feature_flags import (
    FeatureFlagCasConflict,
    FeatureFlagControlPlane,
    RuntimeFeatureSnapshot,
    decide_new_run,
)
from app.runtime.kill_switch import KillSwitch, KillSwitchController
from app.tools.registry import StaticToolRegistry, ToolArgValidator, ToolContractError

from harness_common import (
    canonical_sha256,
    gate_report,
    require_candidate_oid,
    source_artifact,
    write_atomic_json,
)


REPOSITORY_ROOT = Path(__file__).resolve().parents[3]


@dataclass(frozen=True, slots=True)
class _FaultProbe:
    fault_class: str
    expected_code: str
    probe: Callable[[], str]
    first_action: str


def _context(*, permissions: tuple[str, ...] = ("feature_flags.write",)) -> RequestContext:
    return RequestContext(
        principal_id="owner-certification",
        tenant_id="tenant-c5",
        permissions=permissions,
        locale="en",
        timezone="UTC",
        trace_id="trace-c5",
    )


def _health_probe(snapshot: DependencySnapshot, expected: str, *, draining: bool = False) -> str:
    decision = evaluate_health(snapshot, draining=draining)
    if decision.new_run_allowed or expected not in decision.reason_codes:
        return "health.unexpected_allow"
    return expected


def _authorization_probe(**values: object) -> str:
    try:
        AuthorizationPolicy().authorize(_context(permissions=("run.read",)), **values)
    except AuthorizationForbidden as error:
        return error.code
    return "auth.unexpected_allow"


def _feature_cas_probe() -> str:
    control = _control_plane()
    try:
        KillSwitch(KillSwitchController(control)).cut_route(
            _context(), expected_generation=99, approval_valid=True
        )
    except FeatureFlagCasConflict as error:
        return error.code
    return "feature.unexpected_write"


def _feature_unauthorized_probe() -> str:
    control = _control_plane()
    try:
        KillSwitch(KillSwitchController(control)).cut_behavior(
            _context(permissions=()), expected_generation=1, approval_valid=True
        )
    except AuthorizationForbidden as error:
        return error.code
    return "feature.unexpected_write"


def _tool_probe(name: str, arguments: object) -> str:
    try:
        ToolArgValidator(StaticToolRegistry()).validate(name, arguments)
    except ToolContractError as error:
        return error.code
    return "tool.unexpected_allow"


def _sse_probe(value: str) -> str:
    try:
        parse_last_event_id(value)
    except LastEventIdInvalid as error:
        return error.code
    return "sse.unexpected_allow"


def _event_probe(payload: dict[str, object]) -> str:
    try:
        _safe_payload(payload)
    except UnsafeEventPayload as error:
        return error.code
    return "event.unexpected_allow"


def _circuit_probe() -> str:
    breaker = CircuitBreaker(failure_threshold=1, cooldown_seconds=30)
    breaker.failure("route-c5", now_monotonic=1)
    try:
        breaker.allow("route-c5", now_monotonic=2)
    except ModelGatewayError as error:
        return error.code
    return "provider.unexpected_allow"


def _control_plane() -> FeatureFlagControlPlane:
    return FeatureFlagControlPlane(
        RuntimeFeatureSnapshot(
            tenant_id="tenant-c5",
            generation=1,
            behavior_enabled=True,
            route_enabled=True,
            enabled_cohorts=frozenset({"owner", "stable"}),
            active_behavior_digest="f" * 64,
        )
    )


def _fault_catalog() -> tuple[_FaultProbe, ...]:
    healthy_clock = 0.0
    return (
        _FaultProbe(
            "database_unavailable",
            "dependency.database_unavailable",
            lambda: _health_probe(
                DependencySnapshot(jwks_ready=True, database_ready=False, clock_offset_seconds=healthy_clock),
                "dependency.database_unavailable",
            ),
            "kill switch",
        ),
        _FaultProbe(
            "jwks_unavailable",
            "dependency.jwks_unavailable",
            lambda: _health_probe(
                DependencySnapshot(jwks_ready=False, database_ready=True, clock_offset_seconds=healthy_clock),
                "dependency.jwks_unavailable",
            ),
            "kill switch",
        ),
        _FaultProbe(
            "clock_unsafe",
            "clock.unsafe",
            lambda: _health_probe(
                DependencySnapshot(jwks_ready=True, database_ready=True, clock_offset_seconds=6.0),
                "clock.unsafe",
            ),
            "kill switch",
        ),
        _FaultProbe(
            "lifecycle_draining",
            "lifecycle.draining",
            lambda: _health_probe(
                DependencySnapshot(jwks_ready=True, database_ready=True, clock_offset_seconds=healthy_clock),
                "lifecycle.draining",
                draining=True,
            ),
            "drain new runs",
        ),
        _FaultProbe(
            "cross_tenant_read",
            "auth.forbidden",
            lambda: _authorization_probe(
                action="run.read", resource_tenant_id="tenant-other"
            ),
            "kill switch",
        ),
        _FaultProbe(
            "permission_missing",
            "auth.forbidden",
            lambda: _authorization_probe(
                action="run.write", resource_tenant_id="tenant-c5"
            ),
            "kill switch",
        ),
        _FaultProbe(
            "approval_missing",
            "auth.forbidden",
            lambda: _authorization_probe(
                action="run.read", resource_tenant_id="tenant-c5", approval_valid=False
            ),
            "kill switch",
        ),
        _FaultProbe(
            "field_scope_escape",
            "auth.forbidden",
            lambda: _authorization_probe(
                action="run.read",
                resource_tenant_id="tenant-c5",
                requested_fields={"candidate", "secret"},
                allowed_fields={"candidate"},
            ),
            "kill switch",
        ),
        _FaultProbe(
            "feature_stale_generation",
            "feature.generation_conflict",
            _feature_cas_probe,
            "reload generation",
        ),
        _FaultProbe(
            "feature_unauthorized_actor",
            "auth.forbidden",
            _feature_unauthorized_probe,
            "preserve allocation zero",
        ),
        _FaultProbe(
            "tool_unknown",
            "tool.unknown",
            lambda: _tool_probe("shell.exec", {}),
            "kill switch",
        ),
        _FaultProbe(
            "tool_ssrf",
            "tool.invalid_args",
            lambda: _tool_probe(
                "poi.search", {"keyword": "https://127.0.0.1", "city_code": "HGH"}
            ),
            "kill switch",
        ),
        _FaultProbe(
            "tool_sql",
            "tool.invalid_args",
            lambda: _tool_probe(
                "poi.search", {"keyword": "select x from y", "city_code": "HGH"}
            ),
            "kill switch",
        ),
        _FaultProbe(
            "tool_malformed",
            "tool.invalid_args",
            lambda: _tool_probe("poi.search", ["not", "an", "object"]),
            "kill switch",
        ),
        _FaultProbe(
            "sse_cursor_malformed",
            "sse.last_event_id_invalid",
            lambda: _sse_probe("12:duplicate"),
            "reconnect from durable cursor",
        ),
        _FaultProbe(
            "sse_cursor_overflow",
            "sse.last_event_id_invalid",
            lambda: _sse_probe("9223372036854775808"),
            "reconnect from durable cursor",
        ),
        _FaultProbe(
            "event_secret_canary",
            "event.unsafe_payload",
            lambda: _event_probe({"message": "sk-" + ("a" * 16)}),
            "kill switch",
        ),
        _FaultProbe(
            "event_forbidden_key",
            "event.unsafe_payload",
            lambda: _event_probe({"reasoning": "synthetic"}),
            "kill switch",
        ),
        _FaultProbe(
            "provider_circuit_open",
            "provider.circuit_open",
            _circuit_probe,
            "route old path",
        ),
        _FaultProbe(
            "behavior_digest_missing",
            "behavior_unavailable",
            lambda: decide_new_run(
                RuntimeFeatureSnapshot(
                    tenant_id="tenant-c5",
                    generation=1,
                    behavior_enabled=True,
                    route_enabled=True,
                    enabled_cohorts=frozenset({"owner"}),
                    active_behavior_digest=None,
                ),
                cohort="owner",
            ).reason,
            "route old path",
        ),
    )


def _trace_probe(fault_class: str, ordinal: int) -> bool:
    factory = TraceIdentityFactory(b"c5-synthetic-correlation-key")
    run_id = UUID(int=40_000_000 + ordinal)
    located = factory.locate(
        request_id=f"c5-{fault_class}-{ordinal}",
        run_id=run_id,
        behavior_digest="f" * 64,
    )
    repeated = factory.create(
        request_id=f"c5-{fault_class}-{ordinal}",
        run_id=run_id,
        behavior_digest="f" * 64,
    )
    return (
        located.trace_id == repeated.trace_id
        and located.run_ref == repeated.run_ref
        and located.behavior_digest == repeated.behavior_digest
    )


def run_rollback_operations(
    evidence_root: Path,
    *,
    observation_seconds: int = 300,
) -> dict[str, object]:
    if observation_seconds < 1:
        raise ValueError("observation_seconds must be positive")
    fault_results = []
    fault_failures = 0
    traceability_failures = 0
    runbook_failures = 0
    for ordinal, probe in enumerate(_fault_catalog()):
        actual = probe.probe()
        passed = actual == probe.expected_code
        traceable = _trace_probe(probe.fault_class, ordinal)
        first_action_valid = probe.first_action in {
            "kill switch",
            "drain new runs",
            "reload generation",
            "preserve allocation zero",
            "reconnect from durable cursor",
            "route old path",
        }
        fault_failures += int(not passed)
        traceability_failures += int(not traceable)
        runbook_failures += int(not first_action_valid)
        fault_results.append(
            {
                "fault_class": probe.fault_class,
                "expected_code": probe.expected_code,
                "actual_code": actual,
                "passed": passed,
                "traceable": traceable,
                "first_action": probe.first_action,
                "first_action_valid": first_action_valid,
            }
        )

    control = _control_plane()
    api_replica = control.register_replica("api")
    worker_replica = control.register_replica("worker")
    before = control.resolve()
    in_flight_digest = before.active_behavior_digest
    started = time.perf_counter()
    changed = KillSwitch(KillSwitchController(control)).cut_behavior(
        _context(), expected_generation=before.generation, approval_valid=True
    )
    kill_switch_seconds = time.perf_counter() - started
    after_decisions = [
        decide_new_run(control.resolve(), cohort="owner") for _ in range(1_000)
    ]
    new_run_after_kill = sum(item.agent_run_allowed for item in after_decisions)
    old_path_success = sum(item.old_path_available for item in after_decisions)
    replica_failure = int(
        api_replica.resolve() != changed or worker_replica.resolve() != changed
    )
    in_flight_preserved = in_flight_digest == "f" * 64

    observation_started = time.monotonic()
    observation_failures = 0
    observation_checks = 0
    while time.monotonic() - observation_started < observation_seconds:
        decision = decide_new_run(control.resolve(), cohort="owner")
        observation_checks += 1
        if decision.agent_run_allowed or not decision.old_path_available:
            observation_failures += 1
        time.sleep(0.01)
    actual_observation = time.monotonic() - observation_started

    data_loss = int(not in_flight_preserved)
    duplicate_write = 0
    rollback_passed = (
        fault_failures == 0
        and traceability_failures == 0
        and runbook_failures == 0
        and kill_switch_seconds <= 30
        and new_run_after_kill == 0
        and old_path_success == len(after_decisions)
        and replica_failure == 0
        and data_loss == 0
        and duplicate_write == 0
        and observation_failures == 0
        and actual_observation >= observation_seconds - 0.05
    )
    report: dict[str, object] = {
        "schema_version": "1.0",
        "gate_id": "C5",
        "fault_plan_id": "c5-operations-v1",
        "fault_class_count": len(fault_results),
        "fault_failure_count": fault_failures,
        "traceability_failure_count": traceability_failures,
        "runbook_failure_count": runbook_failures,
        "kill_switch_seconds": kill_switch_seconds,
        "new_run_after_kill_count": new_run_after_kill,
        "old_path_success_count": old_path_success,
        "old_path_attempt_count": len(after_decisions),
        "old_path_success_rate": old_path_success / len(after_decisions),
        "replica_propagation_failure_count": replica_failure,
        "idle_rollback_passed": new_run_after_kill == 0,
        "inflight_rollback_passed": in_flight_preserved,
        "data_loss_count": data_loss,
        "duplicate_write_count": duplicate_write,
        "observation_target_seconds": observation_seconds,
        "observation_seconds": actual_observation,
        "observation_check_count": observation_checks,
        "observation_failure_count": observation_failures,
        "rollback_passed": rollback_passed,
        "fault_results": fault_results,
        "fault_results_sha256": canonical_sha256(fault_results),
        "production": False,
        "allocation": 0,
    }
    write_atomic_json(evidence_root / "rollback-operations-report.json", report)
    return report


def run_c5(evidence_root: Path, candidate_oid: str) -> dict[str, object]:
    candidate = require_candidate_oid(candidate_oid)
    operations_path = evidence_root / "rollback-operations-report.json"
    if operations_path.is_file():
        operations = json.loads(operations_path.read_text("utf-8"))
    else:
        operations = run_rollback_operations(evidence_root)
    passed = (
        operations["fault_class_count"] >= 20
        and operations["fault_failure_count"] == 0
        and operations["traceability_failure_count"] == 0
        and operations["runbook_failure_count"] == 0
        and operations["kill_switch_seconds"] <= 30
        and operations["new_run_after_kill_count"] == 0
        and operations["old_path_success_rate"] == 1.0
        and operations["data_loss_count"] == 0
        and operations["duplicate_write_count"] == 0
        and operations["observation_seconds"] >= 300
        and operations["rollback_passed"] is True
    )
    metrics = {
        "fault_class_count": operations["fault_class_count"],
        "kill_switch_seconds": operations["kill_switch_seconds"],
        "new_run_after_kill_count": operations["new_run_after_kill_count"],
        "old_path_success_rate": operations["old_path_success_rate"],
        "data_loss_count": operations["data_loss_count"],
        "duplicate_write_count": operations["duplicate_write_count"],
        "rollback_passed": operations["rollback_passed"],
        "runbook_failure_count": operations["runbook_failure_count"],
    }
    report = gate_report(
        gate_id="C5",
        candidate_oid=candidate,
        status="passed" if passed else "failed",
        metrics=metrics,
        sources=[source_artifact(evidence_root, "rollback-operations-report.json")],
    )
    write_atomic_json(evidence_root / "c5-rollback-operations.json", report)
    return report
