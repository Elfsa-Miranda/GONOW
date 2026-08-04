"""Fixed DeepSeek V4 Flash adapter for the local cost-router candidate."""

from __future__ import annotations

from collections.abc import Callable
import json
import os
from typing import Any

import httpx

from app.models.gateway import (
    AdapterFailure,
    CredentialProvider,
    ModelAdapter,
    ModelInvocation,
    ModelResult,
    ProviderCredential,
)
from app.models.gemini import (
    GeminiModelAdapter,
    PROVIDER_ID as GEMINI_PROVIDER_ID,
    canonical_digest,
)
from app.models.ledger import TokenUsage
from app.models.routes import CertifiedModelRoute, ModelTier


PROVIDER_ID = "deepseek-api"
API_ORIGIN = "https://api.deepseek.com"
API_PATH = "/chat/completions"
MODEL_ID = "deepseek-v4-flash"
AUTH_SCOPE = "model.generate.itinerary"
ROUTE_ID = "deepseek-v4-flash-candidate-v1"


def certified_deepseek_route() -> CertifiedModelRoute:
    return CertifiedModelRoute(
        route_id=ROUTE_ID,
        tier=ModelTier.CAPABILITY,
        provider_id=PROVIDER_ID,
        model_id=MODEL_ID,
        auth_scope=AUTH_SCOPE,
        capabilities=frozenset({"json", "complex"}),
        timeout_seconds=45.0,
        certification_digest=canonical_digest(
            {
                "route": ROUTE_ID,
                "model": MODEL_ID,
                "origin": API_ORIGIN,
                "thinking": "disabled",
                "response_format": "json_object",
                "version": "1",
            }
        ),
    )


class EnvironmentDeepSeekCredentialProvider:
    """Resolve the candidate secret only when its fixed route is invoked."""

    def __init__(self, environment_variable: str = "DEEPSEEK_API_KEY") -> None:
        if environment_variable != "DEEPSEEK_API_KEY":
            raise ValueError("auth.invalid_credential_binding")
        self._environment_variable = environment_variable

    def resolve(self, provider_id: str, auth_scope: str) -> ProviderCredential:
        if provider_id != PROVIDER_ID or auth_scope != AUTH_SCOPE:
            raise AdapterFailure("auth.invalid_credential_binding", retryable=False)
        value = os.environ.get(self._environment_variable, "")
        if not value:
            raise AdapterFailure("auth.secret_unavailable", retryable=False)
        return ProviderCredential(
            provider_id=provider_id,
            credential_ref="secret://environment/DEEPSEEK_API_KEY",
            secret_value=value,
        )


class DeepSeekModelAdapter:
    """Invoke one allowlisted model at one literal HTTPS endpoint."""

    def __init__(
        self,
        *,
        input_resolver: Callable[[str], str],
        client: httpx.Client | None = None,
    ) -> None:
        self._input_resolver = input_resolver
        self._client = client

    @staticmethod
    def _response_error(status_code: int) -> AdapterFailure:
        if status_code == 429:
            return AdapterFailure("llm.rate_limited", retryable=True)
        if status_code in {500, 502, 503, 504}:
            return AdapterFailure("llm.provider_unavailable", retryable=True)
        return AdapterFailure("llm.provider_rejected", retryable=False)

    def invoke(
        self,
        route: CertifiedModelRoute,
        invocation: ModelInvocation,
        credential: ProviderCredential,
        *,
        timeout_seconds: float,
    ) -> ModelResult:
        if (
            route.route_id != ROUTE_ID
            or route.provider_id != PROVIDER_ID
            or route.model_id != MODEL_ID
            or route.auth_scope != AUTH_SCOPE
            or credential.provider_id != PROVIDER_ID
            or credential.credential_ref
            != "secret://environment/DEEPSEEK_API_KEY"
            or not credential.secret_value
        ):
            raise AdapterFailure("auth.invalid_credential_binding", retryable=False)
        try:
            prompt = self._input_resolver(invocation.input_ref)
        except Exception as error:
            raise AdapterFailure("context.required_slice_missing", retryable=False) from error
        if (
            not isinstance(prompt, str)
            or not prompt
            or canonical_digest(prompt) != invocation.input_sha256
        ):
            raise AdapterFailure("context.required_slice_missing", retryable=False)

        payload = {
            "model": MODEL_ID,
            "messages": [{"role": "user", "content": prompt}],
            "thinking": {"type": "disabled"},
            "response_format": {"type": "json_object"},
            "temperature": 0,
            "max_tokens": invocation.max_output_tokens,
        }
        owns_client = self._client is None
        client = self._client or httpx.Client(
            follow_redirects=False,
            timeout=httpx.Timeout(timeout_seconds),
        )
        try:
            response = client.post(
                API_ORIGIN + API_PATH,
                headers={
                    "authorization": f"Bearer {credential.secret_value}",
                    "content-type": "application/json",
                },
                json=payload,
                timeout=timeout_seconds,
            )
            if response.status_code >= 400:
                raise self._response_error(response.status_code)
            body = response.json()
            choice = body["choices"][0]
            if choice.get("finish_reason") != "stop":
                raise AdapterFailure("llm.incomplete_output", retryable=False)
            parsed = json.loads(choice["message"]["content"])
            if not isinstance(parsed, dict):
                raise AdapterFailure("llm.schema_invalid", retryable=False)
            usage = body["usage"]
            input_tokens = int(usage["prompt_tokens"])
            output_tokens = int(usage["completion_tokens"])
            cache_hit = int(usage.get("prompt_cache_hit_tokens", 0))
            cache_miss = int(
                usage.get("prompt_cache_miss_tokens", input_tokens - cache_hit)
            )
            if (
                input_tokens < 1
                or output_tokens < 1
                or cache_hit < 0
                or cache_miss < 0
                or cache_hit + cache_miss != input_tokens
            ):
                raise AdapterFailure("llm.usage_invalid", retryable=False)
            output_sha256 = canonical_digest(parsed)
            return ModelResult(
                output_ref=f"candidate://sha256/{output_sha256}",
                output_sha256=output_sha256,
                usage=TokenUsage(
                    input_tokens=input_tokens, output_tokens=output_tokens
                ),
                payload=parsed,
                input_cache_hit_tokens=cache_hit,
                input_cache_miss_tokens=cache_miss,
            )
        except AdapterFailure:
            raise
        except httpx.TimeoutException as error:
            raise AdapterFailure("llm.timeout", retryable=True) from error
        except httpx.HTTPError as error:
            raise AdapterFailure("llm.provider_unavailable", retryable=True) from error
        except (IndexError, KeyError, TypeError, ValueError) as error:
            raise AdapterFailure("llm.schema_invalid", retryable=False) from error
        finally:
            if owns_client:
                client.close()


class FixedCostRouterCredentialProvider:
    """Dispatch credentials for exactly Gemini and DeepSeek provider IDs."""

    def __init__(
        self,
        *,
        gemini: CredentialProvider,
        deepseek: CredentialProvider,
    ) -> None:
        self._gemini = gemini
        self._deepseek = deepseek

    def resolve(self, provider_id: str, auth_scope: str) -> ProviderCredential:
        if provider_id == GEMINI_PROVIDER_ID:
            return self._gemini.resolve(provider_id, auth_scope)
        if provider_id == PROVIDER_ID:
            return self._deepseek.resolve(provider_id, auth_scope)
        raise AdapterFailure("auth.invalid_credential_binding", retryable=False)


class FixedCostRouterModelAdapter:
    """Dispatch invocations across exactly two fixed provider adapters."""

    def __init__(
        self,
        *,
        gemini: GeminiModelAdapter,
        deepseek: ModelAdapter,
    ) -> None:
        self._gemini = gemini
        self._deepseek = deepseek

    def invoke(
        self,
        route: CertifiedModelRoute,
        invocation: ModelInvocation,
        credential: ProviderCredential,
        *,
        timeout_seconds: float,
    ) -> ModelResult:
        if route.provider_id == GEMINI_PROVIDER_ID:
            return self._gemini.invoke(
                route, invocation, credential, timeout_seconds=timeout_seconds
            )
        if route.provider_id == PROVIDER_ID:
            return self._deepseek.invoke(
                route, invocation, credential, timeout_seconds=timeout_seconds
            )
        raise AdapterFailure("llm.provider_not_allowlisted", retryable=False)
