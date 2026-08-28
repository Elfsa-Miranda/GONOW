from __future__ import annotations

import site
import sys
from pathlib import Path

import pytest
from pydantic import BaseModel, ConfigDict


SERVICE_ROOT = Path(__file__).resolve().parents[3]
site.addsitedir(str(SERVICE_ROOT / ".venv" / "Lib" / "site-packages"))
sys.path.insert(0, str(SERVICE_ROOT))

from app.validation.schema_guard import OutputSchemaError, OutputSchemaGuard  # noqa: E402


class _Output(BaseModel):
    model_config = ConfigDict(extra="forbid")
    value: int


def test_21_output_schema_guard_s_accepts_typed_output() -> None:
    assert OutputSchemaGuard(_Output).validate({"value": 1}).value == 1


def test_21_output_schema_guard_i_repairs_invalid_output_locally() -> None:
    result = OutputSchemaGuard(_Output).validate(
        {"value": "bad"}, repair=lambda value, round_number, issues: {"value": 2}
    )
    assert result.value == 2


def test_21_output_schema_guard_i_stops_no_progress() -> None:
    with pytest.raises(OutputSchemaError, match="output.schema_invalid"):
        OutputSchemaGuard(_Output).validate(
            {"value": "bad"}, repair=lambda value, round_number, issues: value
        )


def test_21_output_schema_guard_d_schema_unavailable_fails_closed() -> None:
    with pytest.raises(OutputSchemaError, match="output.schema_invalid"):
        OutputSchemaGuard(None).validate({"value": 1})
