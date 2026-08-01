"""Certified two-tier model routing without dynamic provider or URL selection."""

from __future__ import annotations

import re
from dataclasses import dataclass
from enum import StrEnum


SHA256 = re.compile(r"^[0-9a-f]{64}$")


class ModelRouteError(ValueError):
    def __init__(self, code: str = "model.no_certified_route") -> None:
        self.code = code
        super().__init__(code)


class ModelTier(StrEnum):
    ECONOMY = "economy"
    CAPABILITY = "capability"


@dataclass(frozen=True, slots=True)
class CertifiedModelRoute:
    route_id: str
    tier: ModelTier
    provider_id: str
    model_id: str
    auth_scope: str
    capabilities: frozenset[str]
    timeout_seconds: float
    certification_digest: str

    def __post_init__(self) -> None:
        if (
            not self.route_id
            or not self.provider_id
            or not self.model_id
            or not self.auth_scope
            or not self.capabilities
            or self.timeout_seconds <= 0
            or SHA256.fullmatch(self.certification_digest) is None
        ):
            raise ModelRouteError()


class CertifiedModelRoutes:
    """An immutable, exactly-two-route table for one provider."""

    def __init__(self, routes: tuple[CertifiedModelRoute, ...]) -> None:
        tiers = {route.tier for route in routes}
        if (
            len(routes) != 2
            or tiers != {ModelTier.ECONOMY, ModelTier.CAPABILITY}
            or len({route.route_id for route in routes}) != 2
            or len({route.model_id for route in routes}) != 2
            or len({route.provider_id for route in routes}) != 1
        ):
            raise ModelRouteError()
        self._by_tier = {route.tier: route for route in routes}

    @property
    def routes(self) -> tuple[CertifiedModelRoute, CertifiedModelRoute]:
        return (
            self._by_tier[ModelTier.ECONOMY],
            self._by_tier[ModelTier.CAPABILITY],
        )

    def plan(self, required_capabilities: frozenset[str]) -> tuple[CertifiedModelRoute, ...]:
        if not required_capabilities:
            raise ModelRouteError()
        economy, capability = self.routes
        preferred = (
            economy
            if required_capabilities.issubset(economy.capabilities)
            else capability
        )
        if not required_capabilities.issubset(preferred.capabilities):
            raise ModelRouteError()
        fallback = capability if preferred is economy else economy
        if required_capabilities.issubset(fallback.capabilities):
            return preferred, fallback
        return (preferred,)
