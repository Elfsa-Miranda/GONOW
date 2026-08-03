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
    assert "--maxfail" not in wrapper


def test_agent_workflow_provisions_database_before_mandatory_gates() -> None:
    workflow = (REPO_ROOT / ".github" / "workflows" / "agent-ci.yml").read_text(
        encoding="utf-8"
    )
    provisioner = (SERVICE_ROOT / "scripts" / "provision_ci_postgres.ps1").read_text(
        encoding="utf-8"
    )
    provision = workflow.index("Provision isolated PostgreSQL contract database")
    mandatory = workflow.index("Run every mandatory Agent gate")
    cleanup = workflow.index("Stop isolated PostgreSQL contract database")

    assert provision < mandatory < cleanup
    assert "provision_ci_postgres.ps1" in workflow
    assert "-Port 55432" in workflow
    assert '"--options=-p $Port -h 127.0.0.1"' in provisioner
    assert "--auth-host=trust" in provisioner
    assert "0.0.0.0" not in provisioner
    assert "CREATE ROLE gonow_migrator_test LOGIN NOSUPERUSER" in provisioner
    assert "CREATE ROLE gonow_bootstrap_admin LOGIN SUPERUSER" in provisioner
    assert "CREATE ROLE gonow_probe_tenant_a NOLOGIN NOSUPERUSER" in provisioner
    assert "REVOKE CONNECT ON DATABASE gonow_p03_test FROM PUBLIC" in provisioner
    assert "migrator role contract failed" in provisioner
    assert "probe role unexpectedly has CONNECT" in provisioner
    assert "PgvectorVersion = '0.8.1'" in provisioner
    assert "PgvectorCommit = '778dacf20c07caf904557a88705142631818d8cb'" in provisioner
    assert "Locked pgvector source commit mismatch" in provisioner
    assert "CREATE EXTENSION IF NOT EXISTS vector WITH SCHEMA public" in provisioner
    assert "CREATE EXTENSION IF NOT EXISTS btree_gin WITH SCHEMA public" in provisioner
    assert "pgvector version contract failed" in provisioner
    assert "pgvector-provisioning.json" in provisioner
    assert "if: ${{ always() }}" in workflow[cleanup:]


def test_deployment_clock_gate_fails_closed_on_missing_measurement() -> None:
    wrapper = (SERVICE_ROOT / "scripts" / "ci.ps1").read_text(encoding="utf-8")
    assert "$StatusExit-ne 0" in wrapper
    assert "$StripExit-ne 0" in wrapper
    assert "$null-eq$Offset" in wrapper
    assert "[Math]::Abs($Offset)-gt 5.0" in wrapper
