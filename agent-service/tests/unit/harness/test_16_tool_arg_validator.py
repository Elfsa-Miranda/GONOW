from __future__ import annotations

import site
import sys
from pathlib import Path

import pytest


SERVICE_ROOT = Path(__file__).resolve().parents[3]
site.addsitedir(str(SERVICE_ROOT / ".venv" / "Lib" / "site-packages"))
sys.path.insert(0, str(SERVICE_ROOT))

from app.tools.registry import (  # noqa: E402
    StaticToolRegistry,
    ToolArgValidator,
    ToolContractError,
)
from app.tools.spec import PoiSearchArgs  # noqa: E402


def _validator(*, available: bool = True) -> ToolArgValidator:
    return ToolArgValidator(StaticToolRegistry(), available=available)


def test_16_tool_arg_validator_s_returns_typed_canonical_hash() -> None:
    value = _validator().validate(
        "poi.search", {"keyword": "museum", "city_code": "SHA", "limit": 3}
    )
    assert isinstance(value.arguments, PoiSearchArgs)
    assert len(value.argument_sha256) == 64


def test_16_tool_arg_validator_i_rejects_identity_injection() -> None:
    with pytest.raises(ToolContractError, match="tool.invalid_args"):
        _validator().validate(
            "poi.search", {"keyword": "x", "city_code": "SHA", "tenant_id": "other"}
        )


@pytest.mark.parametrize("value", ("https://internal", "file:///tmp/x", "select x from y"))
def test_16_tool_arg_validator_i_rejects_url_file_or_sql_value(value: str) -> None:
    with pytest.raises(ToolContractError, match="tool.invalid_args"):
        _validator().validate("poi.search", {"keyword": value, "city_code": "SHA"})


def test_16_tool_arg_validator_i_malformed_input_has_stable_error() -> None:
    with pytest.raises(ToolContractError, match="tool.invalid_args"):
        _validator().validate("poi.search", ["not", "an", "object"])


def test_16_tool_arg_validator_d_schema_unavailable_fails_closed() -> None:
    with pytest.raises(ToolContractError, match="tool.invalid_args"):
        _validator(available=False).validate(
            "poi.search", {"keyword": "museum", "city_code": "SHA"}
        )
