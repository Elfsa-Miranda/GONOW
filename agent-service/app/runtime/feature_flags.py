"""Fail-closed runtime feature flags with atomic replica propagation."""

from __future__ import annotations

import json
import re
from dataclasses import dataclass
from hashlib import sha256
from threading import RLock


SHA256_RE = re.compile(r"[0-9a-f]{64}")
SAFE_NAME_RE = re.compile(r"[a-z][a-z0-9_-]{0,63}")


class FeatureFlagInvalid(ValueError):
    code = "feature.invalid_snapshot"

    def __init__(self) -> None:
        super().__init__(self.code)


class FeatureFlagCasConflict(RuntimeError):
    code = "feature.generation_conflict"

    def __init__(self) -> None:
        super().__init__(self.code)


class FeatureFlagPropagationError(RuntimeError):
    code = "feature.propagation_failed"

    def __init__(self) -> None:
        super().__init__(self.code)


@dataclass(frozen=True, slots=True)
class RuntimeFeatureSnapshot:
    tenant_id: str
    generation: int
    behavior_enabled: bool
    route_enabled: bool
    enabled_cohorts: frozenset[str]
    active_behavior_digest: str | None

    def __post_init__(self) -> None:
        if (
            not self.tenant_id
            or self.generation < 1
            or any(SAFE_NAME_RE.fullmatch(cohort) is None for cohort in self.enabled_cohorts)
            or (
                self.active_behavior_digest is not None
                and SHA256_RE.fullmatch(self.active_behavior_digest) is None
            )
        ):
            raise FeatureFlagInvalid()

    @classmethod
    def fail_closed(cls, tenant_id: str) -> RuntimeFeatureSnapshot:
        return cls(
            tenant_id=tenant_id,
            generation=1,
            behavior_enabled=False,
            route_enabled=False,
            enabled_cohorts=frozenset(),
            active_behavior_digest=None,
        )

    def state_sha256(self) -> str:
        canonical = json.dumps(
            {
                "active_behavior_digest": self.active_behavior_digest,
                "behavior_enabled": self.behavior_enabled,
                "enabled_cohorts": sorted(self.enabled_cohorts),
                "generation": self.generation,
                "route_enabled": self.route_enabled,
                "tenant_ref": _pseudonymous_ref("tenant", self.tenant_id),
            },
            sort_keys=True,
            separators=(",", ":"),
        )
        return sha256(canonical.encode("utf-8")).hexdigest()


@dataclass(frozen=True, slots=True)
class FeatureRouteDecision:
    agent_run_allowed: bool
    selected_path: str
    reason: str
    generation: int
    behavior_digest: str | None

    @property
    def old_path_available(self) -> bool:
        return self.selected_path == "legacy"


def decide_new_run(snapshot: RuntimeFeatureSnapshot, *, cohort: str) -> FeatureRouteDecision:
    """Route a new run only when behavior, route, cohort, and digest all permit it."""

    if not snapshot.behavior_enabled:
        return _legacy(snapshot, "behavior_disabled")
    if not snapshot.route_enabled:
        return _legacy(snapshot, "route_disabled")
    if cohort not in snapshot.enabled_cohorts:
        return _legacy(snapshot, "cohort_disabled")
    if snapshot.active_behavior_digest is None:
        return _legacy(snapshot, "behavior_unavailable")
    return FeatureRouteDecision(
        agent_run_allowed=True,
        selected_path="agent",
        reason="enabled",
        generation=snapshot.generation,
        behavior_digest=snapshot.active_behavior_digest,
    )


def _legacy(snapshot: RuntimeFeatureSnapshot, reason: str) -> FeatureRouteDecision:
    return FeatureRouteDecision(
        agent_run_allowed=False,
        selected_path="legacy",
        reason=reason,
        generation=snapshot.generation,
        behavior_digest=None,
    )


@dataclass(frozen=True, slots=True)
class FeatureFlagAuditReceipt:
    receipt_id: str
    actor_ref: str
    tenant_ref: str
    scope: str
    enabled: bool
    cohort: str | None
    previous_generation: int
    generation: int
    state_sha256: str


class FeatureFlagReplica:
    """Read-side used by one named process; prepare is side-effect free."""

    def __init__(self, name: str, initial: RuntimeFeatureSnapshot) -> None:
        if SAFE_NAME_RE.fullmatch(name) is None:
            raise FeatureFlagInvalid()
        self.name = name
        self._snapshot = initial

    def prepare(self, candidate: RuntimeFeatureSnapshot) -> None:
        if (
            candidate.tenant_id != self._snapshot.tenant_id
            or candidate.generation != self._snapshot.generation + 1
        ):
            raise FeatureFlagPropagationError()

    def commit(self, candidate: RuntimeFeatureSnapshot) -> None:
        self._snapshot = candidate

    def resolve(self) -> RuntimeFeatureSnapshot:
        return self._snapshot


class FeatureFlagControlPlane:
    """Atomic local control plane for state, replicas, and append-only audit."""

    def __init__(self, initial: RuntimeFeatureSnapshot) -> None:
        self._snapshot = initial
        self._replicas: dict[str, FeatureFlagReplica] = {}
        self._receipts: list[FeatureFlagAuditReceipt] = []
        self._lock = RLock()

    def resolve(self) -> RuntimeFeatureSnapshot:
        with self._lock:
            return self._snapshot

    def assert_generation(self, expected_generation: int) -> RuntimeFeatureSnapshot:
        with self._lock:
            if self._snapshot.generation != expected_generation:
                raise FeatureFlagCasConflict()
            return self._snapshot

    def register_replica(self, name: str) -> FeatureFlagReplica:
        with self._lock:
            if name in self._replicas:
                raise FeatureFlagInvalid()
            replica = FeatureFlagReplica(name, self._snapshot)
            self._replicas[name] = replica
            return replica

    def compare_and_swap(
        self,
        *,
        expected_generation: int,
        candidate: RuntimeFeatureSnapshot,
        audit_receipt: FeatureFlagAuditReceipt,
    ) -> RuntimeFeatureSnapshot:
        with self._lock:
            if (
                self._snapshot.generation != expected_generation
                or candidate.generation != expected_generation + 1
                or candidate.tenant_id != self._snapshot.tenant_id
                or audit_receipt.previous_generation != expected_generation
                or audit_receipt.generation != candidate.generation
                or audit_receipt.state_sha256 != candidate.state_sha256()
            ):
                raise FeatureFlagCasConflict()
            for replica in self._replicas.values():
                replica.prepare(candidate)

            # The in-memory commit is one critical section: no caller can observe
            # state without its matching replica generation and immutable receipt.
            self._receipts.append(audit_receipt)
            self._snapshot = candidate
            for replica in self._replicas.values():
                replica.commit(candidate)
            return candidate

    def receipts(self) -> tuple[FeatureFlagAuditReceipt, ...]:
        with self._lock:
            return tuple(self._receipts)


def _pseudonymous_ref(kind: str, value: str) -> str:
    return sha256(f"gonow-feature-flag:{kind}:{value}".encode()).hexdigest()
