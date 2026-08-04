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
        client: httpx.Client | None = None,
    ) -> None:
        self._input_resolver = input_resolver
        self._response_schema = json.loads(_canonical_bytes(response_schema))
        self._client = client

    @staticmethod
    def _response_error(status_code: int) -> AdapterFailure:
        if status_code == 429:
            return AdapterFailure("llm.rate_limited", retryable=True)
        if status_code in {500, 503, 504}:
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
                raise self._response_error(response.status_code)
            body = response.json()
            candidates = body["candidates"]
            first = candidates[0]
            if first.get("finishReason") != "STOP":
                raise AdapterFailure("llm.incomplete_output", retryable=False)
            output_text = first["content"]["parts"][0]["text"]
            parsed = json.loads(output_text)
            if not isinstance(parsed, dict):
                raise AdapterFailure("llm.schema_invalid", retryable=False)
            usage = body["usageMetadata"]
            input_tokens = int(usage["promptTokenCount"])
            output_tokens = int(usage["candidatesTokenCount"]) + int(
                usage.get("thoughtsTokenCount", 0)
            )
            if input_tokens < 1 or output_tokens < 1:
                raise AdapterFailure("llm.usage_invalid", retryable=False)
            output_sha256 = canonical_digest(parsed)
            return ModelResult(
                output_ref=f"candidate://sha256/{output_sha256}",
                output_sha256=output_sha256,
                usage=TokenUsage(input_tokens=input_tokens, output_tokens=output_tokens),
                payload=parsed,
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
