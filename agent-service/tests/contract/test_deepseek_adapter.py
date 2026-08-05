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
from app.models.json_schema import (  # noqa: E402
    canonical_schema,
    canonical_schema_text,
    validation_rule_codes,
)


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
TEST_SCHEMA = {
    "type": "object",
    "properties": {
        "title": {"type": "string", "minLength": 1},
        "days": {"type": "array", "items": {"type": "object", "properties": {}, "additionalProperties": False}},
    },
    "required": ["title", "days"],
    "additionalProperties": False,
}


def _adapter(
    handler, *, output_validator=None
) -> tuple[DeepSeekModelAdapter, httpx.Client]:
    client = httpx.Client(transport=httpx.MockTransport(handler))
    return (
        DeepSeekModelAdapter(
            input_resolver=lambda _: PROMPT,
            response_schema=TEST_SCHEMA,
            output_validator=output_validator,
            client=client,
        ),
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
    assert observed[0]["authorization"] == "Bearer " + CREDENTIAL.secret_value
    body = observed[0]["body"]
    assert body["model"] == MODEL_ID  # type: ignore[index]
    assert body["thinking"] == {"type": "disabled"}  # type: ignore[index]
    assert body["response_format"] == {"type": "json_object"}  # type: ignore[index]
    messages = body["messages"]  # type: ignore[index]
    assert messages[0]["role"] == "system"
    assert messages[0]["content"].endswith(canonical_schema_text(TEST_SCHEMA))
    assert messages[1] == {"role": "user", "content": PROMPT}
    assert body["temperature"] == 0  # type: ignore[index]
    assert result.usage.total_tokens == 125
    assert result.input_cache_hit_tokens == 40
    assert result.input_cache_miss_tokens == 60


@pytest.mark.parametrize(
    ("status", "code", "retryable"),
    [
        (429, "llm.rate_limited", True),
        (503, "llm.provider_unavailable", True),
        (400, "llm.request_invalid", False),
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


def test_adapter_rejects_schema_and_business_shape_with_content_free_codes() -> None:
    responses = iter(
        (
            httpx.Response(
                200,
                json={
                    "choices": [
                        {
                            "finish_reason": "stop",
                            "message": {
                                "content": '{"title":"fixed","days":[],"extra":1}'
                            },
                        }
                    ],
                    "usage": {"prompt_tokens": 10, "completion_tokens": 5},
                },
            ),
            httpx.Response(
                200,
                json={
                    "choices": [
                        {
                            "finish_reason": "stop",
                            "message": {"content": '{"title":"fixed","days":[]}'},
                        }
                    ],
                    "usage": {"prompt_tokens": 10, "completion_tokens": 5},
                },
            ),
        )
    )
    adapter, client = _adapter(
        lambda _: next(responses),
        output_validator=lambda _: ("quality.exact_day_count",),
    )
    try:
        with pytest.raises(AdapterFailure) as schema_failure:
            adapter.invoke(
                certified_deepseek_route(), INVOCATION, CREDENTIAL, timeout_seconds=9
            )
        with pytest.raises(AdapterFailure) as business_failure:
            adapter.invoke(
                certified_deepseek_route(), INVOCATION, CREDENTIAL, timeout_seconds=9
            )
    finally:
        client.close()
    assert schema_failure.value.rule_codes == (
        "quality.exact_day_count",
        "schema.additional_properties",
    )
    assert schema_failure.value.metered_usage is not None
    assert business_failure.value.rule_codes == ("quality.exact_day_count",)
    assert business_failure.value.metered_usage is not None


@pytest.mark.parametrize(
    ("payload", "expected"),
    [
        ({"title": "fixed"}, "schema.required"),
        ({"title": "", "days": []}, "schema.min_length"),
        ({"title": "fixed", "days": "not-array"}, "schema.type"),
        ({"title": "fixed", "days": [], "extra": 1}, "schema.additional_properties"),
    ],
)
def test_local_schema_validator_covers_closed_output_shapes(
    payload: dict[str, object], expected: str
) -> None:
    assert expected in validation_rule_codes(payload, TEST_SCHEMA)


@pytest.mark.parametrize(
    ("schema_type", "valid", "invalid"),
    [
        ("boolean", True, 1),
        ("number", 1.25, True),
        ("number", 0, float("inf")),
        ("null", None, False),
    ],
)
def test_local_schema_validator_covers_json_primitive_types(
    schema_type: str, valid: object, invalid: object
) -> None:
    schema = canonical_schema({"type": schema_type})
    assert validation_rule_codes(valid, schema) == ()
    assert validation_rule_codes(invalid, schema) == ("schema.type",)
