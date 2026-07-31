from __future__ import annotations

import site
import sys
from pathlib import Path

import pytest


SERVICE_ROOT = Path(__file__).resolve().parents[3]
site.addsitedir(str(SERVICE_ROOT / ".venv" / "Lib" / "site-packages"))
sys.path.insert(0, str(SERVICE_ROOT))

from app.observability.logging import PiiRedactor, PrivacyRedactionFailed  # noqa: E402


def test_27_pii_redactor_s_synthetic_pii_is_replaced_without_plaintext() -> None:
    canary = "phase.two@example.invalid"
    result = PiiRedactor().redact({"contact": canary})
    assert canary not in repr(result.value)
    assert result.tags == ("email",)


def test_27_pii_redactor_s_clean_payload_is_not_damaged() -> None:
    payload = {"event": "run.started", "count": 3, "ready": True}
    assert PiiRedactor().redact(payload).value == payload


def test_27_pii_redactor_i_failure_prevents_export() -> None:
    exported: list[object] = []
    with pytest.raises(PrivacyRedactionFailed):
        exported.append(PiiRedactor().redact({"unsafe": object()}).value)
    assert exported == []


def test_27_pii_redactor_d_opaque_reasoning_is_not_recorded_or_rewritten() -> None:
    result = PiiRedactor().redact({"event": "run.completed", "reasoning": object()})
    assert result.value == {"event": "run.completed"}
    assert result.tags == ("opaque_content_omitted",)
