from __future__ import annotations

import site
import sys
from pathlib import Path

import pytest


SERVICE_ROOT = Path(__file__).resolve().parents[3]
site.addsitedir(str(SERVICE_ROOT / ".venv" / "Lib" / "site-packages"))
sys.path.insert(0, str(SERVICE_ROOT))

from app.models.routes import (  # noqa: E402
    CertifiedModelRoute,
    CertifiedModelRoutes,
    ModelRouteError,
    ModelTier,
)


def _route(tier: ModelTier, capabilities: frozenset[str]) -> CertifiedModelRoute:
    return CertifiedModelRoute(
        tier.value,
        tier,
        "provider-a",
        f"model-{tier.value}",
        "models.invoke",
        capabilities,
        5,
        ("a" if tier is ModelTier.ECONOMY else "b") * 64,
    )


def _routes() -> CertifiedModelRoutes:
    return CertifiedModelRoutes(
        (_route(ModelTier.ECONOMY, frozenset({"json"})), _route(ModelTier.CAPABILITY, frozenset({"json", "tool"})))
    )


def test_09_model_router_s_selects_economy_deterministically() -> None:
    assert _routes().plan(frozenset({"json"}))[0].tier is ModelTier.ECONOMY


def test_09_model_router_i_rejects_unknown_capability() -> None:
    with pytest.raises(ModelRouteError):
        _routes().plan(frozenset({"vision"}))


def test_09_model_router_i_rejects_cross_provider_routes() -> None:
    capability = _route(ModelTier.CAPABILITY, frozenset({"json"}))
    capability = CertifiedModelRoute(
        capability.route_id,
        capability.tier,
        "provider-b",
        capability.model_id,
        capability.auth_scope,
        capability.capabilities,
        capability.timeout_seconds,
        capability.certification_digest,
    )
    with pytest.raises(ModelRouteError):
        CertifiedModelRoutes((_route(ModelTier.ECONOMY, frozenset({"json"})), capability))


def test_09_model_router_d_rejects_missing_certification() -> None:
    with pytest.raises(ModelRouteError):
        CertifiedModelRoute("bad", ModelTier.ECONOMY, "p", "m", "scope", frozenset({"json"}), 1, "bad")
