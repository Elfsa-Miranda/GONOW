from __future__ import annotations

import hashlib
import json
import site
import sys
from pathlib import Path


SERVICE_ROOT = Path(__file__).resolve().parents[2]
REPO_ROOT = SERVICE_ROOT.parent
site.addsitedir(str(SERVICE_ROOT / ".venv" / "Lib" / "site-packages"))
sys.path.insert(0, str(SERVICE_ROOT))

from app.api.routes.contracts import EXPECTED_OPENAPI_SHA256, PUBLIC_ERROR_CODES, SchemaRegistry  # noqa: E402
from app.api.main import create_app  # noqa: E402


SPEC_PATH = REPO_ROOT / "contracts" / "openapi" / "agent-api.yaml"


def _specification() -> dict[str, object]:
    return json.loads(SPEC_PATH.read_text(encoding="utf-8"))


def test_openapi_lint_errors_are_zero() -> None:
    specification = _specification()
    assert specification["openapi"] == "3.1.0"
    assert specification["info"]["version"] == "1.1.1"
    assert specification["x-contract-name"] == "agent-api"
    operation_ids = [operation["operationId"] for path in specification["paths"].values() for operation in path.values()]
    assert len(operation_ids) == len(set(operation_ids))


def test_phase_11_documentation_metadata_preserves_v1_wire_contract() -> None:
    specification = _specification()
    assert specification["x-baseline-status"] == "phase-11-single-agent-rag-local-provisional"
    assert specification["x-phase-11-rag"]["contract_change"] == "documentation_only"
    assert specification["x-phase-11-rag"]["production_enabled"] is False
    assert "/v1/contracts/{name}/{major}" in specification["paths"]
    assert {
        "/v1/runs",
        "/v1/runs/{run_id}/candidate",
        "/v1/runs/{run_id}/events",
        "/v1/runs/{run_id}/resume",
        "/v1/runs/{run_id}/cancel",
    } <= set(specification["paths"])


def test_run_start_is_typed_idempotent_and_additive() -> None:
    specification = _specification()
    operation = specification["paths"]["/v1/runs"]["post"]
    assert operation["operationId"] == "startRun"
    assert operation["parameters"] == [
        {
            "name": "Idempotency-Key",
            "in": "header",
            "required": True,
            "schema": {"type": "string", "minLength": 16, "maxLength": 128},
        }
    ]
    assert operation["requestBody"]["content"]["application/json"]["schema"] == {
        "$ref": "#/components/schemas/RunStartRequest"
    }
    assert operation["responses"]["202"]["content"]["application/json"]["schema"] == {
        "$ref": "#/components/schemas/RunStartResponse"
    }


def test_candidate_read_contract_is_owner_scoped_and_strict() -> None:
    specification = _specification()
    operation = specification["paths"]["/v1/runs/{run_id}/candidate"]["get"]
    assert operation["operationId"] == "getRunCandidate"
    assert set(operation["responses"]) == {"200", "401", "403"}
    assert operation["responses"]["200"]["content"]["application/json"]["schema"] == {
        "$ref": "#/components/schemas/ItineraryCandidate"
    }
    assert specification["components"]["schemas"]["ItineraryCandidate"][
        "additionalProperties"
    ] is False


def test_error_code_corpus_diff_is_zero() -> None:
    specification = _specification()
    schema_codes = tuple(specification["components"]["schemas"]["PublicError"]["properties"]["code"]["enum"])
    assert tuple(specification["x-error-codes"]) == PUBLIC_ERROR_CODES
    assert schema_codes == PUBLIC_ERROR_CODES


def test_error_examples_use_only_corpus_codes() -> None:
    specification = _specification()
    responses = specification["components"]["responses"]
    codes = {
        response["content"]["application/json"]["example"]["error"]["code"]
        for response in responses.values()
    }
    assert codes <= set(PUBLIC_ERROR_CODES)
    assert {"auth.invalid_token", "schema.unsupported", "service.unavailable"} <= codes


def test_public_schemas_forbid_unversioned_extra_fields() -> None:
    schemas = _specification()["components"]["schemas"]
    assert all(schema.get("additionalProperties") is False for schema in schemas.values())


def test_contract_does_not_expose_internal_fields() -> None:
    rendered = SPEC_PATH.read_text(encoding="utf-8").lower()
    for forbidden in ("stack", "reasoning", "chain_of_thought", "database_host", "jwks_url", "api_key"):
        assert forbidden not in rendered


def test_spec_sha256_is_exact_and_64_characters() -> None:
    digest = hashlib.sha256(SPEC_PATH.read_bytes()).hexdigest()
    assert len(digest) == 64
    assert digest == EXPECTED_OPENAPI_SHA256


def test_registry_descriptor_binds_same_digest() -> None:
    descriptor = SchemaRegistry(SPEC_PATH).resolve("agent-api", 1).descriptor
    assert descriptor.spec_sha256 == EXPECTED_OPENAPI_SHA256


def test_executable_route_table_matches_every_openapi_operation() -> None:
    specification = _specification()
    contract_operations = {
        (method.upper(), path)
        for path, path_item in specification["paths"].items()
        for method in path_item
    }
    executable_operations = {
        (method, route.path)
        for route in create_app().routes
        if route.path not in {"/openapi.json", "/docs", "/docs/oauth2-redirect", "/redoc"}
        for method in (route.methods or set())
        if method not in {"HEAD", "OPTIONS"}
    }
    assert executable_operations == contract_operations
