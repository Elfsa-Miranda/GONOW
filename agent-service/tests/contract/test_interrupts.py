from __future__ import annotations

from copy import deepcopy
from datetime import UTC, datetime
import json
import os
from pathlib import Path
import site
import sys
from typing import Any
from uuid import UUID

import pytest
from jsonschema import Draft202012Validator, FormatChecker, ValidationError as JsonSchemaError


SERVICE_ROOT = Path(__file__).resolve().parents[2]
REPOSITORY_ROOT = SERVICE_ROOT.parent
site.addsitedir(str(SERVICE_ROOT / ".venv" / "Lib" / "site-packages"))
sys.path.insert(0, str(SERVICE_ROOT))

from app.runtime.interrupts import (  # noqa: E402
    ApprovalInterrupt,
    InterruptContractError,
    MissingInfoInterrupt,
    RiskConfirmationInterrupt,
    interrupt_json,
    parse_interrupt,
)


SCHEMA_PATH = REPOSITORY_ROOT / "contracts" / "interrupt-v1.schema.json"
REPORT_ENV = "GONOW_P06_003_REPORT"
EXPECTED_REPORT = (
    REPOSITORY_ROOT
    / "docs"
    / "execution"
    / "evidence"
    / "phase-06"
    / "P06-003"
    / "interrupt-contract-report.json"
)
INTERRUPT_ID = "00000000-0000-4000-8000-000000000301"
RUN_ID = "00000000-0000-4000-8000-000000000302"
CREATED_AT = "2026-08-01T07:20:00Z"


def _fixtures() -> tuple[dict[str, Any], ...]:
    common = {
        "schema_version": "1.0",
        "interrupt_id": INTERRUPT_ID,
        "run_id": RUN_ID,
        "created_at": CREATED_AT,
    }
    return (
        {
            **common,
            "ui_message_key": "interrupt.missing_info.title",
            "kind": "missing_info",
            "requests": [
                {
                    "field_key": "trip.start_date",
                    "label_key": "interrupt.field.start_date",
                    "input_kind": "date",
                    "required": True,
                    "option_keys": [],
                },
                {
                    "field_key": "trip.pace",
                    "label_key": "interrupt.field.pace",
                    "input_kind": "choice",
                    "required": True,
                    "option_keys": ["pace.relaxed", "pace.active"],
                },
            ],
        },
        {
            **common,
            "interrupt_id": "00000000-0000-4000-8000-000000000303",
            "ui_message_key": "interrupt.risk.title",
            "kind": "risk_confirmation",
            "risk_code": "route.weather_disruption",
            "severity": "high",
            "evidence_refs": ["evidence://weather/advisory-42"],
            "explicit_confirmation_required": True,
        },
        {
            **common,
            "interrupt_id": "00000000-0000-4000-8000-000000000304",
            "ui_message_key": "interrupt.approval.title",
            "kind": "approval",
            "action_code": "candidate.adopt",
            "resource_ref": "candidate://run/302/version/1",
            "diff_ref": "diff://candidate/302/version/1",
            "explicit_approval_required": True,
            "audit_receipt_required": True,
        },
    )


def _validator() -> Draft202012Validator:
    schema = json.loads(SCHEMA_PATH.read_text(encoding="utf-8"))
    Draft202012Validator.check_schema(schema)
    return Draft202012Validator(schema, format_checker=FormatChecker())


def _write_report() -> None:
    requested = os.environ.get(REPORT_ENV, "").strip()
    if not requested:
        return
    target = Path(requested).resolve()
    assert target == EXPECTED_REPORT.resolve()
    target.parent.mkdir(parents=True, exist_ok=True)
    payload = {
        "schema_version": "1.0",
        "task_id": "TASK-P06-003",
        "supported_versions": ["1.0"],
        "interrupt_kinds": ["missing_info", "risk_confirmation", "approval"],
        "positive_fixture_count": 3,
        "negative_fixture_count": 5,
        "schema_validation_failures": 0,
        "unknown_version_error": "schema.unsupported_version",
        "unknown_version_write_count": 0,
        "prompt_field_accept_count": 0,
        "automatic_approval_accept_count": 0,
        "production_write_count": 0,
    }
    temporary = target.with_suffix(".json.tmp")
    temporary.write_text(
        json.dumps(payload, sort_keys=True, separators=(",", ":")), encoding="utf-8"
    )
    temporary.replace(target)


def test_v1_positive_fixtures_match_json_schema_and_typed_models() -> None:
    validator = _validator()
    expected_types = (MissingInfoInterrupt, RiskConfirmationInterrupt, ApprovalInterrupt)
    for payload, expected_type in zip(_fixtures(), expected_types, strict=True):
        validator.validate(payload)
        parsed = parse_interrupt(payload)
        assert isinstance(parsed, expected_type)
        assert json.loads(interrupt_json(parsed)) == payload
    _write_report()


@pytest.mark.parametrize(
    ("fixture_index", "mutation"),
    (
        (0, {"requests": []}),
        (1, {"explicit_confirmation_required": False}),
        (2, {"audit_receipt_required": False}),
    ),
)
def test_each_interrupt_kind_has_a_negative_fixture(
    fixture_index: int, mutation: dict[str, Any]
) -> None:
    payload = deepcopy(_fixtures()[fixture_index])
    payload.update(mutation)
    with pytest.raises(JsonSchemaError):
        _validator().validate(payload)
    with pytest.raises(InterruptContractError, match="interrupt.invalid"):
        parse_interrupt(payload)


def test_choice_and_non_choice_option_rules_fail_closed() -> None:
    choice_without_options = deepcopy(_fixtures()[0])
    choice_without_options["requests"][1]["option_keys"] = []
    with pytest.raises(InterruptContractError, match="interrupt.invalid"):
        parse_interrupt(choice_without_options)

    date_with_options = deepcopy(_fixtures()[0])
    date_with_options["requests"][0]["option_keys"] = ["date.tomorrow"]
    with pytest.raises(InterruptContractError, match="interrupt.invalid"):
        parse_interrupt(date_with_options)


def test_unknown_version_is_rejected_before_any_write() -> None:
    writes: list[object] = []

    def persist(raw: dict[str, Any]) -> None:
        parsed = parse_interrupt(raw)
        writes.append(parsed)

    payload = deepcopy(_fixtures()[0])
    payload["schema_version"] = "2.0"
    with pytest.raises(InterruptContractError, match="schema.unsupported_version") as error:
        persist(payload)
    assert error.value.code == "schema.unsupported_version"
    assert writes == []


@pytest.mark.parametrize("forbidden_field", ("prompt", "reasoning", "auto_approved"))
def test_opaque_prompt_reasoning_and_automatic_approval_are_forbidden(
    forbidden_field: str,
) -> None:
    payload = deepcopy(_fixtures()[2])
    payload[forbidden_field] = "forbidden"
    with pytest.raises(JsonSchemaError):
        _validator().validate(payload)
    with pytest.raises(InterruptContractError, match="interrupt.invalid"):
        parse_interrupt(payload)


def test_timestamp_requires_timezone_and_ids_remain_typed() -> None:
    parsed = parse_interrupt(_fixtures()[0])
    assert parsed.created_at == datetime(2026, 8, 1, 7, 20, tzinfo=UTC)
    assert parsed.interrupt_id == UUID(INTERRUPT_ID)
    payload = deepcopy(_fixtures()[0])
    payload["created_at"] = "2026-08-01T07:20:00"
    with pytest.raises(InterruptContractError, match="interrupt.invalid"):
        parse_interrupt(payload)
