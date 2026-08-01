from __future__ import annotations

import hashlib
import json
import os
import site
import sys
from pathlib import Path

import pytest


SERVICE_ROOT = Path(__file__).resolve().parents[2]
REPOSITORY_ROOT = SERVICE_ROOT.parent
site.addsitedir(str(SERVICE_ROOT / ".venv" / "Lib" / "site-packages"))
sys.path.insert(0, str(SERVICE_ROOT))

from app.harness import (  # noqa: E402
    HarnessCaseEvidence,
    HarnessMappingError,
    load_harness_catalog,
    parse_harness_catalog,
    validate_control_evidence,
)
from app.harness.catalog import OWNER_TASK_BY_CONTROL  # noqa: E402


CATALOG_PATH = REPOSITORY_ROOT / "docs/execution/schemas/harness-test-catalog.yaml"


def _write_report(payload: dict[str, object]) -> None:
    evidence_root = os.environ.get("GONOW_P04_003_EVIDENCE_DIR")
    if not evidence_root:
        return
    path = Path(evidence_root) / "harness-mapping-report.json"
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(".json.tmp")
    temporary.write_text(json.dumps(payload, sort_keys=True, separators=(",", ":")), "utf-8")
    temporary.replace(path)


def test_harness_catalog_maps_all_controls_without_mutation() -> None:
    before = CATALOG_PATH.read_bytes()
    catalog = load_harness_catalog(CATALOG_PATH, repository_root=REPOSITORY_ROOT)
    after = CATALOG_PATH.read_bytes()
    assert [control.id for control in catalog.controls] == list(range(1, 35))
    assert len(catalog.by_id) == len(catalog.by_test_file) == 34
    assert all(control.owner_task and control.failure_code for control in catalog.controls)
    assert catalog.control(13).owner_task == "TASK-P04-001"
    assert catalog.control_for_test(catalog.control(30).test_file).id == 30
    assert before == after
    _write_report(
        {
            "schema_version": "1.0",
            "task_id": "TASK-P04-003",
            "mapped_count": 34,
            "control_ids": [f"{control.id:02d}" for control in catalog.controls],
            "duplicate_id": 0,
            "missing_owner": 0,
            "missing_exact_test_path": 0,
            "missing_failure_contract": 0,
            "catalog_sha_before": hashlib.sha256(before).hexdigest(),
            "catalog_sha_after": hashlib.sha256(after).hexdigest(),
            "catalog_sha_changed": False,
            "catalog_implemented_control_ids": [
                control.id for control in catalog.controls if control.status == "implemented"
            ],
            "implemented_control_ids": [],
            "production_write_count": 0,
        }
    )


@pytest.mark.parametrize(
    "mutation",
    (
        lambda text: text.replace("- {id: 2,", "- {id: 1,", 1),
        lambda text: text.replace("status: implemented", "status: invented", 1),
        lambda text: text.replace(
            "test_file: agent-service/tests/unit/harness/test_01_request_context.py",
            "test_file: missing",
            1,
        ),
    ),
)
def test_harness_catalog_rejects_duplicate_illegal_or_missing_mapping(mutation) -> None:
    raw = mutation(CATALOG_PATH.read_text("utf-8")).encode("utf-8")
    with pytest.raises(HarnessMappingError):
        parse_harness_catalog(raw, repository_root=REPOSITORY_ROOT)


def test_harness_catalog_rejects_missing_owner_mapping() -> None:
    owners = dict(OWNER_TASK_BY_CONTROL)
    owners.pop(34)
    with pytest.raises(HarnessMappingError, match="harness.owner_or_failure_mapping_incomplete"):
        parse_harness_catalog(
            CATALOG_PATH.read_bytes(),
            repository_root=REPOSITORY_ROOT,
            owner_task_by_control=owners,
        )


def test_harness_catalog_rejects_fake_implemented_control() -> None:
    text = CATALOG_PATH.read_text("utf-8").replace(
        "test_file: agent-service/tests/unit/harness/test_01_request_context.py",
        "test_file: agent-service/tests/unit/harness/test_01_missing.py",
        1,
    )
    with pytest.raises(HarnessMappingError, match="harness.implemented_test_missing"):
        parse_harness_catalog(text.encode("utf-8"), repository_root=REPOSITORY_ROOT)


def test_harness_evidence_requires_sid_and_exact_junit_nodes() -> None:
    control = load_harness_catalog(CATALOG_PATH, repository_root=REPOSITORY_ROOT).control(13)
    cases = (
        HarnessCaseEvidence("state-s", "S", "valid delta", "node-s"),
        HarnessCaseEvidence("state-i", "I", "invalid delta", "node-i"),
        HarnessCaseEvidence("state-d", "D", "dependency closed", "node-d"),
        HarnessCaseEvidence("state-i-2", "I", "extra rejected", "node-i-2"),
    )
    validate_control_evidence(
        control,
        cases,
        executed_node_ids=("node-s", "node-i", "node-d", "node-i-2"),
    )
    with pytest.raises(HarnessMappingError, match="harness.evidence_invalid"):
        validate_control_evidence(
            control,
            tuple(case for case in cases if case.category != "D"),
            executed_node_ids=("node-s", "node-i", "node-i-2"),
        )
    with pytest.raises(HarnessMappingError, match="harness.evidence_invalid"):
        validate_control_evidence(control, cases, executed_node_ids=("node-s", "node-i"))
