from __future__ import annotations

import site
import sys
from pathlib import Path

import pytest


SERVICE_ROOT = Path(__file__).resolve().parents[3]
site.addsitedir(str(SERVICE_ROOT / ".venv" / "Lib" / "site-packages"))
sys.path.insert(0, str(SERVICE_ROOT))

from app.tools.registry import StaticToolRegistry, ToolContractError  # noqa: E402


def test_15_tool_registry_s_resolves_versioned_approved_tool() -> None:
    spec = StaticToolRegistry().resolve("poi.search")
    assert spec.version == "1.0.0" and spec.read_only


def test_15_tool_registry_i_returns_safe_unknown_contract() -> None:
    with pytest.raises(ToolContractError) as failure:
        StaticToolRegistry().resolve("unknown")
    assert failure.value.safe_json() == {"error": {"code": "tool.unknown"}}


@pytest.mark.parametrize("name", ("sql.query", "url.fetch", "file.read", "shell.run", "exec"))
def test_15_tool_registry_i_rejects_forbidden_names_without_fallback(name: str) -> None:
    with pytest.raises(ToolContractError, match="tool.unknown"):
        StaticToolRegistry().resolve(name)


def test_15_tool_registry_d_catalog_unavailable_fails_closed() -> None:
    with pytest.raises(ToolContractError, match="tool.unknown"):
        StaticToolRegistry(available=False).resolve("poi.search")
