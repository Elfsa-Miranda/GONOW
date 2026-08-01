from __future__ import annotations

import json
import site
import sys
from pathlib import Path


SERVICE_ROOT = Path(__file__).resolve().parents[2]
REPO_ROOT = SERVICE_ROOT.parent
site.addsitedir(str(SERVICE_ROOT / ".venv" / "Lib" / "site-packages"))
sys.path.insert(0, str(SERVICE_ROOT))

from app.api.routes.contracts import SchemaRegistry  # noqa: E402


FIXTURE_PATH = REPO_ROOT / "test" / "fixtures" / "compatibility" / "client-service-matrix-v1.json"
SPEC_PATH = REPO_ROOT / "contracts" / "openapi" / "agent-api.yaml"
PHASE_MANIFEST_PATH = REPO_ROOT / "docs" / "execution" / "evidence" / "phase-09" / "phase-runtime-manifest.json"


def _fixture() -> dict[str, object]:
    return json.loads(FIXTURE_PATH.read_text(encoding="utf-8"))


def test_build_versions_are_source_bound_and_complete() -> None:
    fixture = _fixture()
    versions = {item["version_id"]: item for item in fixture["versions"]}
    manifest = json.loads(PHASE_MANIFEST_PATH.read_text(encoding="utf-8"))

    assert fixture["workflow"] == "build versions -> matrix -> failures -> report"
    assert set(versions) == {"old_app", "new_app", "old_service", "new_service"}
    assert versions["old_app"]["source_reference"] == "phase_base_oid"
    assert versions["old_service"]["source_reference"] == "phase_base_oid"
    assert len(manifest["phase_base_oid"]) == 40


def test_matrix_contains_each_client_service_pair_once() -> None:
    matrix = _fixture()["matrix"]
    pairs = {(case["client_id"], case["service_id"]) for case in matrix}

    assert len(matrix) == 4
    assert pairs == {
        ("old_app", "old_service"),
        ("old_app", "new_service"),
        ("new_app", "old_service"),
        ("new_app", "new_service"),
    }
    assert {case["expected_result"] for case in matrix} == {"passed"}


def test_old_and_new_service_descriptors_match_the_live_v1_registry() -> None:
    fixture = _fixture()
    actual = SchemaRegistry(SPEC_PATH).resolve("agent-api", 1).descriptor.model_dump()

    assert fixture["services"]["old_service"]["descriptor"] == actual
    assert fixture["services"]["new_service"]["descriptor"] == actual
    assert fixture["services"]["old_service"]["candidate_only"] is True
    assert fixture["services"]["new_service"]["candidate_only"] is True


def test_route_expectations_preserve_old_app_and_enable_new_app() -> None:
    matrix = _fixture()["matrix"]
    old_routes = {case["expected_route"] for case in matrix if case["client_id"] == "old_app"}
    new_routes = {case["expected_route"] for case in matrix if case["client_id"] == "new_app"}

    assert old_routes == {"legacy"}
    assert new_routes == {"agent"}


def test_failures_are_safe_and_never_force_upgrade_or_delete_adapter() -> None:
    fixture = _fixture()
    failure_cases = {case["case_id"]: case for case in fixture["failure_cases"]}

    assert set(failure_cases) == {"digest_mismatch", "service_unavailable", "generation_mismatch"}
    assert {case["expected_route"] for case in failure_cases.values()} == {"legacy"}
    assert fixture["forced_upgrade_count"] == 0
    assert fixture["adapter_delete_count"] == 0
    assert fixture["contract_change"] is False
    assert fixture["production_write_count"] == 0
