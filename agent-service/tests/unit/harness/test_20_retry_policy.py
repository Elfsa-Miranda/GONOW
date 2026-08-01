from __future__ import annotations

import site
import sys
from pathlib import Path

import pytest


SERVICE_ROOT = Path(__file__).resolve().parents[3]
site.addsitedir(str(SERVICE_ROOT / ".venv" / "Lib" / "site-packages"))
sys.path.insert(0, str(SERVICE_ROOT))

from app.models.gateway import AdapterFailure, ModelGatewayError, RetryPolicy  # noqa: E402


def test_20_retry_policy_s_allows_one_retryable_fallback() -> None:
    policy = RetryPolicy(max_total_attempts=2)
    assert policy.allows_fallback(AdapterFailure("llm.timeout", retryable=True), attempts=1)


def test_20_retry_policy_i_rejects_non_retryable_fallback() -> None:
    policy = RetryPolicy(max_total_attempts=2)
    assert not policy.allows_fallback(AdapterFailure("llm.bad", retryable=False), attempts=1)


def test_20_retry_policy_i_stops_at_total_attempt_bound() -> None:
    policy = RetryPolicy(max_total_attempts=2)
    assert not policy.allows_fallback(AdapterFailure("llm.timeout", retryable=True), attempts=2)


def test_20_retry_policy_d_rejects_unbounded_policy() -> None:
    with pytest.raises(ModelGatewayError, match="retry.policy_invalid"):
        RetryPolicy(max_total_attempts=3)
