"""Deterministic feature routing that leaves every legacy family outside Agent."""

from __future__ import annotations

from dataclasses import dataclass
from enum import StrEnum
from typing import Protocol

from app.auth.context import RequestContext


SHA256_LENGTH = 64


class RouteIntent(StrEnum):
    ITINERARY_AGENT = "itinerary_agent"
    LEGACY_CHAT = "legacy_chat"
    LEGACY_IMPORT = "legacy_import"
    LEGACY_AUTH = "legacy_auth"
    LEGACY_FALLBACK = "legacy_fallback"


class SelectedRoute(StrEnum):
    AGENT_ITINERARY = "agent_itinerary"
    LEGACY_CHAT = "legacy_chat"
    LEGACY_IMPORT = "legacy_import"
    LEGACY_AUTH = "legacy_auth"
    LEGACY_FALLBACK = "legacy_fallback"
    LEGACY_ITINERARY = "legacy_itinerary"


LEGACY_DECISIONS = {
    RouteIntent.LEGACY_CHAT: SelectedRoute.LEGACY_CHAT,
    RouteIntent.LEGACY_IMPORT: SelectedRoute.LEGACY_IMPORT,
    RouteIntent.LEGACY_AUTH: SelectedRoute.LEGACY_AUTH,
    RouteIntent.LEGACY_FALLBACK: SelectedRoute.LEGACY_FALLBACK,
}


@dataclass(frozen=True, slots=True)
class FeatureFlagSnapshot:
    itinerary_agent_enabled: bool
    kill_switch: bool
    generation: int
    active_behavior_digest: str | None

    def __post_init__(self) -> None:
        if self.generation < 1:
            raise ValueError("feature.invalid_snapshot")
        if self.active_behavior_digest is not None and (
            len(self.active_behavior_digest) != SHA256_LENGTH
            or any(character not in "0123456789abcdef" for character in self.active_behavior_digest)
        ):
            raise ValueError("feature.invalid_snapshot")


class FeatureFlagStore(Protocol):
    def resolve(self, *, tenant_id: str, principal_id: str) -> FeatureFlagSnapshot: ...


class FeatureFlagUnavailable(RuntimeError):
    code = "feature.disabled"

    def __init__(self) -> None:
        super().__init__(self.code)


@dataclass(frozen=True, slots=True)
class RouteDecision:
    intent: RouteIntent
    selected_route: SelectedRoute
    agent_call_allowed: bool
    behavior_digest: str | None
    reason: str
    flag_generation: int | None


class FeatureRouter:
    """Resolve only the explicit itinerary intent; all legacy intents bypass the store."""

    def __init__(self, store: FeatureFlagStore) -> None:
        self._store = store

    def decide(
        self,
        intent: RouteIntent,
        context: RequestContext,
        *,
        pinned_behavior_digest: str | None = None,
    ) -> RouteDecision:
        legacy_route = LEGACY_DECISIONS.get(intent)
        if legacy_route is not None:
            return RouteDecision(
                intent=intent,
                selected_route=legacy_route,
                agent_call_allowed=False,
                behavior_digest=None,
                reason="legacy_bypass",
                flag_generation=None,
            )

        if intent is not RouteIntent.ITINERARY_AGENT:
            raise ValueError("feature.invalid_intent")

        try:
            snapshot = self._store.resolve(
                tenant_id=context.tenant_id,
                principal_id=context.principal_id,
            )
        except Exception:
            return self._legacy_itinerary("flag_store_unavailable")

        if snapshot.kill_switch:
            return self._legacy_itinerary("kill_switch", snapshot.generation)
        if pinned_behavior_digest is not None:
            self._validate_digest(pinned_behavior_digest)
            return RouteDecision(
                intent=intent,
                selected_route=SelectedRoute.AGENT_ITINERARY,
                agent_call_allowed=True,
                behavior_digest=pinned_behavior_digest,
                reason="running_manifest_pinned",
                flag_generation=snapshot.generation,
            )
        if not snapshot.itinerary_agent_enabled or snapshot.active_behavior_digest is None:
            return self._legacy_itinerary("feature_disabled", snapshot.generation)
        return RouteDecision(
            intent=intent,
            selected_route=SelectedRoute.AGENT_ITINERARY,
            agent_call_allowed=True,
            behavior_digest=snapshot.active_behavior_digest,
            reason="feature_enabled",
            flag_generation=snapshot.generation,
        )

    @staticmethod
    def _legacy_itinerary(reason: str, generation: int | None = None) -> RouteDecision:
        return RouteDecision(
            intent=RouteIntent.ITINERARY_AGENT,
            selected_route=SelectedRoute.LEGACY_ITINERARY,
            agent_call_allowed=False,
            behavior_digest=None,
            reason=reason,
            flag_generation=generation,
        )

    @staticmethod
    def _validate_digest(value: str) -> None:
        if len(value) != SHA256_LENGTH or any(
            character not in "0123456789abcdef" for character in value
        ):
            raise ValueError("feature.invalid_manifest")
