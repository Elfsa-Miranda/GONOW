"""Authenticated model adapter boundary with bounded certified fallback."""

from __future__ import annotations

import re
from dataclasses import dataclass, field
from typing import Any, Protocol

from app.models.ledger import ModelUsageLedger, TokenUsage
from app.models.routes import CertifiedModelRoute, ModelRoutePlan


SHA256 = re.compile(r"^[0-9a-f]{64}$")


class ModelGatewayError(RuntimeError):
    def __init__(self, code: str, *, retryable: bool = False) -> None:
        self.code = code
        self.retryable = retryable
        super().__init__(code)


class AdapterFailure(ModelGatewayError):
    pass


@dataclass(frozen=True, slots=True, repr=False)
class ProviderCredential:
    provider_id: str
    credential_ref: str
    secret_value: str | None = field(default=None, repr=False, compare=False)

    def __repr__(self) -> str:
        return "ProviderCredential(provider_id=<bound>, credential=<redacted>)"


@dataclass(frozen=True, slots=True)
class ModelInvocation:
    request_id: str
    input_ref: str
    input_sha256: str
    required_capabilities: frozenset[str]
    max_output_tokens: int

    def __post_init__(self) -> None:
        if (
            not self.request_id
            or not self.input_ref.startswith("context://")
            or SHA256.fullmatch(self.input_sha256) is None
            or not self.required_capabilities
            or self.max_output_tokens < 1
        ):
            raise ModelGatewayError("llm.request_invalid")


@dataclass(frozen=True, slots=True)
class ModelResult:
    output_ref: str
    output_sha256: str
    usage: TokenUsage
    payload: dict[str, Any] | None = field(default=None, repr=False, compare=False)
    input_cache_hit_tokens: int = 0
    input_cache_miss_tokens: int | None = None

    def __post_init__(self) -> None:
        if (
            not self.output_ref.startswith("candidate://")
            or SHA256.fullmatch(self.output_sha256) is None
            or self.input_cache_hit_tokens < 0
            or (
                self.input_cache_miss_tokens is not None
                and self.input_cache_miss_tokens < 0
            )
            or self.input_cache_hit_tokens > self.usage.input_tokens
            or (
                self.input_cache_miss_tokens is not None
                and self.input_cache_hit_tokens + self.input_cache_miss_tokens
                != self.usage.input_tokens
            )
        ):
            raise ModelGatewayError("llm.response_invalid")


@dataclass(frozen=True, slots=True)
class GatewayOutcome:
    route_id: str
    attempts: int
    fallback_used: bool
    result: ModelResult


class CredentialProvider(Protocol):
    def resolve(self, provider_id: str, auth_scope: str) -> ProviderCredential: ...


class ModelAdapter(Protocol):
    def invoke(
        self,
        route: CertifiedModelRoute,
        invocation: ModelInvocation,
        credential: ProviderCredential,
        *,
        timeout_seconds: float,
    ) -> ModelResult: ...


@dataclass(slots=True)
class _CircuitState:
    failures: int = 0
    opened_at: float | None = None


class CircuitBreaker:
    def __init__(self, *, failure_threshold: int, cooldown_seconds: float) -> None:
        if failure_threshold < 1 or cooldown_seconds <= 0:
            raise ModelGatewayError("provider.circuit_policy_invalid")
        self._failure_threshold = failure_threshold
        self._cooldown_seconds = cooldown_seconds
        self._states: dict[str, _CircuitState] = {}

    def allow(self, route_id: str, *, now_monotonic: float) -> None:
        state = self._states.setdefault(route_id, _CircuitState())
        if state.opened_at is None:
            return
        if now_monotonic - state.opened_at < self._cooldown_seconds:
            raise ModelGatewayError("provider.circuit_open")

    def success(self, route_id: str) -> None:
        self._states[route_id] = _CircuitState()

    def failure(self, route_id: str, *, now_monotonic: float) -> None:
        state = self._states.setdefault(route_id, _CircuitState())
        state.failures += 1
        if state.failures >= self._failure_threshold:
            state.opened_at = now_monotonic


class RetryPolicy:
    """Permit at most one retry, and only by moving to a certified fallback route."""

    def __init__(self, *, max_total_attempts: int) -> None:
        if max_total_attempts not in {1, 2}:
            raise ModelGatewayError("retry.policy_invalid")
        self.max_total_attempts = max_total_attempts

    def allows_fallback(self, failure: AdapterFailure, *, attempts: int) -> bool:
        return failure.retryable and attempts < self.max_total_attempts


class AuthenticatedModelGateway:
    def __init__(
        self,
        *,
        routes: ModelRoutePlan,
        credentials: CredentialProvider,
        adapter: ModelAdapter,
        ledger: ModelUsageLedger,
        circuit_breaker: CircuitBreaker,
        retry_policy: RetryPolicy,
    ) -> None:
        self._routes = routes
        self._credentials = credentials
        self._adapter = adapter
        self._ledger = ledger
        self._circuit_breaker = circuit_breaker
        self._retry_policy = retry_policy

    def invoke(self, invocation: ModelInvocation, *, now_monotonic: float) -> GatewayOutcome:
        route_plan = self._routes.plan(invocation.required_capabilities)
        attempts = 0
        circuit_rejections = 0
        for route in route_plan:
            if attempts >= self._retry_policy.max_total_attempts:
                break
            try:
                self._circuit_breaker.allow(route.route_id, now_monotonic=now_monotonic)
            except ModelGatewayError:
                circuit_rejections += 1
                continue
            attempts += 1
            credential = self._credentials.resolve(route.provider_id, route.auth_scope)
            if (
                credential.provider_id != route.provider_id
                or not credential.credential_ref.startswith("secret://")
            ):
                raise ModelGatewayError("auth.invalid_credential_binding")
            try:
                result = self._adapter.invoke(
                    route,
                    invocation,
                    credential,
                    timeout_seconds=route.timeout_seconds,
                )
            except AdapterFailure as failure:
                self._ledger.record_failure(
                    request_id=invocation.request_id,
                    route_id=route.route_id,
                    attempt=attempts,
                    failure_code=failure.code,
                )
                self._circuit_breaker.failure(
                    route.route_id, now_monotonic=now_monotonic
                )
                if self._retry_policy.allows_fallback(failure, attempts=attempts):
                    continue
                raise ModelGatewayError("retry.exhausted") from failure
            self._circuit_breaker.success(route.route_id)
            self._ledger.record_success(
                request_id=invocation.request_id,
                route_id=route.route_id,
                attempt=attempts,
                usage=result.usage,
            )
            return GatewayOutcome(
                route_id=route.route_id,
                attempts=attempts,
                fallback_used=attempts > 1,
                result=result,
            )
        if attempts == 0 and circuit_rejections:
            raise ModelGatewayError("provider.circuit_open")
        raise ModelGatewayError("retry.exhausted")
