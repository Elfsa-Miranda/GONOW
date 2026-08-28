from __future__ import annotations

import site
import sys
from pathlib import Path

import pytest


SERVICE_ROOT = Path(__file__).resolve().parents[2]
site.addsitedir(str(SERVICE_ROOT / ".venv" / "Lib" / "site-packages"))
sys.path.insert(0, str(SERVICE_ROOT))

from app.api.middleware.rate_limit import (  # noqa: E402
    InMemoryRateLimitStore,
    RateLimitExceeded,
    RateLimiter,
    RateLimitStoreUnavailable,
)


def test_ip_and_principal_keys_are_separate() -> None:
    limiter = RateLimiter(InMemoryRateLimitStore(), limit=1, window_seconds=60)
    ip = limiter.check(scope="ip", identity_ref="192.0.2.1", route="runs", now=120.0)
    principal = limiter.check(scope="principal", identity_ref="principal-1", route="runs", now=120.0)
    assert ip.key != principal.key


def test_limit_returns_stable_error_and_retry_after() -> None:
    limiter = RateLimiter(InMemoryRateLimitStore(), limit=1, window_seconds=60)
    limiter.check(scope="ip", identity_ref="192.0.2.1", route="runs", now=121.0)
    with pytest.raises(RateLimitExceeded) as captured:
        limiter.check(scope="ip", identity_ref="192.0.2.1", route="runs", now=121.0)
    assert str(captured.value) == "rate.limit"
    assert captured.value.retry_after_seconds == 59


class FailingStore:
    def increment(self, key: str, window_id: int) -> int:
        raise RuntimeError("synthetic store failure")


def test_high_risk_store_failure_is_closed() -> None:
    limiter = RateLimiter(FailingStore(), limit=1, window_seconds=60)
    with pytest.raises(RateLimitStoreUnavailable):
        limiter.check(scope="principal", identity_ref="principal-1", route="runs", now=120.0)
