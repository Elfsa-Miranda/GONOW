from __future__ import annotations

import json
import site
import sys
import threading
import uuid
from concurrent.futures import ThreadPoolExecutor
from dataclasses import replace
from pathlib import Path

import pytest


SERVICE_ROOT = Path(__file__).resolve().parents[2]
REPO_ROOT = SERVICE_ROOT.parent
site.addsitedir(str(SERVICE_ROOT / ".venv" / "Lib" / "site-packages"))
sys.path.insert(0, str(SERVICE_ROOT))

from app.persistence.repositories.knowledge_alias import (  # noqa: E402
    KnowledgeAliasAuthorizationDenied,
    KnowledgeAliasCasConflict,
    KnowledgeAliasContext,
    KnowledgeAliasNotFound,
    KnowledgeAliasNotGreen,
    KnowledgeAliasRecord,
    KnowledgeAliasRepository,
    KnowledgeCertificationRecord,
    KnowledgeGreenRecord,
    KnowledgePackageRecord,
)
from app.rag.package import COMPONENTS, digest_knowledge_package  # noqa: E402


TENANT = "tenant-release-test"
PACKAGE_KEY = "travel.primary"
ALIAS = "active"


class _AtomicStore:
    def __init__(self) -> None:
        self.packages: dict[uuid.UUID, KnowledgePackageRecord] = {}
        self.certifications: dict[uuid.UUID, KnowledgeCertificationRecord] = {}
        self.greens: dict[uuid.UUID, KnowledgeGreenRecord] = {}
        self.aliases: dict[tuple[str, str, str], KnowledgeAliasRecord] = {}
        self.history: dict[tuple[str, str, str, int], KnowledgeAliasRecord] = {}
        self._lock = threading.Lock()

    def insert_package(self, record: KnowledgePackageRecord) -> None:
        existing = self.packages.get(record.package_id)
        if existing is not None and existing != record:
            raise RuntimeError("knowledge.package_immutable_conflict")
        self.packages[record.package_id] = record

    def get_package(
        self, *, tenant_id: str, package_key: str, package_id: uuid.UUID
    ) -> KnowledgePackageRecord | None:
        value = self.packages.get(package_id)
        if value is None or (value.tenant_id, value.package_key) != (
            tenant_id,
            package_key,
        ):
            return None
        return value

    def insert_certification(self, record: KnowledgeCertificationRecord) -> None:
        self.certifications[record.certification_id] = record

    def get_certification(
        self, certification_id: uuid.UUID
    ) -> KnowledgeCertificationRecord | None:
        return self.certifications.get(certification_id)

    def insert_green(self, record: KnowledgeGreenRecord) -> None:
        self.greens[record.package_id] = record

    def get_green(self, package_id: uuid.UUID) -> KnowledgeGreenRecord | None:
        return self.greens.get(package_id)

    def create_alias(self, record: KnowledgeAliasRecord) -> bool:
        key = (record.tenant_id, record.package_key, record.alias_name)
        with self._lock:
            if key in self.aliases:
                return False
            self.aliases[key] = record
            self.history[key + (record.generation,)] = record
            return True

    def compare_and_swap_alias(
        self,
        *,
        tenant_id: str,
        package_key: str,
        alias_name: str,
        expected_generation: int,
        target_package_id: uuid.UUID,
        actor_principal_id: str,
        audit_receipt_id: str,
    ) -> KnowledgeAliasRecord | None:
        key = (tenant_id, package_key, alias_name)
        with self._lock:
            current = self.aliases.get(key)
            if current is None or current.generation != expected_generation:
                return None
            changed = KnowledgeAliasRecord(
                tenant_id=tenant_id,
                package_key=package_key,
                alias_name=alias_name,
                package_id=target_package_id,
                generation=expected_generation + 1,
                actor_principal_id=actor_principal_id,
                audit_receipt_id=audit_receipt_id,
            )
            self.aliases[key] = changed
            self.history[key + (changed.generation,)] = changed
            return changed

    def get_alias(
        self, *, tenant_id: str, package_key: str, alias_name: str
    ) -> KnowledgeAliasRecord | None:
        return self.aliases.get((tenant_id, package_key, alias_name))

    def get_alias_generation(
        self,
        *,
        tenant_id: str,
        package_key: str,
        alias_name: str,
        generation: int,
    ) -> KnowledgeAliasRecord | None:
        return self.history.get((tenant_id, package_key, alias_name, generation))


def _manifest(version: str, character: str) -> dict[str, object]:
    return {
        "schema_version": "1.0",
        "tenant_id": TENANT,
        "package_key": PACKAGE_KEY,
        "package_version": version,
        "manifest": {
            "manifest_id": str(uuid.uuid5(uuid.NAMESPACE_URL, f"{TENANT}/{version}")),
            "manifest_digest": character * 64,
        },
        "components": {
            name: {
                "artifact_ref": f"{name}://sha256/{character * 64}",
                "sha256": character * 64,
            }
            for name in COMPONENTS
        },
    }


def _context(principal: str, *permissions: str, tenant_id: str = TENANT):
    return KnowledgeAliasContext(
        tenant_id=tenant_id,
        principal_id=principal,
        permissions=frozenset(permissions),
        allowed_package_keys=frozenset({PACKAGE_KEY}),
        audit_receipt_id=f"audit-{principal}",
    )


def _publish_green(
    repository: KnowledgeAliasRepository,
    manifest: dict[str, object],
) -> KnowledgePackageRecord:
    package = repository.register_manifest(
        context=_context("publisher", "knowledge.package.register"),
        manifest=manifest,
    )
    certification = repository.certify(
        context=_context("security-reviewer", "knowledge.package.certify"),
        package_id=package.package_id,
        package_key=PACKAGE_KEY,
        dataset_digest="d" * 64,
        qualified=True,
    )
    repository.mark_green(
        context=_context("sre-promoter", "knowledge.package.promote"),
        package_id=package.package_id,
        package_key=PACKAGE_KEY,
        certification_id=certification.certification_id,
    )
    return package


def test_manifest_schema_and_digest_are_closed_and_deterministic() -> None:
    schema = json.loads(
        (REPO_ROOT / "contracts" / "knowledge-package-v1.schema.json").read_text(
            encoding="utf-8"
        )
    )
    required = set(schema["required"])
    assert required == {
        "schema_version",
        "tenant_id",
        "package_key",
        "package_version",
        "manifest",
        "components",
    }
    first = digest_knowledge_package(_manifest("1.0.0", "a"))
    second = digest_knowledge_package(_manifest("1.0.0", "a"))
    assert first.sha256 == second.sha256
    assert first.canonical_utf8 == second.canonical_utf8


def test_alias_manifest_certify_green_switch_replay_old_and_rollback() -> None:
    store = _AtomicStore()
    repository = KnowledgeAliasRepository(store)
    old_package = _publish_green(repository, _manifest("1.0.0", "a"))
    new_package = _publish_green(repository, _manifest("1.1.0", "b"))
    operator = _context(
        "release-operator",
        "knowledge.alias.switch",
        "knowledge.alias.resolve",
    )
    repository.create_alias(
        context=operator,
        package_key=PACKAGE_KEY,
        alias_name=ALIAS,
        target_package_id=old_package.package_id,
    )
    old_run = repository.resolve_for_run(
        context=operator, package_key=PACKAGE_KEY, alias_name=ALIAS
    )
    repository.switch_alias(
        context=operator,
        package_key=PACKAGE_KEY,
        alias_name=ALIAS,
        expected_generation=1,
        target_package_id=new_package.package_id,
    )
    new_run = repository.resolve_for_run(
        context=operator, package_key=PACKAGE_KEY, alias_name=ALIAS
    )
    replayed_old = repository.replay_generation(
        context=operator,
        package_key=PACKAGE_KEY,
        alias_name=ALIAS,
        generation=1,
    )
    assert old_run.package_digest == replayed_old.package_digest
    assert old_run.manifest_copy()["package_version"] == "1.0.0"
    assert new_run.manifest_copy()["package_version"] == "1.1.0"

    repository.switch_alias(
        context=operator,
        package_key=PACKAGE_KEY,
        alias_name=ALIAS,
        expected_generation=2,
        target_package_id=old_package.package_id,
    )
    rolled_back = repository.resolve_for_run(
        context=operator, package_key=PACKAGE_KEY, alias_name=ALIAS
    )
    assert rolled_back.package_digest == old_run.package_digest
    assert rolled_back.alias_generation == 3


def test_alias_generation_cas_has_exactly_one_winner() -> None:
    store = _AtomicStore()
    repository = KnowledgeAliasRepository(store)
    first = _publish_green(repository, _manifest("1.0.0", "a"))
    second = _publish_green(repository, _manifest("1.1.0", "b"))
    operator = _context("operator", "knowledge.alias.switch")
    repository.create_alias(
        context=operator,
        package_key=PACKAGE_KEY,
        alias_name=ALIAS,
        target_package_id=first.package_id,
    )
    def compete(target_package_id: uuid.UUID) -> str:
        try:
            repository.switch_alias(
                context=operator,
                package_key=PACKAGE_KEY,
                alias_name=ALIAS,
                expected_generation=1,
                target_package_id=target_package_id,
            )
        except KnowledgeAliasCasConflict:
            return "conflict"
        return "winner"

    with ThreadPoolExecutor(max_workers=2) as executor:
        outcomes = list(executor.map(compete, (first.package_id, second.package_id)))
    assert sorted(outcomes) == ["conflict", "winner"]


def test_identity_and_authorization_deny_publisher_self_certification() -> None:
    repository = KnowledgeAliasRepository(_AtomicStore())
    package = repository.register_manifest(
        context=_context("publisher", "knowledge.package.register"),
        manifest=_manifest("1.0.0", "a"),
    )
    with pytest.raises(KnowledgeAliasAuthorizationDenied, match="authorization_denied"):
        repository.certify(
            context=_context("publisher", "knowledge.package.certify"),
            package_id=package.package_id,
            package_key=PACKAGE_KEY,
            dataset_digest="d" * 64,
            qualified=True,
        )


def test_tenant_and_rls_boundary_cannot_resolve_foreign_alias() -> None:
    repository = KnowledgeAliasRepository(_AtomicStore())
    package = _publish_green(repository, _manifest("1.0.0", "a"))
    operator = _context("operator", "knowledge.alias.switch")
    repository.create_alias(
        context=operator,
        package_key=PACKAGE_KEY,
        alias_name=ALIAS,
        target_package_id=package.package_id,
    )
    with pytest.raises(KnowledgeAliasNotFound, match="alias_not_found"):
        repository.resolve_for_run(
            context=_context(
                "foreign-reader",
                "knowledge.alias.resolve",
                tenant_id="tenant-foreign",
            ),
            package_key=PACKAGE_KEY,
            alias_name=ALIAS,
        )


def test_alias_rejects_uncertified_or_non_independent_green() -> None:
    store = _AtomicStore()
    repository = KnowledgeAliasRepository(store)
    package = repository.register_manifest(
        context=_context("publisher", "knowledge.package.register"),
        manifest=_manifest("1.0.0", "a"),
    )
    with pytest.raises(KnowledgeAliasNotGreen, match="alias_not_green"):
        repository.create_alias(
            context=_context("operator", "knowledge.alias.switch"),
            package_key=PACKAGE_KEY,
            alias_name=ALIAS,
            target_package_id=package.package_id,
        )
    certification = repository.certify(
        context=_context("reviewer", "knowledge.package.certify"),
        package_id=package.package_id,
        package_key=PACKAGE_KEY,
        dataset_digest="d" * 64,
        qualified=True,
    )
    with pytest.raises(KnowledgeAliasNotGreen, match="alias_not_green"):
        repository.mark_green(
            context=_context("reviewer", "knowledge.package.promote"),
            package_id=package.package_id,
            package_key=PACKAGE_KEY,
            certification_id=certification.certification_id,
        )


def test_alias_digest_tampering_fails_closed_before_run_pin() -> None:
    store = _AtomicStore()
    repository = KnowledgeAliasRepository(store)
    package = _publish_green(repository, _manifest("1.0.0", "a"))
    operator = _context(
        "operator", "knowledge.alias.switch", "knowledge.alias.resolve"
    )
    repository.create_alias(
        context=operator,
        package_key=PACKAGE_KEY,
        alias_name=ALIAS,
        target_package_id=package.package_id,
    )
    store.packages[package.package_id] = replace(
        package,
        canonical_manifest=package.canonical_manifest.replace(b"1.0.0", b"9.9.9"),
    )
    with pytest.raises(KnowledgeAliasNotGreen, match="alias_not_green"):
        repository.resolve_for_run(
            context=operator, package_key=PACKAGE_KEY, alias_name=ALIAS
        )
