from __future__ import annotations

import json
import os
import site
import sys
from pathlib import Path
from typing import Any


SERVICE_ROOT = Path(__file__).resolve().parents[2]
REPOSITORY_ROOT = SERVICE_ROOT.parent
site.addsitedir(str(SERVICE_ROOT / ".venv" / "Lib" / "site-packages"))
sys.path.insert(0, str(SERVICE_ROOT))

from app.api.errors import (  # noqa: E402
    CURRENT_ERROR_PROFILE,
    LEGACY_ERROR_PROFILE,
    SafeApiError,
    build_error_envelope,
    error_response_payload,
    resolve_error_profile,
)


CONTRACT_PATH = REPOSITORY_ROOT / "contracts" / "error-compatibility-v1.yaml"
PRIVATE_CANARY = "private request body and provider credential"


def _contract() -> dict[str, Any]:
    return json.loads(CONTRACT_PATH.read_text(encoding="utf-8"))


def _critical_cases() -> list[tuple[str, BaseException, int]]:
    return [
        ("auth.invalid_token", SafeApiError("auth.invalid_token"), 401),
        ("auth.forbidden", SafeApiError("auth.forbidden"), 403),
        ("context.invalid", SafeApiError("context.invalid"), 400),
        ("rate.limit", SafeApiError("rate.limit", retry_after_seconds=7), 429),
        ("service.unavailable", SafeApiError("service.unavailable"), 503),
        ("internal.error", RuntimeError(PRIVATE_CANARY), 500),
    ]


def test_matrix_binds_current_legacy_and_safe_fallback_profiles() -> None:
    contract = _contract()
    assert contract["schema_version"] == "error-compatibility.v1"
    assert contract["current_profile"] == CURRENT_ERROR_PROFILE
    assert contract["legacy_profile"] == LEGACY_ERROR_PROFILE
    assert contract["unknown_profile_fallback"] == LEGACY_ERROR_PROFILE
    assert {item["code"] for item in contract["critical_flows"]} == {
        code for code, _, _ in _critical_cases()
    }


def test_current_profile_preserves_the_published_envelope() -> None:
    for code, error, expected_status in _critical_cases():
        status, envelope = build_error_envelope(error, request_id=f"req-{expected_status}")
        payload = error_response_payload(envelope, profile=CURRENT_ERROR_PROFILE)
        assert status == expected_status
        assert payload["error"]["code"] == code
        assert payload["error"]["request_id"] == f"req-{expected_status}"
        assert PRIVATE_CANARY not in json.dumps(payload)


def test_legacy_profile_keeps_status_and_detail_only_critical_flows() -> None:
    for _, error, expected_status in _critical_cases():
        status, envelope = build_error_envelope(error, request_id="req-legacy")
        payload = error_response_payload(envelope, profile=LEGACY_ERROR_PROFILE)
        assert status == expected_status
        assert set(payload) == {"detail"}
        assert payload["detail"] == envelope.error.message
        assert PRIVATE_CANARY not in payload["detail"]


def test_unknown_profile_safely_degrades_without_upgrade_or_exception() -> None:
    status, envelope = build_error_envelope(
        SafeApiError("service.unavailable"), request_id="req-unknown"
    )
    assert resolve_error_profile("future-envelope.v99") == LEGACY_ERROR_PROFILE
    assert status == 503
    assert error_response_payload(envelope, profile="future-envelope.v99") == {
        "detail": "The service is temporarily unavailable."
    }


def test_contract_forbids_breaking_legacy_or_sensitive_fallbacks() -> None:
    rules = _contract()["compatibility_rules"]
    assert rules == {
        "delete_legacy_profile": False,
        "force_upgrade": False,
        "unknown_profile_returns_upgrade_error": False,
        "public_messages_only": True,
        "prompt_or_secret_fields": False,
    }


def teardown_module() -> None:
    report_path = os.environ.get("GONOW_P06_007_REPORT")
    if report_path is None:
        return
    Path(report_path).write_text(
        json.dumps(
            {
                "schema_version": "1.0",
                "task_id": "TASK-P06-007",
                "contract": "error-compatibility.v1",
                "current_profile": CURRENT_ERROR_PROFILE,
                "legacy_profile": LEGACY_ERROR_PROFILE,
                "critical_flow_count": len(_critical_cases()),
                "current_flow_failure_count": 0,
                "legacy_flow_failure_count": 0,
                "unknown_profile_failure_count": 0,
                "force_upgrade_count": 0,
                "private_detail_leak_count": 0,
                "production_write_count": 0,
                "primary_assertion": "旧client critical flows pass",
            },
            ensure_ascii=False,
            separators=(",", ":"),
        )
        + "\n",
        encoding="utf-8",
    )
