from __future__ import annotations

import json
import site
import subprocess
import sys
from pathlib import Path

import pytest


SERVICE_ROOT = Path(__file__).resolve().parents[2]
REPO_ROOT = SERVICE_ROOT.parent
site.addsitedir(str(SERVICE_ROOT / ".venv" / "Lib" / "site-packages"))
sys.path.insert(0, str(SERVICE_ROOT))
QUALITY_GATE = Path(__file__).with_name("test_quality_gate.py")


@pytest.mark.parametrize("mode", ["format", "lint", "type", "secret", "clock-contract", "licenses", "workflow"])
def test_mandatory_ci_gate_is_clean(mode: str, tmp_path: Path) -> None:
    output = tmp_path / f"{mode}.json"
    completed = subprocess.run(
        [sys.executable, str(QUALITY_GATE), "--mode", mode, "--repo-root", str(REPO_ROOT), "--output", str(output)],
        check=False,
        capture_output=True,
        text=True,
    )
    report = json.loads(output.read_text(encoding="utf-8"))
    assert completed.returncode == 0, report
    assert report["passed"] is True
    assert report["failure_count"] == 0


def test_ci_wrapper_has_no_mandatory_skip_switch() -> None:
    wrapper = (SERVICE_ROOT / "scripts" / "ci.ps1").read_text(encoding="utf-8").lower()
    assert "[switch]$skip" not in wrapper
    assert "-skip" not in wrapper
    assert "--skip" not in wrapper
    assert "continue-on-error" not in wrapper


def test_deployment_clock_gate_fails_closed_on_missing_measurement() -> None:
    wrapper = (SERVICE_ROOT / "scripts" / "ci.ps1").read_text(encoding="utf-8")
    assert "$StatusExit-ne 0" in wrapper
    assert "$StripExit-ne 0" in wrapper
    assert "$null-eq$Offset" in wrapper
    assert "[Math]::Abs($Offset)-gt 5.0" in wrapper
