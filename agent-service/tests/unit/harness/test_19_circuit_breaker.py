from __future__ import annotations

import site
import sys
from pathlib import Path

import pytest


SERVICE_ROOT = Path(__file__).resolve().parents[3]
site.addsitedir(str(SERVICE_ROOT / ".venv" / "Lib" / "site-packages"))
sys.path.insert(0, str(SERVICE_ROOT))

from app.models.gateway import CircuitBreaker, ModelGatewayError  # noqa: E402


def test_19_circuit_breaker_s_allows_closed_route() -> None:
    CircuitBreaker(failure_threshold=2, cooldown_seconds=10).allow("r", now_monotonic=0)


def test_19_circuit_breaker_s_success_resets_failures() -> None:
    breaker = CircuitBreaker(failure_threshold=2, cooldown_seconds=10)
    breaker.failure("r", now_monotonic=0)
    breaker.success("r")
    breaker.allow("r", now_monotonic=1)


def test_19_circuit_breaker_i_opens_at_threshold() -> None:
    breaker = CircuitBreaker(failure_threshold=2, cooldown_seconds=10)
    breaker.failure("r", now_monotonic=0)
    breaker.failure("r", now_monotonic=1)
    with pytest.raises(ModelGatewayError, match="provider.circuit_open"):
        breaker.allow("r", now_monotonic=2)


def test_19_circuit_breaker_i_isolates_route_state() -> None:
    breaker = CircuitBreaker(failure_threshold=1, cooldown_seconds=10)
    breaker.failure("bad", now_monotonic=0)
    breaker.allow("good", now_monotonic=1)


def test_19_circuit_breaker_d_allows_bounded_probe_after_cooldown() -> None:
    breaker = CircuitBreaker(failure_threshold=1, cooldown_seconds=10)
    breaker.failure("r", now_monotonic=0)
    breaker.allow("r", now_monotonic=10)
