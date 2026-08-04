"""Transaction-owned Knowledge persistence with explicit tenant and authority checks."""

from __future__ import annotations

import re
import uuid
from dataclasses import dataclass
from datetime import datetime
from typing import Any

from sqlalchemy import func, select
from sqlalchemy.orm import Session

from app.persistence.models.knowledge import (
    KnowledgeAclEntryRecord,
    KnowledgeChunkRecord,
    KnowledgeIngestionReceiptRecord,
    KnowledgeManifestEntryRecord,
    KnowledgeManifestRecord,
    KnowledgeOutboxRecord,
    KnowledgeSourceRecord,
    KnowledgeSourceVersionRecord,
)
from app.persistence.repositories.runs import TransactionRequired


SOURCE_KEY_PATTERN = re.compile(r"^[a-z][a-z0-9_.:/-]{0,190}$")
NAME_PATTERN = re.compile(r"^[a-z][a-z0-9_.-]{0,126}$")
DIGEST_PATTERN = re.compile(r"^[0-9a-f]{64}$")
SOURCE_CLASSES = frozenset(
    {
        "first_party_product_knowledge",
        "public_licensed_reference",
        "tenant_private_curated",
    }
)
PURPOSES = frozenset(
    {"itinerary_planning", "candidate_explanation", "travel_knowledge_retrieval"}
)


class KnowledgeAuthorizationDenied(RuntimeError):
    code = "knowledge.authorization_denied"

    def __init__(self) -> None:
        super().__init__(self.code)


class KnowledgeRecordNotFound(RuntimeError):
    code = "knowledge.record_not_found"

    def __init__(self) -> None:
        super().__init__(self.code)


class KnowledgeImmutableConflict(RuntimeError):
    code = "knowledge.immutable_conflict"

    def __init__(self) -> None:
        super().__init__(self.code)


@dataclass(frozen=True, slots=True)
class KnowledgeWriteContext:
    tenant_id: str
    principal_id: str
    audit_receipt_id: str
    permissions: frozenset[str]


@dataclass(frozen=True, slots=True)
class CreateResult:
    record: Any
    created: bool


def _valid_digest(value: str) -> bool:
    return DIGEST_PATTERN.fullmatch(value) is not None


class KnowledgeRepository:
    def __init__(self, session: Session) -> None:
        self._session = session

    def _require_transaction(self) -> None:
        if not self._session.in_transaction():
            raise TransactionRequired()

    @staticmethod
    def _authorize(context: KnowledgeWriteContext, permission: str) -> None:
        if (
            not context.tenant_id
            or not context.principal_id
            or not context.audit_receipt_id
            or permission not in context.permissions
        ):
            raise KnowledgeAuthorizationDenied()

    def _source_for_update(
        self, *, tenant_id: str, source_id: uuid.UUID
    ) -> KnowledgeSourceRecord:
        source = self._session.execute(
            select(KnowledgeSourceRecord)
            .where(
                KnowledgeSourceRecord.tenant_id == tenant_id,
                KnowledgeSourceRecord.source_id == source_id,
            )
            .with_for_update()
        ).scalar_one_or_none()
        if source is None:
            raise KnowledgeRecordNotFound()
        return source

    def create_source(
        self,
        *,
        context: KnowledgeWriteContext,
        source_key: str,
        source_class: str,
        owner_principal_id: str,
        license_identifier: str,
        purpose: str,
    ) -> CreateResult:
        self._require_transaction()
        self._authorize(context, "knowledge.source.create")
        if (
            SOURCE_KEY_PATTERN.fullmatch(source_key) is None
            or source_class not in SOURCE_CLASSES
            or purpose not in PURPOSES
            or not owner_principal_id
            or not license_identifier
        ):
            raise ValueError("knowledge source boundary is invalid")
        existing = self._session.execute(
            select(KnowledgeSourceRecord).where(
                KnowledgeSourceRecord.tenant_id == context.tenant_id,
                KnowledgeSourceRecord.source_key == source_key,
            )
        ).scalar_one_or_none()
        if existing is not None:
            expected = (
                source_class,
                owner_principal_id,
                license_identifier,
                purpose,
            )
            actual = (
                existing.source_class,
                existing.owner_principal_id,
                existing.license_identifier,
                existing.purpose,
            )
            if actual != expected:
                raise KnowledgeImmutableConflict()
            return CreateResult(record=existing, created=False)
        source = KnowledgeSourceRecord(
            source_id=uuid.uuid4(),
            tenant_id=context.tenant_id,
            source_key=source_key,
            source_class=source_class,
            owner_principal_id=owner_principal_id,
            license_identifier=license_identifier,
            purpose=purpose,
            status="active",
            audit_receipt_id=context.audit_receipt_id,
        )
        self._session.add(source)
        self._session.flush()
        return CreateResult(record=source, created=True)

    def create_source_version(
        self,
        *,
        context: KnowledgeWriteContext,
        source_id: uuid.UUID,
        version_number: int,
        content_digest: str,
        parser_digest: str,
        metadata_payload: dict[str, Any],
    ) -> CreateResult:
        self._require_transaction()
        self._authorize(context, "knowledge.version.create")
        if (
            version_number < 1
            or not _valid_digest(content_digest)
            or not _valid_digest(parser_digest)
            or not isinstance(metadata_payload, dict)
        ):
            raise ValueError("knowledge source version boundary is invalid")
        source = self._source_for_update(
            tenant_id=context.tenant_id, source_id=source_id
        )
        if source.status != "active":
            raise KnowledgeImmutableConflict()
        existing = self._session.execute(
            select(KnowledgeSourceVersionRecord).where(
                KnowledgeSourceVersionRecord.tenant_id == context.tenant_id,
                KnowledgeSourceVersionRecord.source_id == source_id,
                KnowledgeSourceVersionRecord.version_number == version_number,
            )
        ).scalar_one_or_none()
        if existing is not None:
            if (
                existing.content_digest != content_digest
                or existing.parser_digest != parser_digest
                or existing.metadata_payload != metadata_payload
            ):
                raise KnowledgeImmutableConflict()
            return CreateResult(record=existing, created=False)
        version = KnowledgeSourceVersionRecord(
            version_id=uuid.uuid4(),
            tenant_id=context.tenant_id,
            source_id=source_id,
            version_number=version_number,
            content_digest=content_digest,
            parser_digest=parser_digest,
            object_ref=f"knowledge-object://sha256/{content_digest}",
            status="staged",
            metadata_payload=metadata_payload,
            created_by_principal_id=context.principal_id,
            audit_receipt_id=context.audit_receipt_id,
        )
        self._session.add(version)
        self._session.flush()
        return CreateResult(record=version, created=True)

    def grant_read(
        self,
        *,
        context: KnowledgeWriteContext,
        source_id: uuid.UUID,
        subject_type: str,
        subject_id: str,
    ) -> CreateResult:
        self._require_transaction()
        self._authorize(context, "knowledge.acl.manage")
        if subject_type not in {"principal", "group", "tenant"} or not subject_id:
            raise ValueError("knowledge ACL boundary is invalid")
        self._source_for_update(tenant_id=context.tenant_id, source_id=source_id)
        existing = self._session.execute(
            select(KnowledgeAclEntryRecord)
            .where(
                KnowledgeAclEntryRecord.tenant_id == context.tenant_id,
                KnowledgeAclEntryRecord.source_id == source_id,
                KnowledgeAclEntryRecord.subject_type == subject_type,
                KnowledgeAclEntryRecord.subject_id == subject_id,
                KnowledgeAclEntryRecord.permission == "read",
            )
            .with_for_update()
        ).scalar_one_or_none()
        if existing is not None:
            if existing.revoked_at is not None:
                existing.revoked_at = None
                existing.granted_by_principal_id = context.principal_id
                existing.audit_receipt_id = context.audit_receipt_id
                self._session.flush()
            return CreateResult(record=existing, created=False)
        entry = KnowledgeAclEntryRecord(
            acl_entry_id=uuid.uuid4(),
            tenant_id=context.tenant_id,
            source_id=source_id,
            subject_type=subject_type,
            subject_id=subject_id,
            permission="read",
            granted_by_principal_id=context.principal_id,
            audit_receipt_id=context.audit_receipt_id,
            revoked_at=None,
        )
        self._session.add(entry)
        self._session.flush()
        return CreateResult(record=entry, created=True)

    def add_chunk(
        self,
        *,
        context: KnowledgeWriteContext,
        source_id: uuid.UUID,
        version_id: uuid.UUID,
        chunk_ordinal: int,
        chunk_digest: str,
        text_content: str,
        token_count: int,
        metadata_payload: dict[str, Any],
    ) -> CreateResult:
        self._require_transaction()
        self._authorize(context, "knowledge.chunk.create")
        if (
            chunk_ordinal < 0
            or not _valid_digest(chunk_digest)
            or not text_content
            or token_count < 1
            or not isinstance(metadata_payload, dict)
        ):
            raise ValueError("knowledge chunk boundary is invalid")
        version = self._session.execute(
            select(KnowledgeSourceVersionRecord).where(
                KnowledgeSourceVersionRecord.tenant_id == context.tenant_id,
                KnowledgeSourceVersionRecord.source_id == source_id,
                KnowledgeSourceVersionRecord.version_id == version_id,
            )
        ).scalar_one_or_none()
        if version is None:
            raise KnowledgeRecordNotFound()
        existing = self._session.execute(
            select(KnowledgeChunkRecord).where(
                KnowledgeChunkRecord.tenant_id == context.tenant_id,
                KnowledgeChunkRecord.version_id == version_id,
                KnowledgeChunkRecord.chunk_ordinal == chunk_ordinal,
            )
        ).scalar_one_or_none()
        if existing is not None:
            if (
                existing.chunk_digest != chunk_digest
                or existing.text_content != text_content
                or existing.token_count != token_count
                or existing.metadata_payload != metadata_payload
            ):
                raise KnowledgeImmutableConflict()
            return CreateResult(record=existing, created=False)
        chunk = KnowledgeChunkRecord(
            chunk_id=uuid.uuid4(),
            tenant_id=context.tenant_id,
            source_id=source_id,
            version_id=version_id,
            chunk_ordinal=chunk_ordinal,
            chunk_digest=chunk_digest,
            text_content=text_content,
            token_count=token_count,
            metadata_payload=metadata_payload,
        )
        self._session.add(chunk)
        self._session.flush()
        return CreateResult(record=chunk, created=True)

    def create_manifest(
        self,
        *,
        context: KnowledgeWriteContext,
        manifest_digest: str,
        tokenizer_version: str,
        embedding_model_ref: str,
    ) -> CreateResult:
        self._require_transaction()
        self._authorize(context, "knowledge.manifest.create")
        if (
            not _valid_digest(manifest_digest)
            or not tokenizer_version
            or not embedding_model_ref
        ):
            raise ValueError("knowledge manifest boundary is invalid")
        existing = self._session.execute(
            select(KnowledgeManifestRecord).where(
                KnowledgeManifestRecord.tenant_id == context.tenant_id,
                KnowledgeManifestRecord.manifest_digest == manifest_digest,
            )
        ).scalar_one_or_none()
        if existing is not None:
            if (
                existing.tokenizer_version != tokenizer_version
                or existing.embedding_model_ref != embedding_model_ref
            ):
                raise KnowledgeImmutableConflict()
            return CreateResult(record=existing, created=False)
        manifest = KnowledgeManifestRecord(
            manifest_id=uuid.uuid4(),
            tenant_id=context.tenant_id,
            manifest_digest=manifest_digest,
            status="building",
            tokenizer_version=tokenizer_version,
            embedding_model_ref=embedding_model_ref,
            created_by_principal_id=context.principal_id,
            audit_receipt_id=context.audit_receipt_id,
        )
        self._session.add(manifest)
        self._session.flush()
        return CreateResult(record=manifest, created=True)

    def add_manifest_entry(
        self,
        *,
        context: KnowledgeWriteContext,
        manifest_id: uuid.UUID,
        chunk_id: uuid.UUID,
        entry_ordinal: int,
    ) -> KnowledgeManifestEntryRecord:
        self._require_transaction()
        self._authorize(context, "knowledge.manifest.create")
        if entry_ordinal < 0:
            raise ValueError("knowledge manifest entry boundary is invalid")
        manifest = self._session.execute(
            select(KnowledgeManifestRecord).where(
                KnowledgeManifestRecord.tenant_id == context.tenant_id,
                KnowledgeManifestRecord.manifest_id == manifest_id,
            )
        ).scalar_one_or_none()
        chunk = self._session.execute(
            select(KnowledgeChunkRecord).where(
                KnowledgeChunkRecord.tenant_id == context.tenant_id,
                KnowledgeChunkRecord.chunk_id == chunk_id,
            )
        ).scalar_one_or_none()
        if manifest is None or chunk is None or manifest.status != "building":
            raise KnowledgeRecordNotFound()
        entry = KnowledgeManifestEntryRecord(
            manifest_entry_id=uuid.uuid4(),
            tenant_id=context.tenant_id,
            manifest_id=manifest_id,
            chunk_id=chunk_id,
            entry_ordinal=entry_ordinal,
        )
        self._session.add(entry)
        self._session.flush()
        return entry

    def record_ingestion_receipt(
        self,
        *,
        context: KnowledgeWriteContext,
        source_id: uuid.UUID,
        version_id: uuid.UUID,
        pipeline_digest: str,
        status: str,
        chunk_count: int,
        failure_code: str | None,
    ) -> CreateResult:
        self._require_transaction()
        self._authorize(context, "knowledge.ingestion.complete")
        if (
            not _valid_digest(pipeline_digest)
            or status not in {"succeeded", "failed"}
            or chunk_count < 0
            or (status == "failed") != (failure_code is not None)
            or (failure_code is not None and NAME_PATTERN.fullmatch(failure_code) is None)
        ):
            raise ValueError("knowledge ingestion receipt boundary is invalid")
        existing = self._session.execute(
            select(KnowledgeIngestionReceiptRecord).where(
                KnowledgeIngestionReceiptRecord.tenant_id == context.tenant_id,
                KnowledgeIngestionReceiptRecord.source_id == source_id,
                KnowledgeIngestionReceiptRecord.version_id == version_id,
                KnowledgeIngestionReceiptRecord.pipeline_digest == pipeline_digest,
            )
        ).scalar_one_or_none()
        if existing is not None:
            expected = (status, chunk_count, failure_code)
            actual = (existing.status, existing.chunk_count, existing.failure_code)
            if actual != expected:
                raise KnowledgeImmutableConflict()
            return CreateResult(record=existing, created=False)
        receipt = KnowledgeIngestionReceiptRecord(
            ingestion_receipt_id=uuid.uuid4(),
            tenant_id=context.tenant_id,
            source_id=source_id,
            version_id=version_id,
            pipeline_digest=pipeline_digest,
            status=status,
            chunk_count=chunk_count,
            failure_code=failure_code,
            audit_receipt_id=context.audit_receipt_id,
        )
        self._session.add(receipt)
        self._session.flush()
        return CreateResult(record=receipt, created=True)

    def enqueue_outbox(
        self,
        *,
        context: KnowledgeWriteContext,
        event_type: str,
        aggregate_type: str,
        aggregate_id: uuid.UUID,
        idempotency_key: str,
        payload_digest: str,
        max_attempts: int = 5,
    ) -> CreateResult:
        self._require_transaction()
        self._authorize(context, "knowledge.outbox.enqueue")
        if (
            NAME_PATTERN.fullmatch(event_type) is None
            or aggregate_type not in {"source", "version", "manifest", "deletion"}
            or not idempotency_key
            or len(idempotency_key) > 191
            or not _valid_digest(payload_digest)
            or not 1 <= max_attempts <= 10
        ):
            raise ValueError("knowledge outbox boundary is invalid")
        existing = self._session.execute(
            select(KnowledgeOutboxRecord).where(
                KnowledgeOutboxRecord.tenant_id == context.tenant_id,
                KnowledgeOutboxRecord.idempotency_key == idempotency_key,
            )
        ).scalar_one_or_none()
        if existing is not None:
            expected = (event_type, aggregate_type, aggregate_id, payload_digest)
            actual = (
                existing.event_type,
                existing.aggregate_type,
                existing.aggregate_id,
                existing.payload_digest,
            )
            if actual != expected:
                raise KnowledgeImmutableConflict()
            return CreateResult(record=existing, created=False)
        message = KnowledgeOutboxRecord(
            outbox_id=uuid.uuid4(),
            tenant_id=context.tenant_id,
            event_type=event_type,
            aggregate_type=aggregate_type,
            aggregate_id=aggregate_id,
            idempotency_key=idempotency_key,
            payload_ref=f"knowledge-event://sha256/{payload_digest}",
            payload_digest=payload_digest,
            status="pending",
            attempt_count=0,
            max_attempts=max_attempts,
            available_at=func.statement_timestamp(),
            claim_token=None,
            claimed_by=None,
            claimed_until=None,
            last_error_code=None,
            audit_receipt_id=context.audit_receipt_id,
            delivered_at=None,
        )
        self._session.add(message)
        self._session.flush()
        return CreateResult(record=message, created=True)

    def get_source(
        self, *, tenant_id: str, source_id: uuid.UUID
    ) -> KnowledgeSourceRecord:
        if not tenant_id:
            raise ValueError("tenant_id is required")
        source = self._session.execute(
            select(KnowledgeSourceRecord).where(
                KnowledgeSourceRecord.tenant_id == tenant_id,
                KnowledgeSourceRecord.source_id == source_id,
            )
        ).scalar_one_or_none()
        if source is None:
            raise KnowledgeRecordNotFound()
        return source

    def mark_source_updated(self, source: KnowledgeSourceRecord) -> None:
        self._require_transaction()
        source.updated_at = datetime.now().astimezone()
        self._session.flush()
