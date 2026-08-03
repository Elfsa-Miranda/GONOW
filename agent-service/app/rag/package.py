"""Canonical, content-addressed Knowledge Package manifests."""

from __future__ import annotations

import hashlib
import re
import uuid
from dataclasses import dataclass
from typing import Any

from app.runtime.behavior_manifest import BehaviorManifestError, canonicalize_jcs


COMPONENTS = (
    "tokenizer",
    "embedding",
    "dictionary",
    "fusion",
    "reranker",
    "citations",
    "eval",
    "rollback",
)
TOP_LEVEL_FIELDS = frozenset(
    {
        "schema_version",
        "tenant_id",
        "package_key",
        "package_version",
        "manifest",
        "components",
    }
)
TENANT_PATTERN = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.:-]{0,127}$")
PACKAGE_KEY_PATTERN = re.compile(r"^[a-z][a-z0-9_.-]{0,126}$")
VERSION_PATTERN = re.compile(r"^[0-9]+\.[0-9]+\.[0-9]+$")
DIGEST_PATTERN = re.compile(r"^[0-9a-f]{64}$")
FORBIDDEN_FIELDS = frozenset(
    {
        "api_key",
        "content",
        "credential",
        "prompt",
        "reasoning",
        "response",
        "secret",
        "text_content",
        "token",
    }
)


class KnowledgePackageError(ValueError):
    def __init__(self, code: str = "knowledge.package_invalid") -> None:
        self.code = code
        super().__init__(code)


@dataclass(frozen=True, slots=True)
class KnowledgePackageDigest:
    normalized: dict[str, Any]
    canonical_utf8: bytes
    sha256: str


def _fail() -> None:
    raise KnowledgePackageError()


def _reject_sensitive_fields(value: Any) -> None:
    if isinstance(value, dict):
        if any(str(key).lower() in FORBIDDEN_FIELDS for key in value):
            _fail()
        for nested in value.values():
            _reject_sensitive_fields(nested)
    elif isinstance(value, list):
        for nested in value:
            _reject_sensitive_fields(nested)


def normalize_knowledge_package(manifest: dict[str, Any]) -> dict[str, Any]:
    if not isinstance(manifest, dict) or set(manifest) != TOP_LEVEL_FIELDS:
        _fail()
    tenant_id = manifest.get("tenant_id")
    package_key = manifest.get("package_key")
    package_version = manifest.get("package_version")
    knowledge_manifest = manifest.get("manifest")
    components = manifest.get("components")
    if (
        manifest.get("schema_version") != "1.0"
        or not isinstance(tenant_id, str)
        or TENANT_PATTERN.fullmatch(tenant_id) is None
        or not isinstance(package_key, str)
        or PACKAGE_KEY_PATTERN.fullmatch(package_key) is None
        or not isinstance(package_version, str)
        or VERSION_PATTERN.fullmatch(package_version) is None
        or not isinstance(knowledge_manifest, dict)
        or set(knowledge_manifest) != {"manifest_id", "manifest_digest"}
        or not isinstance(components, dict)
        or set(components) != set(COMPONENTS)
    ):
        _fail()
    manifest_id = knowledge_manifest.get("manifest_id")
    manifest_digest = knowledge_manifest.get("manifest_digest")
    try:
        parsed_manifest_id = uuid.UUID(str(manifest_id))
    except (ValueError, TypeError, AttributeError) as error:
        raise KnowledgePackageError() from error
    if (
        str(parsed_manifest_id) != manifest_id
        or not isinstance(manifest_digest, str)
        or DIGEST_PATTERN.fullmatch(manifest_digest) is None
    ):
        _fail()

    normalized_components: dict[str, dict[str, str]] = {}
    for component_name in COMPONENTS:
        component = components[component_name]
        if not isinstance(component, dict) or set(component) != {"artifact_ref", "sha256"}:
            _fail()
        artifact_ref = component.get("artifact_ref")
        digest = component.get("sha256")
        if (
            not isinstance(artifact_ref, str)
            or not isinstance(digest, str)
            or DIGEST_PATTERN.fullmatch(digest) is None
            or artifact_ref != f"{component_name}://sha256/{digest}"
        ):
            _fail()
        normalized_components[component_name] = {
            "artifact_ref": artifact_ref,
            "sha256": digest,
        }

    _reject_sensitive_fields(manifest)
    return {
        "schema_version": "1.0",
        "tenant_id": tenant_id,
        "package_key": package_key,
        "package_version": package_version,
        "manifest": {
            "manifest_id": str(parsed_manifest_id),
            "manifest_digest": manifest_digest,
        },
        "components": normalized_components,
    }


def digest_knowledge_package(manifest: dict[str, Any]) -> KnowledgePackageDigest:
    normalized = normalize_knowledge_package(manifest)
    try:
        canonical = canonicalize_jcs(normalized)
    except BehaviorManifestError as error:
        raise KnowledgePackageError() from error
    return KnowledgePackageDigest(
        normalized=normalized,
        canonical_utf8=canonical,
        sha256=hashlib.sha256(canonical).hexdigest(),
    )
