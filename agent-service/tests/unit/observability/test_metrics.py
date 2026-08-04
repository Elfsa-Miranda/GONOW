from __future__ import annotations

import json
import site
import sys
from pathlib import Path

import pytest


SERVICE_ROOT = Path(__file__).resolve().parents[3]
REPOSITORY_ROOT = SERVICE_ROOT.parent
site.addsitedir(str(SERVICE_ROOT / ".venv" / "Lib" / "site-packages"))
sys.path.insert(0, str(SERVICE_ROOT))

from app.observability.metrics import (  # noqa: E402
    FORBIDDEN_LABEL_KEYS,
    METRIC_REGISTRY,
    MetricContractError,
    OperationalMetrics,
)


def test_required_domains_have_type_unit_and_owner() -> None:
    assert {item.domain for item in METRIC_REGISTRY.values()} == {
        "run", "tool", "context", "validation", "cost", "recovery"
    }
    assert len(METRIC_REGISTRY) == 12
    assert all(item.kind in {"counter", "gauge", "histogram"} for item in METRIC_REGISTRY.values())
    assert all(item.unit and item.owner for item in METRIC_REGISTRY.values())


def test_registry_has_no_high_cardinality_label_key() -> None:
    label_keys = {key for item in METRIC_REGISTRY.values() for key in item.label_keys}
    assert label_keys.isdisjoint(FORBIDDEN_LABEL_KEYS)
    assert label_keys == {"outcome", "tool_class", "validation_result", "recovery_reason"}


def test_record_accepts_only_complete_bounded_labels() -> None:
    metrics = OperationalMetrics()
    assert metrics.record(
        "gonow_tool_calls_total", 1, {"tool_class": "weather", "outcome": "success"}
    )
    with pytest.raises(MetricContractError):
        metrics.record("gonow_tool_calls_total", 1, {"tool_class": "weather"})
    with pytest.raises(MetricContractError):
        metrics.record(
            "gonow_tool_calls_total", 1, {"tool_class": "user-selected-tool", "outcome": "success"}
        )


@pytest.mark.parametrize("label", ["run_id", "tenant_id", "user_id", "behavior_digest"])
def test_high_cardinality_label_is_rejected(label: str) -> None:
    with pytest.raises(MetricContractError):
        OperationalMetrics().record("gonow_context_tokens", 100, {label: "synthetic"})


def test_disable_noncritical_preserves_critical_metrics() -> None:
    metrics = OperationalMetrics()
    metrics.disable_noncritical()
    assert metrics.record("gonow_context_tokens", 120) is False
    assert metrics.record("gonow_model_cost_usd_total", 0.04) is True
    assert set(metrics.snapshot()) == {"gonow_model_cost_usd_total"}


def test_dashboard_references_every_required_metric_with_matching_contract() -> None:
    dashboard_path = REPOSITORY_ROOT / "ops" / "dashboards" / "agent-operations.json"
    dashboard = json.loads(dashboard_path.read_text(encoding="utf-8"))
    panels = {panel["metric"]: panel for panel in dashboard["panels"]}
    assert set(panels) == set(METRIC_REGISTRY)
    for name, definition in METRIC_REGISTRY.items():
        assert panels[name]["type"] == definition.kind
        assert panels[name]["unit"] == definition.unit
        assert panels[name]["owner"] == definition.owner
    assert dashboard["forbidden_group_by"] == sorted(FORBIDDEN_LABEL_KEYS)


def test_dashboard_has_only_bounded_variables() -> None:
    dashboard = json.loads(
        (REPOSITORY_ROOT / "ops" / "dashboards" / "agent-operations.json").read_text(encoding="utf-8")
    )
    assert dashboard["variables"] == [
        {"name": "environment", "values": ["local", "staging", "production"]}
    ]
