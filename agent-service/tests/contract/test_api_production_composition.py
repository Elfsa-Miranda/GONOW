from __future__ import annotations

import hashlib
import json
from pathlib import Path
import site
import sys

import pytest


SERVICE_ROOT = Path(__file__).resolve().parents[2]
site.addsitedir(str(SERVICE_ROOT / ".venv" / "Lib" / "site-packages"))
sys.path.insert(0, str(SERVICE_ROOT))

from app.api.composition import (  # noqa: E402
    ApiCompositionError,
    ImmutableManifestFileStore,
    build_api_dependencies_from_environment,
)
from app.runtime.behavior_manifest import COMPONENTS, digest_behavior_manifest  # noqa: E402


REQUIRED_ENVIRONMENT = (
    "GONOW_DATABASE_URL",
    "GONOW_JWKS_URL",
    "GONOW_JWKS_ALLOWED_HOSTS",
    "GONOW_JWT_ISSUER",
    "GONOW_JWT_AUDIENCE",
    "GONOW_BEHAVIOR_MANIFEST_PATH",
    "GONOW_BEHAVIOR_MANIFEST_SHA256",
    "GONOW_BEHAVIOR_KEY",
    "GONOW_BEHAVIOR_ENVIRONMENT",
)


def _manifest() -> dict[str, object]:
    return {
        "schema_version": "1.0",
        "behavior_key": "itinerary.planning",
        "release_version": "1.0.0",
        "components": {
            name: {
                "artifact_ref": f"{name}://sha256/{index:064x}",
                "sha256": f"{index:064x}",
            }
            for index, name in enumerate(COMPONENTS, start=1)
        },
    }


def _valid_environment(monkeypatch: pytest.MonkeyPatch, manifest_path: Path) -> None:
    values = {
        "GONOW_DATABASE_URL": (
            "postgresql+pg8000://gonow_bootstrap_admin@127.0.0.1:55432/"
            "gonow_p03_test"
        ),
        "GONOW_JWKS_URL": "https://identity.test.invalid/.well-known/jwks.json",
        "GONOW_JWKS_ALLOWED_HOSTS": "identity.test.invalid",
        "GONOW_JWT_ISSUER": "https://identity.test.invalid",
        "GONOW_JWT_AUDIENCE": "gonow-agent",
        "GONOW_BEHAVIOR_MANIFEST_PATH": str(manifest_path.resolve()),
        "GONOW_BEHAVIOR_MANIFEST_SHA256": hashlib.sha256(
            manifest_path.read_bytes()
        ).hexdigest(),
        "GONOW_BEHAVIOR_KEY": "itinerary.planning",
        "GONOW_BEHAVIOR_ENVIRONMENT": "offline",
    }
    for name, value in values.items():
        monkeypatch.setenv(name, value)


def test_api_composition_fails_closed_when_required_inputs_are_missing(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    for name in REQUIRED_ENVIRONMENT:
        monkeypatch.delenv(name, raising=False)
    with pytest.raises(ApiCompositionError):
        build_api_dependencies_from_environment()


def test_api_composition_rejects_wildcard_jwks_hosts(
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
) -> None:
    path = tmp_path / "manifest.json"
    path.write_text(json.dumps(_manifest()), encoding="utf-8")
    _valid_environment(monkeypatch, path)
    monkeypatch.setenv("GONOW_JWKS_ALLOWED_HOSTS", "*")
    with pytest.raises(ApiCompositionError):
        build_api_dependencies_from_environment()


def test_manifest_store_detects_byte_tampering_before_pin(tmp_path: Path) -> None:
    manifest = _manifest()
    raw = json.dumps(manifest, separators=(",", ":"), sort_keys=True).encode("utf-8")
    path = (tmp_path / "manifest.json").resolve()
    path.write_bytes(raw)
    store = ImmutableManifestFileStore(path, hashlib.sha256(raw).hexdigest())
    digest = digest_behavior_manifest(manifest).sha256
    assert store.load(digest) == manifest

    path.write_bytes(raw + b"\n")
    with pytest.raises(ApiCompositionError):
        store.load(digest)


def test_api_composition_rejects_non_https_issuer(
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
) -> None:
    path = tmp_path / "manifest.json"
    path.write_text(json.dumps(_manifest()), encoding="utf-8")
    _valid_environment(monkeypatch, path)
    monkeypatch.setenv("GONOW_JWT_ISSUER", "http://identity.test.invalid")
    with pytest.raises(ApiCompositionError):
        build_api_dependencies_from_environment()
