from __future__ import annotations

import site
import sys
from pathlib import Path

import pytest


SERVICE_ROOT = Path(__file__).resolve().parents[3]
site.addsitedir(str(SERVICE_ROOT / ".venv" / "Lib" / "site-packages"))
sys.path.insert(0, str(SERVICE_ROOT))

from app.models.gateway import (  # noqa: E402
    ModelGatewayError,
    ModelInvocation,
    ModelResult,
    ProviderCredential,
)
from app.models.ledger import ModelUsageLedger, TokenUsage  # noqa: E402


def test_10_model_gateway_s_accepts_reference_only_invocation() -> None:
    value = ModelInvocation("r", "context://one", "a" * 64, frozenset({"json"}), 1)
    assert value.input_ref == "context://one"


def test_10_model_gateway_s_accepts_reference_only_result() -> None:
    value = ModelResult("candidate://one", "b" * 64, TokenUsage(1, 1))
    assert value.usage.total_tokens == 2


def test_10_model_gateway_i_rejects_embedded_input() -> None:
    with pytest.raises(ModelGatewayError, match="llm.request_invalid"):
        ModelInvocation("r", "raw prompt", "a" * 64, frozenset({"json"}), 1)


def test_10_model_gateway_i_redacts_credential_repr() -> None:
    credential = ProviderCredential("provider-a", "secret://hidden")
    assert "hidden" not in repr(credential)


def test_10_model_gateway_d_ledger_never_accepts_bodies() -> None:
    ledger = ModelUsageLedger()
    ledger.record_failure(request_id="r", route_id="route", attempt=1, failure_code="llm.error")
    assert tuple(record.status for record in ledger.records) == ("failed",)
