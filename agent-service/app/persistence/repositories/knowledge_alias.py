"""Authorized Knowledge Package certification and tenant-scoped alias CAS."""

from __future__ import annotations

import json
import re
import uuid
from dataclasses import dataclass
from typing import Literal, Protocol

from app.rag.package import DIGEST_PATTERN, digest_knowledge_package


ALIAS_PATTERN = re.compile(r"^[a-z][a-z0-9_.-]{0,126}$")
PACKAGE_NAMESPACE = uuid.UUID("9d50f8d6-e77f-47af-90ad-7e75a46135b2")


class KnowledgeAliasAuthorizationDenied(RuntimeError):
    code = "knowledge.alias_authorization_denied"

    def __init__(self) -> None:
        super().__init__(self.code)


class KnowledgeAliasNotGreen(RuntimeError):
    code = "knowledge.alias_not_green"

    def __init__(self) -> None:
        super().__init__(self.code)


class KnowledgeAliasCasConflict(RuntimeError):
    code = "knowledge.alias_cas_conflict"

    def __init__(self) -> None:
        super().__init__(self.code)


class KnowledgeAliasNotFound(RuntimeError):
    code = "knowledge.alias_not_found"

    def __init__(self) -> None:
        super().__init__(self.code)


@dataclass(frozen=True, slots=True)
class KnowledgeAliasContext:
    tenant_id: str
    principal_id: str
    permissions: frozenset[str]
    allowed_package_keys: frozenset[str]
    audit_receipt_id: str


@dataclass(frozen=True, slots=True)
class KnowledgePackageRecord:
    package_id: uuid.UUID
    tenant_id: str
    package_key: str
    package_version: str
    package_digest: str
    manifest_id: uuid.UUID
    manifest_digest: str
    canonical_manifest: bytes
    publisher_principal_id: str
    audit_receipt_id: str


@dataclass(frozen=True, slots=True)
class KnowledgeCertificationRecord:
    certification_id: uuid.UUID
    package_id: uuid.UUID
    dataset_digest: str
    result: Literal["qualified", "rejected"]
    certifier_principal_id: str
    audit_receipt_id: str


@dataclass(frozen=True, slots=True)
class KnowledgeGreenRecord:
    green_id: uuid.UUID
    package_id: uuid.UUID
    certification_id: uuid.UUID
    promoter_principal_id: str
    audit_receipt_id: str


@dataclass(frozen=True, slots=True)
class KnowledgeAliasRecord:
    tenant_id: str
    package_key: str
    alias_name: str
    package_id: uuid.UUID
    generation: int
    actor_principal_id: str
    audit_receipt_id: str


@dataclass(frozen=True, slots=True)
class KnowledgeRunPin:
    package_id: uuid.UUID
    package_digest: str
    package_version: str
    manifest_id: uuid.UUID
    manifest_digest: str
    alias_generation: int
    canonical_manifest: bytes
    audit_receipt_id: str

    def manifest_copy(self) -> dict[str, object]:
        value = json.loads(self.canonical_manifest.decode("utf-8"))
        if not isinstance(value, dict):
            raise KnowledgeAliasNotGreen()
        return value


class KnowledgeAliasStore(Protocol):
    """Durable adapter contract; alias CAS and history append are one transaction."""

    def insert_package(self, record: KnowledgePackageRecord) -> None: ...

    def get_package(
        self, *, tenant_id: str, package_key: str, package_id: uuid.UUID
    ) -> KnowledgePackageRecord | None: ...

    def insert_certification(self, record: KnowledgeCertificationRecord) -> None: ...

    def get_certification(
        self, certification_id: uuid.UUID
    ) -> KnowledgeCertificationRecord | None: ...

    def insert_green(self, record: KnowledgeGreenRecord) -> None: ...

    def get_green(self, package_id: uuid.UUID) -> KnowledgeGreenRecord | None: ...

    def create_alias(self, record: KnowledgeAliasRecord) -> bool: ...

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
    ) -> KnowledgeAliasRecord | None: ...

    def get_alias(
        self, *, tenant_id: str, package_key: str, alias_name: str
    ) -> KnowledgeAliasRecord | None: ...

    def get_alias_generation(
        self,
        *,
        tenant_id: str,
        package_key: str,
        alias_name: str,
        generation: int,
    ) -> KnowledgeAliasRecord | None: ...


class KnowledgeAliasRepository:
    def __init__(self, store: KnowledgeAliasStore) -> None:
        self._store = store

    @staticmethod
    def _authorize(
        context: KnowledgeAliasContext, *, permission: str, package_key: str
    ) -> None:
        if (
            not context.tenant_id
            or not context.principal_id
            or not context.audit_receipt_id
            or permission not in context.permissions
            or package_key not in context.allowed_package_keys
        ):
            raise KnowledgeAliasAuthorizationDenied()

    def register_manifest(
        self, *, context: KnowledgeAliasContext, manifest: dict[str, object]
    ) -> KnowledgePackageRecord:
        digest = digest_knowledge_package(manifest)
        tenant_id = str(digest.normalized["tenant_id"])
        package_key = str(digest.normalized["package_key"])
        self._authorize(
            context, permission="knowledge.package.register", package_key=package_key
        )
        if tenant_id != context.tenant_id:
            raise KnowledgeAliasAuthorizationDenied()
        manifest_identity = digest.normalized["manifest"]
        if not isinstance(manifest_identity, dict):
            raise KnowledgeAliasNotGreen()
        record = KnowledgePackageRecord(
            package_id=uuid.uuid5(
                PACKAGE_NAMESPACE,
                f"{tenant_id}|{package_key}|{digest.sha256}",
            ),
            tenant_id=tenant_id,
            package_key=package_key,
            package_version=str(digest.normalized["package_version"]),
            package_digest=digest.sha256,
            manifest_id=uuid.UUID(str(manifest_identity["manifest_id"])),
            manifest_digest=str(manifest_identity["manifest_digest"]),
            canonical_manifest=digest.canonical_utf8,
            publisher_principal_id=context.principal_id,
            audit_receipt_id=context.audit_receipt_id,
        )
        self._store.insert_package(record)
        return record

    def certify(
        self,
        *,
        context: KnowledgeAliasContext,
        package_id: uuid.UUID,
        package_key: str,
        dataset_digest: str,
        qualified: bool,
    ) -> KnowledgeCertificationRecord:
        self._authorize(
            context, permission="knowledge.package.certify", package_key=package_key
        )
        package = self._load_package(context, package_key, package_id)
        if DIGEST_PATTERN.fullmatch(dataset_digest) is None:
            raise ValueError("knowledge certification dataset digest is invalid")
        if package.publisher_principal_id == context.principal_id:
            raise KnowledgeAliasAuthorizationDenied()
        result: Literal["qualified", "rejected"] = (
            "qualified" if qualified else "rejected"
        )
        record = KnowledgeCertificationRecord(
            certification_id=uuid.uuid4(),
            package_id=package.package_id,
            dataset_digest=dataset_digest,
            result=result,
            certifier_principal_id=context.principal_id,
            audit_receipt_id=context.audit_receipt_id,
        )
        self._store.insert_certification(record)
        return record

    def mark_green(
        self,
        *,
        context: KnowledgeAliasContext,
        package_id: uuid.UUID,
        package_key: str,
        certification_id: uuid.UUID,
    ) -> KnowledgeGreenRecord:
        self._authorize(
            context, permission="knowledge.package.promote", package_key=package_key
        )
        package = self._load_package(context, package_key, package_id)
        certification = self._store.get_certification(certification_id)
        if (
            certification is None
            or certification.package_id != package.package_id
            or certification.result != "qualified"
            or certification.certifier_principal_id == context.principal_id
            or package.publisher_principal_id == context.principal_id
        ):
            raise KnowledgeAliasNotGreen()
        record = KnowledgeGreenRecord(
            green_id=uuid.uuid4(),
            package_id=package.package_id,
            certification_id=certification.certification_id,
            promoter_principal_id=context.principal_id,
            audit_receipt_id=context.audit_receipt_id,
        )
        self._store.insert_green(record)
        return record

    def create_alias(
        self,
        *,
        context: KnowledgeAliasContext,
        package_key: str,
        alias_name: str,
        target_package_id: uuid.UUID,
    ) -> KnowledgeAliasRecord:
        self._authorize(
            context, permission="knowledge.alias.switch", package_key=package_key
        )
        self._require_alias_name(alias_name)
        package = self._require_green(context, package_key, target_package_id)
        record = KnowledgeAliasRecord(
            tenant_id=context.tenant_id,
            package_key=package.package_key,
            alias_name=alias_name,
            package_id=package.package_id,
            generation=1,
            actor_principal_id=context.principal_id,
            audit_receipt_id=context.audit_receipt_id,
        )
        if not self._store.create_alias(record):
            raise KnowledgeAliasCasConflict()
        return record

    def switch_alias(
        self,
        *,
        context: KnowledgeAliasContext,
        package_key: str,
        alias_name: str,
        expected_generation: int,
        target_package_id: uuid.UUID,
    ) -> KnowledgeAliasRecord:
        self._authorize(
            context, permission="knowledge.alias.switch", package_key=package_key
        )
        self._require_alias_name(alias_name)
        if expected_generation < 1:
            raise KnowledgeAliasCasConflict()
        package = self._require_green(context, package_key, target_package_id)
        changed = self._store.compare_and_swap_alias(
            tenant_id=context.tenant_id,
            package_key=package.package_key,
            alias_name=alias_name,
            expected_generation=expected_generation,
            target_package_id=package.package_id,
            actor_principal_id=context.principal_id,
            audit_receipt_id=context.audit_receipt_id,
        )
        if changed is None:
            raise KnowledgeAliasCasConflict()
        return changed

    def resolve_for_run(
        self,
        *,
        context: KnowledgeAliasContext,
        package_key: str,
        alias_name: str,
    ) -> KnowledgeRunPin:
        self._authorize(
            context, permission="knowledge.alias.resolve", package_key=package_key
        )
        self._require_alias_name(alias_name)
        alias = self._store.get_alias(
            tenant_id=context.tenant_id,
            package_key=package_key,
            alias_name=alias_name,
        )
        if alias is None:
            raise KnowledgeAliasNotFound()
        return self._pin(context, alias)

    def replay_generation(
        self,
        *,
        context: KnowledgeAliasContext,
        package_key: str,
        alias_name: str,
        generation: int,
    ) -> KnowledgeRunPin:
        self._authorize(
            context, permission="knowledge.alias.resolve", package_key=package_key
        )
        self._require_alias_name(alias_name)
        if generation < 1:
            raise KnowledgeAliasNotFound()
        alias = self._store.get_alias_generation(
            tenant_id=context.tenant_id,
            package_key=package_key,
            alias_name=alias_name,
            generation=generation,
        )
        if alias is None:
            raise KnowledgeAliasNotFound()
        return self._pin(context, alias)

    def _pin(
        self, context: KnowledgeAliasContext, alias: KnowledgeAliasRecord
    ) -> KnowledgeRunPin:
        package = self._require_green(context, alias.package_key, alias.package_id)
        try:
            decoded = json.loads(package.canonical_manifest.decode("utf-8"))
            if not isinstance(decoded, dict):
                raise ValueError("manifest is not an object")
            verified = digest_knowledge_package(decoded)
        except (UnicodeError, ValueError, TypeError) as error:
            raise KnowledgeAliasNotGreen() from error
        if verified.sha256 != package.package_digest:
            raise KnowledgeAliasNotGreen()
        return KnowledgeRunPin(
            package_id=package.package_id,
            package_digest=package.package_digest,
            package_version=package.package_version,
            manifest_id=package.manifest_id,
            manifest_digest=package.manifest_digest,
            alias_generation=alias.generation,
            canonical_manifest=bytes(package.canonical_manifest),
            audit_receipt_id=alias.audit_receipt_id,
        )

    def _load_package(
        self,
        context: KnowledgeAliasContext,
        package_key: str,
        package_id: uuid.UUID,
    ) -> KnowledgePackageRecord:
        package = self._store.get_package(
            tenant_id=context.tenant_id,
            package_key=package_key,
            package_id=package_id,
        )
        if package is None:
            raise KnowledgeAliasNotFound()
        return package

    def _require_green(
        self,
        context: KnowledgeAliasContext,
        package_key: str,
        package_id: uuid.UUID,
    ) -> KnowledgePackageRecord:
        package = self._load_package(context, package_key, package_id)
        green = self._store.get_green(package.package_id)
        if green is None:
            raise KnowledgeAliasNotGreen()
        certification = self._store.get_certification(green.certification_id)
        if (
            certification is None
            or certification.package_id != package.package_id
            or certification.result != "qualified"
        ):
            raise KnowledgeAliasNotGreen()
        return package

    @staticmethod
    def _require_alias_name(alias_name: str) -> None:
        if ALIAS_PATTERN.fullmatch(alias_name) is None:
            raise ValueError("knowledge alias name is invalid")
