"""IP-before-auth and principal-after-policy rate-limit primitives."""

from __future__ import annotations

import math
import time
from dataclasses import dataclass
from typing import Protocol


class RateLimitExceeded(RuntimeError):
    code = "rate.limit"

    def __init__(self, retry_after_seconds: int) -> None:
        super().__init__(self.code)
        self.retry_after_seconds = retry_after_seconds


class RateLimitStoreUnavailable(RuntimeError):
    pass


class RateLimitStore(Protocol):
    def increment(self, key: str, window_id: int) -> int:
        """Atomically increment and return the current count."""


class InMemoryRateLimitStore:
    """Deterministic isolated-test store; never a production truth source."""

    def __init__(self) -> None:
        self._counts: dict[tuple[str, int], int] = {}

    def increment(self, key: str, window_id: int) -> int:
        composite = (key, window_id)
        self._counts[composite] = self._counts.get(composite, 0) + 1
        return self._counts[composite]


@dataclass(frozen=True, slots=True)
class RateLimitDecision:
    allowed: bool
    retry_after_seconds: int
    key: str


class RateLimiter:
    def __init__(self, store: RateLimitStore, *, limit: int, window_seconds: int, fail_closed: bool = True) -> None:
        if limit < 1 or window_seconds < 1:
            raise ValueError("rate limit values must be positive")
        self._store = store
        self._limit = limit
        self._window_seconds = window_seconds
        self._fail_closed = fail_closed

    def check(self, *, scope: str, identity_ref: str, route: str, now: float | None = None) -> RateLimitDecision:
        instant = time.time() if now is None else now
        window_id = math.floor(instant / self._window_seconds)
        key = f"{scope}:{identity_ref}:{route}"
        try:
            count = self._store.increment(key, window_id)
        except Exception as error:
            if self._fail_closed:
                raise RateLimitStoreUnavailable("rate limit store unavailable") from error
            return RateLimitDecision(allowed=True, retry_after_seconds=0, key=key)
        if count > self._limit:
            retry_after = max(1, math.ceil((window_id + 1) * self._window_seconds - instant))
            raise RateLimitExceeded(retry_after)
        return RateLimitDecision(allowed=True, retry_after_seconds=0, key=key)
