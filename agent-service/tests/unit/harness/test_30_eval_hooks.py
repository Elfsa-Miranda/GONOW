from __future__ import annotations

import copy
import site
import sys
from pathlib import Path

import pytest


SERVICE_ROOT = Path(__file__).resolve().parents[3]
site.addsitedir(str(SERVICE_ROOT / ".venv" / "Lib" / "site-packages"))
sys.path.insert(0, str(SERVICE_ROOT))
sys.path.insert(0, str(SERVICE_ROOT / "tests" / "eval"))

from test_e0_parity import (  # noqa: E402
    E0ContractDrift,
    MANIFEST_PATH,
    _security_counts,
    run_e0_evaluation,
    verify_frozen_contract,
)


def test_30_eval_hooks_s_runs_both_paths_for_every_frozen_case() -> None:
    report = run_e0_evaluation()
    assert report["case_counts"]["dataset"] == 40
    assert report["case_counts"]["total_results"] == 80
    assert report["parity"]["compared_case_count"] == 40


def test_30_eval_hooks_s_records_quality_latency_and_cost_denominators() -> None:
    report = run_e0_evaluation()
    assert report["quality"]["threshold_failure_count"] == 0
    assert all(row["sample_count"] == 40 for row in report["latency"].values())
    assert report["cost"]["total_cost_usd"] == 0


def test_30_eval_hooks_i_rejects_a_changed_frozen_dataset_digest() -> None:
    manifest = __import__("json").loads(MANIFEST_PATH.read_text("utf-8"))
    manifest["dataset_sha256"] = "f" * 64
    with pytest.raises(E0ContractDrift, match="dataset_sha256"):
        verify_frozen_contract(manifest_override=manifest)


def test_30_eval_hooks_i_detects_a_missing_audit_receipt() -> None:
    report = run_e0_evaluation()
    changed = copy.deepcopy(report["case_results"])
    changed[0]["audit_receipt_id"] = ""
    assert _security_counts(changed)["missing_audit_receipt_count"] == 1


def test_30_eval_hooks_d_semantic_replay_is_deterministic() -> None:
    first = run_e0_evaluation()
    second = run_e0_evaluation()
    assert first["parity"]["semantic_results_sha256"] == second["parity"]["semantic_results_sha256"]


def test_30_eval_hooks_d_keeps_formal_and_production_claims_closed() -> None:
    report = run_e0_evaluation()
    assert report["formal_approval_status"] == "pending_external"
    assert report["production_validation"] is False
    assert report["production_write_count"] == 0
