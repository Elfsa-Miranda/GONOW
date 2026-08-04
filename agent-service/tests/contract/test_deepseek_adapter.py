from __future__ import annotations

from dataclasses import replace
import json
import site
import sys
from pathlib import Path

import httpx
import pytest


SERVICE_ROOT = Path(__file__).resolve().parents[2]
site.addsitedir(str(SERVICE_ROOT / ".venv" / "Lib" / "site-packages"))
sys.path.insert(0, str(SERVICE_ROOT))

from app.models.deepseek import (  # noqa: E402
    API_ORIGIN,
    API_PATH,
    MODEL_ID,
    PROVIDER_ID,
    DeepSeekModelAdapter,
    EnvironmentDeepSeekCredentialProvider,
    certified_deepseek_route,
)
from app.models.gateway import AdapterFailure, ModelInvocation, ProviderCredential  # noqa: E402
from app.models.gemini import canonical_digest  # noqa: E402


PROMPT = 'Return JSON: {"route":"fixed"}'
INVOCATION = ModelInvocation(
    request_id="deepseek-contract-001",
    input_ref="context://sha256/" + canonical_digest(PROMPT),
    input_sha256=canonical_digest(PROMPT),
    required_capabilities=frozenset({"json"}),
    max_output_tokens=1024,
)
CREDENTIAL = ProviderCredential(
    PROVIDER_ID,
    "secret://environment/DEEPSEEK_API_KEY",
    "synthetic-deepseek-credential",
)


def _adapter(handler) -> tuple[DeepSeekModelAdapter, httpx.Client]:
    client = httpx.Client(transport=httpx.MockTransport(handler))
    return (
        DeepSeekModelAdapter(input_resolver=lambda _: PROMPT, client=client),
        client,
    )


def test_adapter_uses_one_literal_origin_model_non_thinking_json_request() -> None:
    observed: list[dict[str, object]] = []

    def handler(request: httpx.Request) -> httpx.Response:
        body = json.loads(request.content)
        observed.append(
            {
                "url": str(request.url),
                "authorization": request.headers["authorization"],
                "body": body,
            }
        )
        return httpx.Response(
            200,
            json={
                "choices": [
                    {
                        "finish_reason": "stop",
                        "message": {"content": '{"title":"fixed","days":[]}'},
                    }
                ],
                "usage": {
                    "prompt_tokens": 100,
                    "completion_tokens": 25,
                    "prompt_cache_hit_tokens": 40,
                    "prompt_cache_miss_tokens": 60,
                },
            },
        )

    adapter, client = _adapter(handler)
    try:
        result = adapter.invoke(
            certified_deepseek_route(), INVOCATION, CREDENTIAL, timeout_seconds=9
        )
    finally:
        client.close()
    assert observed[0]["url"] == API_ORIGIN + API_PATH
    assert observed[0]["authorization"] == "Bearer synthetic-deepseek-credential"
    body = observed[0]["body"]
    assert body["model"] == MODEL_ID  # type: ignore[index]
    assert body["thinking"] == {"type": "disabled"}  # type: ignore[index]
    assert body["response_format"] == {"type": "json_object"}  # type: ignore[index]
    assert body["temperature"] == 0  # type: ignore[index]
    assert result.usage.total_tokens == 125
    assert result.input_cache_hit_tokens == 40
    assert result.input_cache_miss_tokens == 60


@pytest.mark.parametrize(
    ("status", "code", "retryable"),
    [
        (429, "llm.rate_limited", True),
        (503, "llm.provider_unavailable", True),
        (400, "llm.provider_rejected", False),
    ],
)
def test_adapter_classifies_provider_failures_without_network_retry(
    status: int, code: str, retryable: bool
) -> None:
    adapter, client = _adapter(lambda _: httpx.Response(status, json={"error": {}}))
    try:
        with pytest.raises(AdapterFailure, match=code) as caught:
            adapter.invoke(
                certified_deepseek_route(), INVOCATION, CREDENTIAL, timeout_seconds=9
            )
    finally:
        client.close()
    assert caught.value.retryable is retryable


def test_adapter_rejects_any_non_allowlisted_model_before_http() -> None:
    calls = 0

    def handler(_: httpx.Request) -> httpx.Response:
        nonlocal calls
        calls += 1
        return httpx.Response(200, json={})

    adapter, client = _adapter(handler)
    try:
        with pytest.raises(AdapterFailure, match="auth.invalid_credential_binding"):
            adapter.invoke(
                replace(certified_deepseek_route(), model_id="dynamic-model"),
                INVOCATION,
                CREDENTIAL,
                timeout_seconds=9,
            )
    finally:
        client.close()
    assert calls == 0


def test_environment_credential_is_exactly_bound_and_repr_is_redacted(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setenv("DEEPSEEK_API_KEY", "synthetic-deepseek-credential")
    credential = EnvironmentDeepSeekCredentialProvider().resolve(
        PROVIDER_ID, "model.generate.itinerary"
    )
    assert credential.secret_value == "synthetic-deepseek-credential"
    assert "synthetic-deepseek-credential" not in repr(credential)
    with pytest.raises(ValueError, match="auth.invalid_credential_binding"):
        EnvironmentDeepSeekCredentialProvider("CALLER_SELECTED_KEY")


def test_adapter_rejects_invalid_json_and_incomplete_output() -> None:
    responses = iter(
        (
            httpx.Response(
                200,
                json={
                    "choices": [
                        {"finish_reason": "stop", "message": {"content": "not-json"}}
                    ],
                    "usage": {"prompt_tokens": 1, "completion_tokens": 1},
                },
            ),
            httpx.Response(
                200,
                json={
                    "choices": [
                        {"finish_reason": "length", "message": {"content": "{}"}}
                    ],
                    "usage": {"prompt_tokens": 1, "completion_tokens": 1},
                },
            ),
        )
    )
    adapter, client = _adapter(lambda _: next(responses))
    try:
        with pytest.raises(AdapterFailure, match="llm.schema_invalid"):
            adapter.invoke(
                certified_deepseek_route(), INVOCATION, CREDENTIAL, timeout_seconds=9
            )
        with pytest.raises(AdapterFailure, match="llm.incomplete_output"):
            adapter.invoke(
                certified_deepseek_route(), INVOCATION, CREDENTIAL, timeout_seconds=9
            )
    finally:
        client.close()
