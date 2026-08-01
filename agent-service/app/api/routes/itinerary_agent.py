"""In-process itinerary dispatch; no public route is mounted before its API phase."""

from __future__ import annotations

from collections.abc import Callable
from dataclasses import dataclass
from typing import Any

from app.api.routing import FeatureRouter, RouteIntent, SelectedRoute
from app.auth.context import RequestContext


RouteHandler = Callable[[RequestContext], Any]


@dataclass(frozen=True, slots=True)
class ItineraryRouteHandlers:
    agent_itinerary: RouteHandler
    legacy_itinerary: RouteHandler
    legacy_chat: RouteHandler
    legacy_import: RouteHandler
    legacy_auth: RouteHandler
    legacy_fallback: RouteHandler


class ItineraryRouteCoordinator:
    """Call the Agent handler only for an explicitly enabled itinerary decision."""

    def __init__(self, router: FeatureRouter, handlers: ItineraryRouteHandlers) -> None:
        self._router = router
        self._handlers = handlers

    def dispatch(
        self,
        intent: RouteIntent,
        context: RequestContext,
        *,
        pinned_behavior_digest: str | None = None,
    ) -> Any:
        decision = self._router.decide(
            intent,
            context,
            pinned_behavior_digest=pinned_behavior_digest,
        )
        handler = {
            SelectedRoute.AGENT_ITINERARY: self._handlers.agent_itinerary,
            SelectedRoute.LEGACY_ITINERARY: self._handlers.legacy_itinerary,
            SelectedRoute.LEGACY_CHAT: self._handlers.legacy_chat,
            SelectedRoute.LEGACY_IMPORT: self._handlers.legacy_import,
            SelectedRoute.LEGACY_AUTH: self._handlers.legacy_auth,
            SelectedRoute.LEGACY_FALLBACK: self._handlers.legacy_fallback,
        }[decision.selected_route]
        if decision.agent_call_allowed != (
            decision.selected_route is SelectedRoute.AGENT_ITINERARY
        ):
            raise RuntimeError("feature.route_invariant")
        return handler(context)
