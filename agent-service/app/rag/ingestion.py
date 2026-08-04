"""Authorization-first, idempotent Knowledge ingestion orchestration."""

from __future__ import annotations

import hashlib
import json
import uuid
from dataclasses import dataclass, field
from typing import Any, Callable, Mapping

from sqlalchemy.orm import Session

from app.persistence.repositories.knowledge import (
    KnowledgeAuthorizationDenied,
    KnowledgeRepository,
    KnowledgeWriteContext,
)
from app.persistence.repositories.runs import TransactionRequired
from app.rag.chunker import ChunkDraft, DeterministicChunker
from app.rag.embedding_jobs import EmbeddingJobPlan, EmbeddingJobPlanner
from app.rag.parser import DeterministicTextParser, DocumentParser, ParsedDocument


REQUIRED_INGESTION_PERMISSIONS = frozenset(
    {
        "knowledge.chunk.create",
        "knowledge.ingestion.complete",
        "knowledge.outbox.enqueue",
        "knowledge.source.create",
        "knowledge.version.create",
    }
)
SYSTEM_METADATA_PREFIX = "_gonow_"


@dataclass(frozen=True, slots=True)
class IngestionRequest:
    context: KnowledgeWriteContext
    source_key: str
    source_class: str
    owner_principal_id: str
    license_identifier: str
    purpose: str
    version_number: int
    payload: bytes = field(repr=False)
    media_type: str
    embedding_model_ref: str
    metadata_payload: Mapping[str, Any] = field(default_factory=dict)


@dataclass(frozen=True, slots=True)
class IngestionResult:
    source_id: uuid.UUID
    version_id: uuid.UUID
    ingestion_receipt_id: uuid.UUID
    outbox_id: uuid.UUID
    chunk_ids: tuple[uuid.UUID, ...]
    content_digest: str
    pipeline_digest: str
    embedding_plan: EmbeddingJobPlan
    source_created: bool
    version_created: bool
    created_chunk_count: int
    receipt_created: bool
    outbox_created: bool

    @property
    def replayed(self) -> bool:
        return not any(
            (
                self.source_created,
                self.version_created,
                self.created_chunk_count > 0,
                self.receipt_created,
                self.outbox_created,
            )
        )


@dataclass(frozen=True, slots=True)
class _PreparedIngestion:
    document: ParsedDocument
    chunks: tuple[ChunkDraft, ...]
    embedding_plan: EmbeddingJobPlan
    pipeline_digest: str
    version_metadata: dict[str, Any]


RepositoryFactory = Callable[[Session], KnowledgeRepository]


def _canonical_json(value: Mapping[str, Any]) -> str:
    try:
        return json.dumps(
            value,
            allow_nan=False,
            ensure_ascii=False,
            separators=(",", ":"),
            sort_keys=True,
        )
    except (TypeError, ValueError) as exc:
        raise ValueError("ingestion metadata must be canonical JSON") from exc


class KnowledgeIngestionPipeline:
    """Prepare fully in memory, then persist one replay-safe transaction."""

    PIPELINE_VERSION = "1"

    def __init__(
        self,
        session: Session,
        *,
        parser: DocumentParser | None = None,
        chunker: DeterministicChunker | None = None,
        embedding_planner: EmbeddingJobPlanner | None = None,
        repository_factory: RepositoryFactory = KnowledgeRepository,
    ) -> None:
        self._session = session
        self._parser = parser or DeterministicTextParser()
        self._chunker = chunker or DeterministicChunker()
        self._embedding_planner = embedding_planner or EmbeddingJobPlanner()
        self._repository_factory = repository_factory

    def ingest(self, request: IngestionRequest) -> IngestionResult:
        if not self._session.in_transaction():
            raise TransactionRequired()
        self._authorize(request.context)
        prepared = self._prepare(request)
        repository = self._repository_factory(self._session)

        source_result = repository.create_source(
            context=request.context,
            source_key=request.source_key,
            source_class=request.source_class,
            owner_principal_id=request.owner_principal_id,
            license_identifier=request.license_identifier,
            purpose=request.purpose,
        )
        version_result = repository.create_source_version(
            context=request.context,
            source_id=source_result.record.source_id,
            version_number=request.version_number,
            content_digest=prepared.document.content_digest,
            parser_digest=prepared.document.parser_digest,
            metadata_payload=prepared.version_metadata,
        )

        chunk_ids: list[uuid.UUID] = []
        created_chunk_count = 0
        for chunk in prepared.chunks:
            chunk_result = repository.add_chunk(
                context=request.context,
                source_id=source_result.record.source_id,
                version_id=version_result.record.version_id,
                chunk_ordinal=chunk.ordinal,
                chunk_digest=chunk.chunk_digest,
                text_content=chunk.text,
                token_count=chunk.token_count,
                metadata_payload=chunk.metadata_payload(),
            )
            chunk_ids.append(chunk_result.record.chunk_id)
            created_chunk_count += int(chunk_result.created)

        receipt_result = repository.record_ingestion_receipt(
            context=request.context,
            source_id=source_result.record.source_id,
            version_id=version_result.record.version_id,
            pipeline_digest=prepared.pipeline_digest,
            status="succeeded",
            chunk_count=len(chunk_ids),
            failure_code=None,
        )
        outbox_result = repository.enqueue_outbox(
            context=request.context,
            event_type="knowledge.embedding.requested",
            aggregate_type="version",
            aggregate_id=version_result.record.version_id,
            idempotency_key=f"embedding:{prepared.embedding_plan.plan_digest}",
            payload_digest=prepared.embedding_plan.plan_digest,
            max_attempts=prepared.embedding_plan.max_attempts,
        )
        return IngestionResult(
            source_id=source_result.record.source_id,
            version_id=version_result.record.version_id,
            ingestion_receipt_id=receipt_result.record.ingestion_receipt_id,
            outbox_id=outbox_result.record.outbox_id,
            chunk_ids=tuple(chunk_ids),
            content_digest=prepared.document.content_digest,
            pipeline_digest=prepared.pipeline_digest,
            embedding_plan=prepared.embedding_plan,
            source_created=source_result.created,
            version_created=version_result.created,
            created_chunk_count=created_chunk_count,
            receipt_created=receipt_result.created,
            outbox_created=outbox_result.created,
        )

    @staticmethod
    def _authorize(context: KnowledgeWriteContext) -> None:
        if (
            not context.tenant_id
            or not context.principal_id
            or not context.audit_receipt_id
            or not REQUIRED_INGESTION_PERMISSIONS.issubset(context.permissions)
        ):
            raise KnowledgeAuthorizationDenied()

    def _prepare(self, request: IngestionRequest) -> _PreparedIngestion:
        if request.version_number < 1:
            raise ValueError("version_number must be positive")
        if any(str(key).startswith(SYSTEM_METADATA_PREFIX) for key in request.metadata_payload):
            raise ValueError("reserved ingestion metadata key")
        canonical_metadata = _canonical_json(request.metadata_payload)
        document = self._parser.parse(
            payload=request.payload,
            media_type=request.media_type,
        )
        chunks = self._chunker.chunk(document)
        embedding_plan = self._embedding_planner.plan(
            tenant_id=request.context.tenant_id,
            source_key=request.source_key,
            version_number=request.version_number,
            model_ref=request.embedding_model_ref,
            chunks=chunks,
        )
        pipeline_contract = {
            "chunker_digest": self._chunker.config_digest,
            "embedding_max_attempts": embedding_plan.max_attempts,
            "embedding_model_ref": embedding_plan.model_ref,
            "parser_digest": document.parser_digest,
            "pipeline_version": self.PIPELINE_VERSION,
        }
        pipeline_digest = hashlib.sha256(
            json.dumps(
                pipeline_contract, sort_keys=True, separators=(",", ":")
            ).encode("utf-8")
        ).hexdigest()
        version_metadata = json.loads(canonical_metadata)
        version_metadata.update(
            {
                f"{SYSTEM_METADATA_PREFIX}character_count": document.character_count,
                f"{SYSTEM_METADATA_PREFIX}chunk_count": len(chunks),
                f"{SYSTEM_METADATA_PREFIX}chunker_digest": self._chunker.config_digest,
                f"{SYSTEM_METADATA_PREFIX}embedding_model_ref": embedding_plan.model_ref,
                f"{SYSTEM_METADATA_PREFIX}embedding_plan_digest": embedding_plan.plan_digest,
                f"{SYSTEM_METADATA_PREFIX}media_type": document.media_type,
                f"{SYSTEM_METADATA_PREFIX}pipeline_digest": pipeline_digest,
            }
        )
        return _PreparedIngestion(
            document=document,
            chunks=chunks,
            embedding_plan=embedding_plan,
            pipeline_digest=pipeline_digest,
            version_metadata=version_metadata,
        )
