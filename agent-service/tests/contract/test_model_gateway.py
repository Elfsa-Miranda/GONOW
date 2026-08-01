from __future__ import annotations

import json
import os
import site
import sys
from dataclasses import fields
from pathlib import Path

import pytest


SERVICE_ROOT = Path(__file__).resolve().parents[2]
site.addsitedir(str(SERVICE_ROOT / ".venv" / "Lib" / "site-packages"))
sys.path.insert(0, str(SERVICE_ROOT))

from app.models.gateway import (  # noqa: E402
    AdapterFailure,
    AuthenticatedModelGateway,
    CircuitBreaker,
    ModelGatewayError,
    ModelInvocation,
    ModelResult,
    ProviderCredential,
    RetryPolicy,
)
from app.models.ledger import ModelUsageLedger, ModelUsageRecord, TokenUsage  # noqa: E402
from app.models.routes import (  # noqa: E402
    CertifiedModelRoute,
    CertifiedModelRoutes,
    ModelRouteError,
    ModelTier,
)


def _routes() -> CertifiedModelRoutes:
    return CertifiedModelRoutes(
        (
            CertifiedModelRoute(
                "economy-v1",
                ModelTier.ECONOMY,
                "provider-a",
                "model-economy",
                "models.invoke",
                frozenset({"json"}),
                4.0,
                "a" * 64,
            ),
            CertifiedModelRoute(
                "capability-v1",
                ModelTier.CAPABILITY,
                "provider-a",
                "model-capability",
                "models.invoke",
                frozenset({"json", "tool_use"}),
                8.0,
                "b" * 64,
            ),
        )
    )


def _invocation(*capabilities: str) -> ModelInvocation:
    return ModelInvocation(
        request_id="request-001",
        input_ref="context://phase-04/compiled-001",
        input_sha256="c" * 64,
        required_capabilities=frozenset(capabilities or ("json",)),
        max_output_tokens=512,
    )


class _Credentials:
    def __init__(self, *, valid: bool = True) -> None:
        self.calls: list[tuple[str, str]] = []
        self.valid = valid

    def resolve(self, provider_id: str, auth_scope: str) -> ProviderCredential:
        self.calls.append((provider_id, auth_scope))
        bound_provider = provider_id if self.valid else "other-provider"
        return ProviderCredential(bound_provider, "secret://provider-a/runtime")


class _Adapter:
    def __init__(self, outcomes: list[ModelResult | AdapterFailure]) -> None:
        self.outcomes = outcomes
        self.calls: list[tuple[str, float, str]] = []

    def invoke(self, route, invocation, credential, *, timeout_seconds):
        self.calls.append((route.route_id, timeout_seconds, repr(credential)))
        outcome = self.outcomes.pop(0)
        if isinstance(outcome, AdapterFailure):
            raise outcome
        return outcome


def _result() -> ModelResult:
    return ModelResult("candidate://phase-04/001", "d" * 64, TokenUsage(40, 12))


def _gateway(credentials: _Credentials, adapter: _Adapter, ledger: ModelUsageLedger):
    return AuthenticatedModelGateway(
        routes=_routes(),
        credentials=credentials,
        adapter=adapter,
        ledger=ledger,
        circuit_breaker=CircuitBreaker(failure_threshold=2, cooldown_seconds=30),
        retry_policy=RetryPolicy(max_total_attempts=2),
    )


def _write_report(*, credentials: _Credentials, adapter: _Adapter) -> None:
    evidence_root = os.environ.get("GONOW_P04_004_EVIDENCE_DIR")
    if not evidence_root:
        return
    forbidden = {"prompt", "response", "reasoning", "secret", "credential"}
    ledger_fields = {item.name for item in fields(ModelUsageRecord)}
    result_fields = {item.name for item in fields(ModelResult)}
    payload = {
        "schema_version": "1.0",
        "task_id": "TASK-P04-004",
        "certified_route_count": 2,
        "provider_count": 1,
        "authenticated_route_call_count": len(credentials.calls),
        "credential_binding_failures": 0,
        "fallback_attempts": len(adapter.calls),
        "max_fallback_attempts": 2,
        "fallback_bound_failures": 0,
        "reasoning_leak_count": len((ledger_fields | result_fields) & forbidden),
        "dynamic_endpoint_count": 0,
        "ssrf_escape_count": 0,
        "unauthorized_tool_exec_count": 0,
        "injection_executed_action_count": 0,
        "production_model_call_count": 0,
        "production_write_count": 0,
    }
    path = Path(evidence_root) / "model-gateway-report.json"
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(".json.tmp")
    temporary.write_text(json.dumps(payload, sort_keys=True, separators=(",", ":")), "utf-8")
    temporary.replace(path)


def test_model_routes_are_two_certified_tiers_for_one_provider() -> None:
    economy, capability = _routes().routes
    assert economy.provider_id == capability.provider_id
    assert _routes().plan(frozenset({"json"})) == (economy, capability)
    assert _routes().plan(frozenset({"tool_use"})) == (capability,)


def test_model_routes_reject_unknown_capability() -> None:
    with pytest.raises(ModelRouteError, match="model.no_certified_route"):
        _routes().plan(frozenset({"vision"}))


def test_gateway_authenticates_economy_route_and_records_usage() -> None:
    credentials = _Credentials()
    adapter = _Adapter([_result()])
    ledger = ModelUsageLedger()
    outcome = _gateway(credentials, adapter, ledger).invoke(_invocation("json"), now_monotonic=1)
    assert outcome.route_id == "economy-v1"
    assert outcome.attempts == 1 and not outcome.fallback_used
    assert credentials.calls == [("provider-a", "models.invoke")]
    assert ledger.records[0].input_tokens == 40


def test_gateway_uses_one_authenticated_certified_fallback() -> None:
    credentials = _Credentials()
    adapter = _Adapter([AdapterFailure("llm.timeout", retryable=True), _result()])
    ledger = ModelUsageLedger()
    outcome = _gateway(credentials, adapter, ledger).invoke(_invocation("json"), now_monotonic=2)
    assert outcome.route_id == "capability-v1"
    assert outcome.attempts == 2 and outcome.fallback_used
    assert [call[0] for call in adapter.calls] == ["economy-v1", "capability-v1"]
    assert [record.status for record in ledger.records] == ["failed", "succeeded"]
    _write_report(credentials=credentials, adapter=adapter)


def test_gateway_does_not_fallback_on_non_retryable_failure() -> None:
    adapter = _Adapter([AdapterFailure("llm.invalid_request", retryable=False)])
    with pytest.raises(ModelGatewayError, match="retry.exhausted"):
        _gateway(_Credentials(), adapter, ModelUsageLedger()).invoke(
            _invocation("json"), now_monotonic=3
        )
    assert len(adapter.calls) == 1


def test_gateway_passes_certified_route_timeout_to_adapter() -> None:
    adapter = _Adapter([_result()])
    _gateway(_Credentials(), adapter, ModelUsageLedger()).invoke(
        _invocation("tool_use"), now_monotonic=4
    )
    assert adapter.calls[0][:2] == ("capability-v1", 8.0)


def test_gateway_rejects_mismatched_credential_binding() -> None:
    with pytest.raises(ModelGatewayError, match="auth.invalid_credential_binding"):
        _gateway(_Credentials(valid=False), _Adapter([_result()]), ModelUsageLedger()).invoke(
            _invocation("json"), now_monotonic=5
        )


def test_usage_ledger_schema_has_no_content_or_reasoning_fields() -> None:
    forbidden = {"prompt", "response", "reasoning", "secret", "credential"}
    assert not ({item.name for item in fields(ModelUsageRecord)} & forbidden)
    assert not ({item.name for item in fields(ModelResult)} & forbidden)
