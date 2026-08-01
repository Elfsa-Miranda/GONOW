"""Resolve certified Behavior releases and freeze complete manifests for new Runs."""

from __future__ import annotations

import json
from dataclasses import dataclass
from typing import Protocol
from uuid import UUID

from app.persistence.repositories.behavior import ResolvedBehaviorRelease
from app.runtime.behavior_manifest import (
    BehaviorManifestError,
    digest_behavior_manifest,
)


class BehaviorPackageError(ValueError):
    def __init__(self, code: str = "behavior.not_qualified") -> None:
        self.code = code
        super().__init__(code)


class BehaviorReleaseResolver(Protocol):
    def resolve_deployed_release(
        self,
        *,
        behavior_key: str,
        environment: str,
    ) -> ResolvedBehaviorRelease: ...


class BehaviorManifestStore(Protocol):
    def load(self, package_digest: str) -> dict[str, object]: ...


@dataclass(frozen=True, slots=True)
class RunBehaviorPin:
    release_id: UUID
    behavior_digest: str
    release_version: str
    canonical_manifest: bytes
    audit_receipt_id: str

    def manifest_copy(self) -> dict[str, object]:
        value = json.loads(self.canonical_manifest.decode("utf-8"))
        if not isinstance(value, dict):
            raise BehaviorPackageError()
        return value


class BehaviorPackageResolver:
    def __init__(
        self,
        *,
        releases: BehaviorReleaseResolver,
        manifests: BehaviorManifestStore,
    ) -> None:
        self._releases = releases
        self._manifests = manifests

    def pin_for_new_run(
        self,
        *,
        behavior_key: str,
        environment: str,
    ) -> RunBehaviorPin:
        try:
            release = self._releases.resolve_deployed_release(
                behavior_key=behavior_key,
                environment=environment,
            )
            manifest = self._manifests.load(release.package_digest)
            digest = digest_behavior_manifest(manifest)
        except (BehaviorManifestError, KeyError, RuntimeError, TypeError, ValueError) as error:
            raise BehaviorPackageError() from error
        if (
            digest.sha256 != release.package_digest
            or digest.normalized["behavior_key"] != release.behavior_key
            or digest.normalized["release_version"] != release.release_version
            or not release.audit_receipt_id
        ):
            raise BehaviorPackageError()
        return RunBehaviorPin(
            release_id=release.release_id,
            behavior_digest=digest.sha256,
            release_version=release.release_version,
            canonical_manifest=digest.canonical_utf8,
            audit_receipt_id=release.audit_receipt_id,
        )
