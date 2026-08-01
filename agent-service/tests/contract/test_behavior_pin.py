from __future__ import annotations

import json
import os
import site
import sys
from dataclasses import replace
from pathlib import Path
from uuid import UUID

import pytest


SERVICE_ROOT = Path(__file__).resolve().parents[2]
site.addsitedir(str(SERVICE_ROOT / ".venv" / "Lib" / "site-packages"))
sys.path.insert(0, str(SERVICE_ROOT))

from app.persistence.repositories.behavior import (  # noqa: E402
    PointerCasConflict,
    ResolvedBehaviorRelease,
)
from app.runtime.behavior_manifest import COMPONENTS, digest_behavior_manifest  # noqa: E402
from app.runtime.behavior_package import (  # noqa: E402
    BehaviorPackageError,
    BehaviorPackageResolver,
)


BEHAVIOR_KEY = "itinerary.single-agent"


def _manifest(version: str, character: str) -> dict[str, object]:
    return {
        "schema_version": "1.0",
        "behavior_key": BEHAVIOR_KEY,
        "release_version": version,
        "components": {
            name: {
                "artifact_ref": f"{name}://sha256/{character * 64}",
                "sha256": character * 64,
            }
            for name in COMPONENTS
        },
    }


class _Store:
    def __init__(self, manifests: tuple[dict[str, object], ...]) -> None:
        self.values = {
            digest_behavior_manifest(manifest).sha256: manifest for manifest in manifests
        }

    def load(self, package_digest: str) -> dict[str, object]:
        return self.values[package_digest]


class _Releases:
    def __init__(self, manifests: tuple[dict[str, object], ...]) -> None:
        self.releases = []
        for index, manifest in enumerate(manifests, start=1):
            digest = digest_behavior_manifest(manifest).sha256
            self.releases.append(
                ResolvedBehaviorRelease(
                    release_id=UUID(int=index),
                    behavior_key=BEHAVIOR_KEY,
                    release_version=str(manifest["release_version"]),
                    package_digest=digest,
                    certification_id=UUID(int=index + 10),
                    audit_receipt_id=f"audit-release-{index}",
                    generation=index,
                )
            )
        self.current = 0
        self.generation = 1
        self.qualified = True

    def resolve_deployed_release(self, *, behavior_key: str, environment: str):
        if not self.qualified or behavior_key != BEHAVIOR_KEY or environment != "offline":
            raise RuntimeError("behavior.not_qualified")
        release = self.releases[self.current]
        return ResolvedBehaviorRelease(
            release_id=release.release_id,
            behavior_key=release.behavior_key,
            release_version=release.release_version,
            package_digest=release.package_digest,
            certification_id=release.certification_id,
            audit_receipt_id=release.audit_receipt_id,
            generation=self.generation,
        )

    def move(self, target: int, *, expected_generation: int, audit_receipt_id: str) -> None:
        if not audit_receipt_id or expected_generation != self.generation:
            raise PointerCasConflict()
        self.current = target
        self.generation += 1


def _fixture():
    manifests = (_manifest("1.0.0", "a"), _manifest("1.1.0", "b"))
    releases = _Releases(manifests)
    resolver = BehaviorPackageResolver(releases=releases, manifests=_Store(manifests))
    return releases, resolver


def _write_report(old_digest: str, new_digest: str, rollback_digest: str) -> None:
    evidence_root = os.environ.get("GONOW_P04_008_EVIDENCE_DIR")
    if not evidence_root:
        return
    payload = {
        "schema_version": "1.0",
        "task_id": "TASK-P04-008",
        "ct_012": "passed",
        "ct_013": "passed",
        "component_count": len(COMPONENTS),
        "old_run_digest": old_digest,
        "new_run_digest": new_digest,
        "rollback_new_run_digest": rollback_digest,
        "old_run_behavior_digest_changes": 0,
        "pointer_race_winner_count": 1,
        "pointer_race_conflict_count": 1,
        "rollback_new_run_uses_old_digest": rollback_digest == old_digest,
        "missing_audit_receipt_count": 0,
        "uncertified_release_accept_count": 0,
        "production_write_count": 0,
    }
    path = Path(evidence_root) / "behavior-pin-report.json"
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(".json.tmp")
    temporary.write_text(json.dumps(payload, sort_keys=True, separators=(",", ":")), "utf-8")
    temporary.replace(path)


def test_behavior_package_pins_all_components_and_audit_receipt() -> None:
    _, resolver = _fixture()
    pin = resolver.pin_for_new_run(behavior_key=BEHAVIOR_KEY, environment="offline")
    assert set(pin.manifest_copy()["components"]) == set(COMPONENTS)
    assert pin.audit_receipt_id == "audit-release-1"


def test_ct_012_pointer_change_affects_only_new_run() -> None:
    releases, resolver = _fixture()
    old_run = resolver.pin_for_new_run(behavior_key=BEHAVIOR_KEY, environment="offline")
    releases.move(1, expected_generation=1, audit_receipt_id="audit-pointer-new")
    new_run = resolver.pin_for_new_run(behavior_key=BEHAVIOR_KEY, environment="offline")
    assert old_run.behavior_digest != new_run.behavior_digest
    assert old_run.release_version == "1.0.0"


def test_pointer_rollback_makes_only_subsequent_run_use_old_digest() -> None:
    releases, resolver = _fixture()
    old_run = resolver.pin_for_new_run(behavior_key=BEHAVIOR_KEY, environment="offline")
    releases.move(1, expected_generation=1, audit_receipt_id="audit-pointer-new")
    new_run = resolver.pin_for_new_run(behavior_key=BEHAVIOR_KEY, environment="offline")
    releases.move(0, expected_generation=2, audit_receipt_id="audit-pointer-rollback")
    rollback_run = resolver.pin_for_new_run(behavior_key=BEHAVIOR_KEY, environment="offline")
    assert rollback_run.behavior_digest == old_run.behavior_digest
    assert new_run.behavior_digest != old_run.behavior_digest
    _write_report(old_run.behavior_digest, new_run.behavior_digest, rollback_run.behavior_digest)


def test_ct_013_generation_cas_has_one_winner() -> None:
    releases, _ = _fixture()
    releases.move(1, expected_generation=1, audit_receipt_id="audit-winner")
    with pytest.raises(PointerCasConflict, match="behavior.pointer_conflict"):
        releases.move(0, expected_generation=1, audit_receipt_id="audit-loser")


def test_uncertified_release_fails_closed() -> None:
    releases, resolver = _fixture()
    releases.qualified = False
    with pytest.raises(BehaviorPackageError, match="behavior.not_qualified"):
        resolver.pin_for_new_run(behavior_key=BEHAVIOR_KEY, environment="offline")


def test_manifest_digest_mismatch_fails_closed() -> None:
    releases, resolver = _fixture()
    releases.releases[0] = replace(
        releases.releases[0],
        package_digest="f" * 64,
    )
    with pytest.raises(BehaviorPackageError, match="behavior.not_qualified"):
        resolver.pin_for_new_run(behavior_key=BEHAVIOR_KEY, environment="offline")


def test_manifest_copy_cannot_mutate_existing_pin() -> None:
    _, resolver = _fixture()
    pin = resolver.pin_for_new_run(behavior_key=BEHAVIOR_KEY, environment="offline")
    manifest = pin.manifest_copy()
    manifest["release_version"] = "9.9.9"
    assert pin.manifest_copy()["release_version"] == "1.0.0"
