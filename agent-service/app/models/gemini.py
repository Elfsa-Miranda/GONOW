"""Fixed Gemini REST adapter for the certified two-route model boundary."""

from __future__ import annotations

from collections.abc import Callable
import hashlib
import json
import os
from typing import Any

import httpx

from app.models.gateway import (
    AdapterFailure,
    ModelInvocation,
    ModelResult,
    ProviderCredential,
)
from app.models.ledger import TokenUsage
from app.models.json_schema import canonical_schema, validation_rule_codes
from app.models.routes import CertifiedModelRoute, CertifiedModelRoutes, ModelTier


PROVIDER_ID = "google-gemini-developer-api"
API_ORIGIN = "https://generativelanguage.googleapis.com"
API_VERSION = "v1beta"
ECONOMIC_MODEL_ID = "gemini-3.1-flash-lite"
CAPABILITY_MODEL_ID = "gemini-3.6-flash"
ALLOWED_MODELS = frozenset({ECONOMIC_MODEL_ID, CAPABILITY_MODEL_ID})


def _canonical_bytes(value: Any) -> bytes:
    return json.dumps(
        value,
        allow_nan=False,
        ensure_ascii=False,
        separators=(",", ":"),
        sort_keys=True,
    ).encode("utf-8")


def canonical_digest(value: Any) -> str:
    return hashlib.sha256(_canonical_bytes(value)).hexdigest()


def certified_gemini_routes() -> CertifiedModelRoutes:
    routes = (
        CertifiedModelRoute(
            route_id="gemini-economic-v1",
            tier=ModelTier.ECONOMY,
            provider_id=PROVIDER_ID,
            model_id=ECONOMIC_MODEL_ID,
            auth_scope="model.generate.itinerary",
            capabilities=frozenset({"json"}),
            timeout_seconds=30.0,
            certification_digest=canonical_digest(
                {"route": "economic", "model": ECONOMIC_MODEL_ID, "version": "1"}
            ),
        ),
        CertifiedModelRoute(
            route_id="gemini-capability-v1",
            tier=ModelTier.CAPABILITY,
            provider_id=PROVIDER_ID,
            model_id=CAPABILITY_MODEL_ID,
            auth_scope="model.generate.itinerary",
            capabilities=frozenset({"json", "complex"}),
            timeout_seconds=45.0,
            certification_digest=canonical_digest(
                {"route": "capability", "model": CAPABILITY_MODEL_ID, "version": "1"}
            ),
        ),
    )
    return CertifiedModelRoutes(routes)


class EnvironmentGeminiCredentialProvider:
    """Resolve the Gemini credential on every invocation without caching it."""

    def __init__(self, environment_variable: str = "GEMINI_API_KEY") -> None:
        if environment_variable != "GEMINI_API_KEY":
            raise ValueError("auth.invalid_credential_binding")
        self._environment_variable = environment_variable

    def resolve(self, provider_id: str, auth_scope: str) -> ProviderCredential:
        if provider_id != PROVIDER_ID or auth_scope != "model.generate.itinerary":
            raise AdapterFailure("auth.invalid_credential_binding", retryable=False)
        value = os.environ.get(self._environment_variable, "")
        if not value:
            raise AdapterFailure("auth.secret_unavailable", retryable=False)
        return ProviderCredential(
            provider_id=provider_id,
            credential_ref="secret://environment/GEMINI_API_KEY",
            secret_value=value,
        )


class GeminiModelAdapter:
    """Invoke only allowlisted models at the fixed Google API origin."""

    def __init__(
        self,
        *,
        input_resolver: Callable[[str], str],
        response_schema: dict[str, Any],
        output_validator: Callable[[dict[str, Any]], tuple[str, ...]] | None = None,
        client: httpx.Client | None = None,
    ) -> None:
        self._input_resolver = input_resolver
        self._response_schema = canonical_schema(response_schema)
        self._output_validator = output_validator or (lambda _: ())
        self._client = client

    @staticmethod
    def _response_error(response: httpx.Response) -> AdapterFailure:
        status_code = response.status_code
        provider_status = ""
        provider_reasons: set[str] = set()
        try:
            error = response.json().get("error", {})
            if isinstance(error, dict):
                provider_status = str(error.get("status", "")).upper()
                details = error.get("details", ())
                if isinstance(details, list):
                    for detail in details:
                        if isinstance(detail, dict):
                            reason = detail.get("reason")
                            if isinstance(reason, str):
                                provider_reasons.add(reason.upper())
        except (TypeError, ValueError):
            pass
        if status_code == 429:
            return AdapterFailure("llm.rate_limited", retryable=True)
        if status_code in {500, 502, 503, 504}:
            return AdapterFailure("llm.provider_unavailable", retryable=True)
        if status_code == 401 or provider_status == "UNAUTHENTICATED":
            return AdapterFailure("auth.provider_unauthenticated", retryable=False)
        if status_code == 404 or provider_status == "NOT_FOUND":
            return AdapterFailure("llm.model_not_found", retryable=False)
        if (
            status_code == 402
            or provider_status == "FAILED_PRECONDITION"
            or any("BILLING" in reason or "ACCOUNT" in reason for reason in provider_reasons)
        ):
            return AdapterFailure("billing.provider_account", retryable=False)
        if status_code == 403 or provider_status == "PERMISSION_DENIED":
            return AdapterFailure("auth.provider_permission_denied", retryable=False)
        if status_code == 400 or provider_status == "INVALID_ARGUMENT":
            return AdapterFailure("llm.request_invalid", retryable=False)
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
            route.provider_id != PROVIDER_ID
            or route.model_id not in ALLOWED_MODELS
            or credential.provider_id != PROVIDER_ID
            or credential.credential_ref != "secret://environment/GEMINI_API_KEY"
            or not credential.secret_value
        ):
            raise AdapterFailure("auth.invalid_credential_binding", retryable=False)
        try:
            prompt = self._input_resolver(invocation.input_ref)
        except Exception as error:
            raise AdapterFailure("context.required_slice_missing", retryable=False) from error
        if not isinstance(prompt, str) or not prompt or canonical_digest(prompt) != invocation.input_sha256:
            raise AdapterFailure("context.required_slice_missing", retryable=False)
        payload = {
            "contents": [{"role": "user", "parts": [{"text": prompt}]}],
            "generationConfig": {
                "temperature": 0,
                "maxOutputTokens": invocation.max_output_tokens,
                "responseMimeType": "application/json",
                "responseJsonSchema": self._response_schema,
                "thinkingConfig": {"thinkingLevel": "low"},
            },
        }
        url = f"{API_ORIGIN}/{API_VERSION}/models/{route.model_id}:generateContent"
        owns_client = self._client is None
        client = self._client or httpx.Client(
            follow_redirects=False,
            timeout=httpx.Timeout(timeout_seconds),
        )
        try:
            response = client.post(
                url,
                headers={
                    "x-goog-api-key": credential.secret_value,
                    "content-type": "application/json",
                },
                json=payload,
                timeout=timeout_seconds,
            )
            if response.status_code >= 400:
                raise self._response_error(response)
            body = response.json()
            usage = body["usageMetadata"]
            input_tokens = int(usage["promptTokenCount"])
            output_tokens = int(usage["candidatesTokenCount"]) + int(
                usage.get("thoughtsTokenCount", 0)
            )
            if input_tokens < 1 or output_tokens < 1:
                raise AdapterFailure("llm.usage_invalid", retryable=False)
            token_usage = TokenUsage(
                input_tokens=input_tokens, output_tokens=output_tokens
            )
            candidates = body["candidates"]
            first = candidates[0]
            if first.get("finishReason") != "STOP":
                raise AdapterFailure(
                    "llm.incomplete_output",
                    retryable=False,
                    metered_usage=token_usage,
                    input_cache_miss_tokens=input_tokens,
                )
            output_text = first["content"]["parts"][0]["text"]
            try:
                parsed = json.loads(output_text)
            except (TypeError, ValueError) as error:
                raise AdapterFailure(
                    "llm.schema_invalid",
                    retryable=False,
                    metered_usage=token_usage,
                    input_cache_miss_tokens=input_tokens,
                ) from error
            if not isinstance(parsed, dict):
                raise AdapterFailure(
                    "llm.schema_invalid",
                    retryable=False,
                    metered_usage=token_usage,
                    input_cache_miss_tokens=input_tokens,
                )
            output_sha256 = canonical_digest(parsed)
            rule_codes = tuple(
                sorted(
                    set(validation_rule_codes(parsed, self._response_schema))
                    | set(self._output_validator(parsed))
                )
            )
            if rule_codes:
                raise AdapterFailure(
                    rule_codes[0],
                    retryable=False,
                    rule_codes=rule_codes,
                    metered_usage=token_usage,
                    output_sha256=output_sha256,
                    input_cache_hit_tokens=0,
                    input_cache_miss_tokens=input_tokens,
                )
            return ModelResult(
                output_ref=f"candidate://sha256/{output_sha256}",
                output_sha256=output_sha256,
                usage=token_usage,
                payload=parsed,
                input_cache_miss_tokens=input_tokens,
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
