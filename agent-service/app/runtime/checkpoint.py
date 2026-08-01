"""Strict, fenced PostgreSQL saver compatible with LangGraph v1."""

from __future__ import annotations

from collections.abc import Iterator, Sequence
from dataclasses import dataclass
import hashlib
import json
import math
import re
from typing import Any, cast
import uuid

from langchain_core.runnables import RunnableConfig
from langgraph.checkpoint.base import (
    BaseCheckpointSaver,
    ChannelVersions,
    Checkpoint,
    CheckpointMetadata,
    CheckpointTuple,
)
from sqlalchemy import (
    Column,
    DateTime,
    ForeignKeyConstraint,
    Integer,
    MetaData,
    SmallInteger,
    String,
    Table,
    func,
    select,
    update,
)
from sqlalchemy.dialects.postgresql import JSONB, UUID, insert as pg_insert
from sqlalchemy.orm import Session, sessionmaker

from app.persistence.models.jobs import CheckpointMetadataRecord, JobRecord
from app.persistence.models.runtime import RUNTIME_SCHEMA
from app.persistence.repositories.jobs import JobsRepository


CURRENT_ENVELOPE_VERSION = 2
MAX_CHECKPOINT_BYTES = 1_048_576
SCHEMA_DIGEST = hashlib.sha256(b"gonow-checkpoint-envelope-v2").hexdigest()
SECRET_CANARY = re.compile(
    r"(?i)(sk-[a-z0-9]{16,}|github_pat_[a-z0-9_]+|-----BEGIN [A-Z ]*PRIVATE KEY-----)"
)
FORBIDDEN_KEYS = frozenset(
    {
        "access_token",
        "api_key",
        "authorization",
        "client",
        "connection",
        "prompt",
        "raw_body",
        "reasoning",
        "refresh_token",
        "secret",
    }
)

_metadata = MetaData(schema=RUNTIME_SCHEMA)
checkpoint_payloads = Table(
    "checkpoint_payloads",
    _metadata,
    Column("tenant_id", String(128), primary_key=True),
    Column("state_ref", String(103), primary_key=True),
    Column("state_digest", String(64), nullable=False),
    Column("state_schema_digest", String(64), nullable=False),
    Column("envelope_version", SmallInteger, nullable=False),
    Column("payload", JSONB, nullable=False),
    Column("created_at", DateTime(timezone=True), nullable=False),
)
checkpoint_pending_writes = Table(
    "checkpoint_pending_writes",
    _metadata,
    Column("tenant_id", String(128), primary_key=True),
    Column("checkpoint_id", UUID(as_uuid=True), primary_key=True),
    Column("run_id", UUID(as_uuid=True), nullable=False),
    Column("task_id", String(128), primary_key=True),
    Column("task_path", String(256), nullable=False),
    Column("write_index", Integer, primary_key=True),
    Column("channel", String(128), nullable=False),
    Column("value_json", JSONB, nullable=False),
    Column("value_digest", String(64), nullable=False),
    Column("created_at", DateTime(timezone=True), nullable=False),
    ForeignKeyConstraint(
        ["checkpoint_id", "tenant_id", "run_id"],
        [
            f"{RUNTIME_SCHEMA}.checkpoint_metadata.checkpoint_id",
            f"{RUNTIME_SCHEMA}.checkpoint_metadata.tenant_id",
            f"{RUNTIME_SCHEMA}.checkpoint_metadata.run_id",
        ],
    ),
)


class UnsafeCheckpoint(ValueError):
    code = "checkpoint.unsafe_state"

    def __init__(self) -> None:
        super().__init__(self.code)


class CheckpointConflict(RuntimeError):
    code = "checkpoint.conflict"

    def __init__(self) -> None:
        super().__init__(self.code)


class UnsupportedCheckpointVersion(RuntimeError):
    code = "checkpoint.unsupported_version"

    def __init__(self) -> None:
        super().__init__(self.code)


class CorruptCheckpoint(RuntimeError):
    code = "checkpoint.corrupt"

    def __init__(self) -> None:
        super().__init__(self.code)


@dataclass(frozen=True, slots=True)
class _CheckpointIdentity:
    tenant_id: str
    run_id: uuid.UUID
    job_id: uuid.UUID
    holder_id: str
    fencing_token: int
    audit_receipt_id: str
    checkpoint_ns: str
    checkpoint_id: uuid.UUID | None


def _normalize_json(value: Any, *, path: tuple[str, ...] = ()) -> Any:
    if value is None or isinstance(value, (bool, int, str)):
        if isinstance(value, str) and SECRET_CANARY.search(value):
            raise UnsafeCheckpoint()
        return value
    if isinstance(value, float):
        if not math.isfinite(value):
            raise UnsafeCheckpoint()
        return value
    if isinstance(value, (list, tuple)):
        return [_normalize_json(item, path=path + (str(index),)) for index, item in enumerate(value)]
    if isinstance(value, dict):
        normalized: dict[str, Any] = {}
        for key, item in value.items():
            if not isinstance(key, str) or key.lower() in FORBIDDEN_KEYS:
                raise UnsafeCheckpoint()
            normalized[key] = _normalize_json(item, path=path + (key,))
        return normalized
    raise UnsafeCheckpoint()


def _canonical_json(value: Any) -> tuple[Any, bytes, str]:
    normalized = _normalize_json(value)
    encoded = json.dumps(
        normalized,
        ensure_ascii=False,
        allow_nan=False,
        separators=(",", ":"),
        sort_keys=True,
    ).encode("utf-8")
    if len(encoded) > MAX_CHECKPOINT_BYTES:
        raise UnsafeCheckpoint()
    return normalized, encoded, hashlib.sha256(encoded).hexdigest()


def _upgrade_envelope(payload: Any, envelope_version: int) -> dict[str, Any]:
    normalized = _normalize_json(payload)
    if not isinstance(normalized, dict):
        raise CorruptCheckpoint()
    if envelope_version == 1:
        if set(normalized) != {"checkpoint", "metadata", "version"} or normalized.get("version") != 1:
            raise CorruptCheckpoint()
        return {
            "version": CURRENT_ENVELOPE_VERSION,
            "checkpoint": normalized["checkpoint"],
            "metadata": normalized["metadata"],
            "new_versions": {},
        }
    if envelope_version == CURRENT_ENVELOPE_VERSION:
        if set(normalized) != {"checkpoint", "metadata", "new_versions", "version"} or normalized.get("version") != CURRENT_ENVELOPE_VERSION:
            raise CorruptCheckpoint()
        return cast(dict[str, Any], normalized)
    raise UnsupportedCheckpointVersion()


class GoNowPostgresCheckpointSaver(BaseCheckpointSaver[str]):
    """Synchronous LangGraph saver using GoNow tenant and fencing contracts."""

    def __init__(self, session_factory: sessionmaker[Session]) -> None:
        super().__init__()
        self._session_factory = session_factory

    @staticmethod
    def _identity(config: RunnableConfig, *, write: bool) -> _CheckpointIdentity:
        configurable = config.get("configurable")
        if not isinstance(configurable, dict):
            raise ValueError("checkpoint configurable identity is required")
        try:
            tenant_id = str(configurable["tenant_id"])
            run_id = uuid.UUID(str(configurable["run_id"]))
            job_id = uuid.UUID(str(configurable["job_id"]))
            holder_id = str(configurable["lease_holder_id"])
            fencing_token = int(configurable["fencing_token"])
            audit_receipt_id = str(configurable["audit_receipt_id"])
        except (KeyError, TypeError, ValueError) as error:
            raise ValueError("checkpoint configurable identity is invalid") from error
        thread_id = str(configurable.get("thread_id", ""))
        checkpoint_ns = str(configurable.get("checkpoint_ns", ""))
        checkpoint_value = configurable.get("checkpoint_id")
        try:
            checkpoint_id = None if checkpoint_value is None else uuid.UUID(str(checkpoint_value))
        except ValueError as error:
            raise ValueError("checkpoint_id must be a UUID") from error
        if (
            not tenant_id
            or not holder_id
            or fencing_token <= 0
            or (write and not audit_receipt_id)
            or thread_id != str(run_id)
            or checkpoint_ns != ""
        ):
            raise ValueError("checkpoint identity, thread, namespace, or audit receipt is invalid")
        return _CheckpointIdentity(
            tenant_id=tenant_id,
            run_id=run_id,
            job_id=job_id,
            holder_id=holder_id,
            fencing_token=fencing_token,
            audit_receipt_id=audit_receipt_id,
            checkpoint_ns=checkpoint_ns,
            checkpoint_id=checkpoint_id,
        )

    @staticmethod
    def _set_tenant(session: Session, tenant_id: str) -> None:
        session.execute(select(func.set_config("app.tenant_id", tenant_id, True)))

    @staticmethod
    def _assert_fence(session: Session, identity: _CheckpointIdentity) -> None:
        JobsRepository(session).assert_fence(
            tenant_id=identity.tenant_id,
            job_id=identity.job_id,
            holder_id=identity.holder_id,
            fencing_token=identity.fencing_token,
        )

    @staticmethod
    def _returned_config(config: RunnableConfig, checkpoint_id: uuid.UUID) -> RunnableConfig:
        configurable = dict(cast(dict[str, Any], config["configurable"]))
        configurable["checkpoint_ns"] = ""
        configurable["checkpoint_id"] = str(checkpoint_id)
        return cast(RunnableConfig, {**config, "configurable": configurable})

    def put(
        self,
        config: RunnableConfig,
        checkpoint: Checkpoint,
        metadata: CheckpointMetadata,
        new_versions: ChannelVersions,
    ) -> RunnableConfig:
        identity = self._identity(config, write=True)
        try:
            checkpoint_id = uuid.UUID(str(checkpoint["id"]))
        except (KeyError, ValueError) as error:
            raise ValueError("LangGraph checkpoint id must be a UUID") from error
        envelope, _, digest = _canonical_json(
            {
                "version": CURRENT_ENVELOPE_VERSION,
                "checkpoint": checkpoint,
                "metadata": metadata,
                "new_versions": new_versions,
            }
        )
        state_ref = f"checkpoint://sha256/{digest}"
        parent_id = identity.checkpoint_id

        with self._session_factory.begin() as session:
            self._set_tenant(session, identity.tenant_id)
            self._assert_fence(session, identity)
            existing = session.get(CheckpointMetadataRecord, checkpoint_id)
            if existing is not None:
                if (
                    existing.tenant_id != identity.tenant_id
                    or existing.run_id != identity.run_id
                    or existing.state_digest != digest
                ):
                    raise CheckpointConflict()
                return self._returned_config(config, checkpoint_id)

            job = session.execute(
                select(JobRecord)
                .where(
                    JobRecord.job_id == identity.job_id,
                    JobRecord.run_id == identity.run_id,
                    JobRecord.tenant_id == identity.tenant_id,
                )
                .with_for_update()
            ).scalar_one()
            next_seq = session.execute(
                select(func.coalesce(func.max(CheckpointMetadataRecord.checkpoint_seq), 0) + 1).where(
                    CheckpointMetadataRecord.run_id == identity.run_id,
                    CheckpointMetadataRecord.tenant_id == identity.tenant_id,
                )
            ).scalar_one()
            inserted = session.execute(
                pg_insert(checkpoint_payloads)
                .values(
                    tenant_id=identity.tenant_id,
                    state_ref=state_ref,
                    state_digest=digest,
                    state_schema_digest=SCHEMA_DIGEST,
                    envelope_version=CURRENT_ENVELOPE_VERSION,
                    payload=envelope,
                    created_at=func.statement_timestamp(),
                )
                .on_conflict_do_nothing(
                    index_elements=[
                        checkpoint_payloads.c.tenant_id,
                        checkpoint_payloads.c.state_ref,
                    ]
                )
                .returning(checkpoint_payloads.c.state_ref)
            ).scalar_one_or_none()
            if inserted is None:
                stored = session.execute(
                    select(
                        checkpoint_payloads.c.state_digest,
                        checkpoint_payloads.c.state_schema_digest,
                        checkpoint_payloads.c.envelope_version,
                    ).where(
                        checkpoint_payloads.c.tenant_id == identity.tenant_id,
                        checkpoint_payloads.c.state_ref == state_ref,
                    )
                ).one()
                if tuple(stored) != (digest, SCHEMA_DIGEST, CURRENT_ENVELOPE_VERSION):
                    raise CheckpointConflict()
            session.add(
                CheckpointMetadataRecord(
                    checkpoint_id=checkpoint_id,
                    parent_checkpoint_id=parent_id,
                    job_id=job.job_id,
                    run_id=identity.run_id,
                    tenant_id=identity.tenant_id,
                    checkpoint_seq=next_seq,
                    fencing_token=identity.fencing_token,
                    state_ref=state_ref,
                    state_digest=digest,
                    state_schema_digest=SCHEMA_DIGEST,
                    pending_writes_ref=None,
                    audit_receipt_id=identity.audit_receipt_id,
                )
            )
            session.flush()
        return self._returned_config(config, checkpoint_id)

    def put_writes(
        self,
        config: RunnableConfig,
        writes: Sequence[tuple[str, Any]],
        task_id: str,
        task_path: str = "",
    ) -> None:
        identity = self._identity(config, write=True)
        if identity.checkpoint_id is None or not task_id or len(task_id) > 128 or len(task_path) > 256:
            raise ValueError("checkpoint write identity is invalid")
        normalized_writes: list[tuple[int, str, Any, str]] = []
        for index, (channel, value) in enumerate(writes):
            if not channel or len(channel) > 128:
                raise ValueError("checkpoint write channel is invalid")
            normalized, _, digest = _canonical_json(value)
            normalized_writes.append((index, channel, normalized, digest))

        with self._session_factory.begin() as session:
            self._set_tenant(session, identity.tenant_id)
            self._assert_fence(session, identity)
            metadata_record = session.execute(
                select(CheckpointMetadataRecord)
                .where(
                    CheckpointMetadataRecord.checkpoint_id == identity.checkpoint_id,
                    CheckpointMetadataRecord.tenant_id == identity.tenant_id,
                    CheckpointMetadataRecord.run_id == identity.run_id,
                )
                .with_for_update()
            ).scalar_one()
            for index, channel, value, digest in normalized_writes:
                inserted = session.execute(
                    pg_insert(checkpoint_pending_writes)
                    .values(
                        tenant_id=identity.tenant_id,
                        checkpoint_id=identity.checkpoint_id,
                        run_id=identity.run_id,
                        task_id=task_id,
                        task_path=task_path,
                        write_index=index,
                        channel=channel,
                        value_json=value,
                        value_digest=digest,
                        created_at=func.statement_timestamp(),
                    )
                    .on_conflict_do_nothing(
                        index_elements=[
                            checkpoint_pending_writes.c.tenant_id,
                            checkpoint_pending_writes.c.checkpoint_id,
                            checkpoint_pending_writes.c.task_id,
                            checkpoint_pending_writes.c.write_index,
                        ]
                    )
                    .returning(checkpoint_pending_writes.c.write_index)
                ).scalar_one_or_none()
                if inserted is None:
                    existing = session.execute(
                        select(
                            checkpoint_pending_writes.c.channel,
                            checkpoint_pending_writes.c.value_digest,
                        ).where(
                            checkpoint_pending_writes.c.tenant_id == identity.tenant_id,
                            checkpoint_pending_writes.c.checkpoint_id == identity.checkpoint_id,
                            checkpoint_pending_writes.c.run_id == identity.run_id,
                            checkpoint_pending_writes.c.task_id == task_id,
                            checkpoint_pending_writes.c.write_index == index,
                        )
                    ).one()
                    if tuple(existing) != (channel, digest):
                        raise CheckpointConflict()
            write_rows = session.execute(
                select(
                    checkpoint_pending_writes.c.task_id,
                    checkpoint_pending_writes.c.write_index,
                    checkpoint_pending_writes.c.channel,
                    checkpoint_pending_writes.c.value_digest,
                )
                .where(
                    checkpoint_pending_writes.c.tenant_id == identity.tenant_id,
                    checkpoint_pending_writes.c.checkpoint_id == identity.checkpoint_id,
                    checkpoint_pending_writes.c.run_id == identity.run_id,
                )
                .order_by(
                    checkpoint_pending_writes.c.task_id,
                    checkpoint_pending_writes.c.write_index,
                )
            ).all()
            _, _, pending_digest = _canonical_json([list(row) for row in write_rows])
            metadata_record.pending_writes_ref = f"pending://sha256/{pending_digest}"
            session.flush()

    def _tuple_for_record(
        self,
        session: Session,
        config: RunnableConfig,
        record: CheckpointMetadataRecord,
    ) -> CheckpointTuple:
        payload_row = session.execute(
            select(
                checkpoint_payloads.c.payload,
                checkpoint_payloads.c.state_digest,
                checkpoint_payloads.c.state_schema_digest,
                checkpoint_payloads.c.envelope_version,
            ).where(
                checkpoint_payloads.c.tenant_id == record.tenant_id,
                checkpoint_payloads.c.state_ref == record.state_ref,
            )
        ).one()
        normalized, _, digest = _canonical_json(payload_row.payload)
        if (
            digest != payload_row.state_digest
            or digest != record.state_digest
            or payload_row.state_schema_digest != record.state_schema_digest
        ):
            raise CorruptCheckpoint()
        envelope = _upgrade_envelope(normalized, int(payload_row.envelope_version))
        pending_rows = session.execute(
            select(
                checkpoint_pending_writes.c.task_id,
                checkpoint_pending_writes.c.channel,
                checkpoint_pending_writes.c.value_json,
            )
            .where(
                checkpoint_pending_writes.c.tenant_id == record.tenant_id,
                checkpoint_pending_writes.c.checkpoint_id == record.checkpoint_id,
                checkpoint_pending_writes.c.run_id == record.run_id,
            )
            .order_by(
                checkpoint_pending_writes.c.task_id,
                checkpoint_pending_writes.c.write_index,
            )
        ).all()
        result_config = self._returned_config(config, record.checkpoint_id)
        parent_config = (
            None
            if record.parent_checkpoint_id is None
            else self._returned_config(config, record.parent_checkpoint_id)
        )
        return CheckpointTuple(
            config=result_config,
            checkpoint=cast(Checkpoint, envelope["checkpoint"]),
            metadata=cast(CheckpointMetadata, envelope["metadata"]),
            parent_config=parent_config,
            pending_writes=[(row.task_id, row.channel, row.value_json) for row in pending_rows],
        )

    def get_tuple(self, config: RunnableConfig) -> CheckpointTuple | None:
        identity = self._identity(config, write=False)
        with self._session_factory.begin() as session:
            self._set_tenant(session, identity.tenant_id)
            self._assert_fence(session, identity)
            statement = select(CheckpointMetadataRecord).where(
                CheckpointMetadataRecord.tenant_id == identity.tenant_id,
                CheckpointMetadataRecord.run_id == identity.run_id,
                CheckpointMetadataRecord.job_id == identity.job_id,
            )
            if identity.checkpoint_id is not None:
                statement = statement.where(
                    CheckpointMetadataRecord.checkpoint_id == identity.checkpoint_id
                )
            else:
                statement = statement.order_by(
                    CheckpointMetadataRecord.checkpoint_seq.desc()
                ).limit(1)
            record = session.execute(statement).scalar_one_or_none()
            return None if record is None else self._tuple_for_record(session, config, record)

    def list(
        self,
        config: RunnableConfig | None,
        *,
        filter: dict[str, Any] | None = None,
        before: RunnableConfig | None = None,
        limit: int | None = None,
    ) -> Iterator[CheckpointTuple]:
        if config is None:
            raise ValueError("tenant-scoped checkpoint config is required")
        if limit is not None and not 1 <= limit <= 100:
            raise ValueError("checkpoint list limit must be between one and 100")
        identity = self._identity(config, write=False)
        before_identity = None if before is None else self._identity(before, write=False)
        if before_identity is not None and (
            before_identity.tenant_id != identity.tenant_id
            or before_identity.run_id != identity.run_id
        ):
            raise ValueError("checkpoint before cursor crosses tenant or run")
        results: list[CheckpointTuple] = []
        with self._session_factory.begin() as session:
            self._set_tenant(session, identity.tenant_id)
            self._assert_fence(session, identity)
            statement = select(CheckpointMetadataRecord).where(
                CheckpointMetadataRecord.tenant_id == identity.tenant_id,
                CheckpointMetadataRecord.run_id == identity.run_id,
                CheckpointMetadataRecord.job_id == identity.job_id,
            )
            if before_identity is not None and before_identity.checkpoint_id is not None:
                before_seq = session.execute(
                    select(CheckpointMetadataRecord.checkpoint_seq).where(
                        CheckpointMetadataRecord.checkpoint_id
                        == before_identity.checkpoint_id,
                        CheckpointMetadataRecord.tenant_id == identity.tenant_id,
                    )
                ).scalar_one()
                statement = statement.where(
                    CheckpointMetadataRecord.checkpoint_seq < before_seq
                )
            records = session.scalars(
                statement.order_by(CheckpointMetadataRecord.checkpoint_seq.desc())
            ).all()
            for record in records:
                item = self._tuple_for_record(session, config, record)
                if filter and any(item.metadata.get(key) != value for key, value in filter.items()):
                    continue
                results.append(item)
                if limit is not None and len(results) >= limit:
                    break
        yield from results
