from __future__ import annotations

import site
import sys
from pathlib import Path

import pytest


SERVICE_ROOT = Path(__file__).resolve().parents[3]
REPO_ROOT = SERVICE_ROOT.parent
site.addsitedir(str(SERVICE_ROOT / ".venv" / "Lib" / "site-packages"))
sys.path.insert(0, str(SERVICE_ROOT))

from app.api.routes.contracts import (  # noqa: E402
    SchemaDigestMismatch,
    SchemaRegistry,
    SchemaRegistryUnavailable,
    SchemaUnsupported,
)


SPEC_PATH = REPO_ROOT / "contracts" / "openapi" / "agent-api.yaml"


def test_33_schema_registry_s_supported_version_resolves_codec() -> None:
    codec = SchemaRegistry(SPEC_PATH).resolve("agent-api", 1)
    encoded = codec.encode({"version": "1.0.0", "ready": True})
    assert codec.decode(encoded) == {"ready": True, "version": "1.0.0"}


def test_33_schema_registry_i_unknown_major_is_unsupported() -> None:
    with pytest.raises(SchemaUnsupported, match="schema.unsupported"):
        SchemaRegistry(SPEC_PATH).resolve("agent-api", 2)


def test_33_schema_registry_d_generated_digest_mismatch_is_rejected(tmp_path: Path) -> None:
    changed = tmp_path / "agent-api.yaml"
    changed.write_bytes(SPEC_PATH.read_bytes() + b"\n")
    with pytest.raises(SchemaDigestMismatch, match="schema.digest_mismatch"):
        SchemaRegistry(changed).resolve("agent-api", 1)


def test_33_schema_registry_d_unavailable_registry_fails_closed() -> None:
    registry = SchemaRegistry(SPEC_PATH)
    registry.available = False
    with pytest.raises(SchemaRegistryUnavailable, match="service.unavailable"):
        registry.resolve("agent-api", 1)
